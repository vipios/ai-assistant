import Foundation

/// 更新包下载源测速（2026-11-05，用户要求）
///
/// 背景：`UpdateManager.downloadAndInstall` 原来是**写死顺序**——
///   GitHub 直连 → ghfast.top → gh-proxy.com。
/// 国内直连 GitHub 下载基本是「等到 30 秒超时再换下一个」，
/// 也就是说排在前面的直连等于白等半分钟，所谓「加速镜像」只是失败后的备胎，
/// 根本没起到加速作用。
///
/// 现在改成：直连和两个镜像**同时**各拉一小段（1.5MB / 最多 8 秒），
/// 按实测速度降序排，从最快的开始下。谁快走谁，直连也参与比较。
///
/// 几个实现要点（都踩过或想清楚了才这么写）：
///   1. 必须用 `URLSessionDataDelegate` 手动计数，不能用 `dataTask(completionHandler:)`——
///      后者会把整个 body 收完才回调，测速等于把 104MB 的包整个下一遍。
///      这里收够 1.5MB 立即 cancel。
///   2. 必须检查 HTTP 状态。镜像挂掉时常返回 200 + 错误页（几十字节的 HTML），
///      不判状态的话「秒回」会被算成第一名，然后下载链从它开始必然失败。
///      只认 200 / 206。
///   3. 三个源**并行**探测，总耗时 = 最慢的那个（有 8 秒硬上限），
///      串行的话光测速就要 24 秒，用户会以为卡死。
///   4. 分数 = 已收字节 / 已用时，再对「太早收满」的源打一点折扣（见 finish 里的说明）。
final class UpdateSourceProbe: NSObject, URLSessionDataDelegate {

    static let shared = UpdateSourceProbe()

    /// 单源探测上限（字节）。
    ///
    /// 2026-11-05 实测校准：本项目的更新包 **104MB**（`Content-Range: bytes 0-1023/104033566`）。
    /// 最初写 320KB，实测下来不够——320KB 只够跑 1~3 秒，太容易受 TCP 慢启动
    /// 和首包抖动影响，同一台手机连测两次排出来的第一名都能不一样。
    /// 调到 1.5MB：按实测 100~200KB/s 的速度大约要 8~15 秒，正好和下面的
    /// 时间上限配平；流量代价 1.5MB/源 × 3 源 ≈ 4.5MB，相对于 104MB 的包可以忽略。
    private let probeBytes = 1536 * 1024
    /// 单源最长探测时间（秒）
    ///
    /// 为什么不设更短：速度差在 100KB/s 和 300KB/s 这种量级时，
    /// 3 秒的窗口区分不出来（TCP 还在慢启动）。8 秒能稳定分出高低。
    /// 为什么不设更长：三个源并行，总耗时就是最慢那个，8 秒是用户能忍的极限。
    private let probeSeconds: TimeInterval = 8.0

    private struct Rec {
        let started: Date
        var bytes: Int = 0
        /// 状态不是 200/206（错误页、404 等）——速度按 0 算，别让它排到前面
        var bad: Bool = false
        var callback: ((Double) -> Void)?
        /// 只回调一次（cancel 之后 didCompleteWithError 还会再来一趟）
        var fired = false
    }

    private var recs: [Int: Rec] = [:]
    private let lock = NSLock()
    private var session: URLSession!

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = probeSeconds + 4
        cfg.timeoutIntervalForResource = probeSeconds + 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 不复用共享 session：它的 delegate 是 nil，拿不到逐块回调
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    // MARK: - 对外

    /// 并行测速并排序。
    /// - Parameter targets: (显示名, 前缀, 完整测速 URL)。前缀为空串表示 GitHub 直连。
    /// - Returns: 按实测速度降序排列的结果（速度为 0 的排最后，但**保留**——
    ///   全都不通时下载链还得按原顺序逐个试，不能因为测速失败就放弃更新）。
    func rank(_ targets: [(label: String, prefix: String, url: String)],
              completion: @escaping ([(label: String, prefix: String, speed: Double)]) -> Void) {
        guard !targets.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let group = DispatchGroup()
        let outLock = NSLock()
        var out: [(label: String, prefix: String, speed: Double)] = []
        out.reserveCapacity(targets.count)

        for t in targets {
            guard let u = URL(string: t.url) else { continue }
            group.enter()
            measure(u) { speed in
                outLock.lock()
                out.append((t.label, t.prefix, speed))
                outLock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // 稳定排序：速度相同的保持输入顺序（直连在前），避免每次测速结果抖动
            let sorted = out.enumerated().sorted { a, b in
                if a.element.speed != b.element.speed { return a.element.speed > b.element.speed }
                return a.offset < b.offset
            }.map { $0.element }
            completion(sorted)
        }
    }

    /// 单个源测速，回调速度（字节/秒）。失败回调 0。**保证回调且只回调一次。**
    ///
    /// 2026-11-05：这里原来有个会把整个更新流程卡死的隐患。
    /// `finish()` 的 guard 是「recs 里还有这条记录才结算」，而外面还挂了一个
    /// 8+1.5 秒的兜底 `asyncAfter`。如果网络层先自己结束（didCompleteWithError）
    /// 把记录摘掉了，兜底那次进来会直接 return —— 看似没事；
    /// 但反过来，如果兜底先跑、把记录摘掉，而真正的数据回调稍后才到，
    /// 那次也会被 guard 挡掉。两条路本身都不致命，致命的是：
    /// **DispatchGroup 的 leave 挂在 completion 上**，只要 completion 一次都没被调用，
    /// leave 就永远不执行 → `group.notify` 永远不触发 → `downloadAndInstall`
    /// 的回调永远不来 → 界面永远停在「正在测速」，连超时提示都没有。
    /// 修法：用一个只执行一次的包装闭包，无论走哪条路，最终必定有一次回调。
    private func measure(_ url: URL, completion: @escaping (Double) -> Void) {
        var req = URLRequest(url: url)
        req.timeoutInterval = probeSeconds + 4
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // 只要前面一小段。服务器不支持 Range 会返回 200 全量 —— 那种情况收够了就断，无妨。
        req.setValue("bytes=0-\(probeBytes - 1)", forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        // 只执行一次的闸门：先到先算，后来的全部丢弃。
        // 用一个 class 持有状态——Swift 的闭包捕获 var 在逃逸闭包里是引用语义，
        // 但跨线程读写同一个 var 会有数据竞争告警（Swift 6 直接变编译错误），
        // 装进 class + NSLock 才是干净的写法。
        let gate = OnceGate()
        let once: (Double) -> Void = { speed in gate.fire(speed, completion) }

        let task = session.dataTask(with: req)
        let tid = task.taskIdentifier
        lock.lock()
        recs[tid] = Rec(started: Date(), callback: once)
        lock.unlock()
        task.resume()

        // 硬超时兜底：某些代理会「连上了但一个字节都不发」，光靠 URLRequest 超时可能拖很久。
        // 这是最后的保险——即使网络层一个回调都不给，这里也会放行一次（速度记 0）。
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + probeSeconds + 1.5) { [weak self] in
            guard let self = self else { once(0); return }
            self.finish(tid, shouldCancel: task)
            // finish 如果因为记录已被摘掉而提前返回，once 就还没跑过 —— 这里补一次。
            // 有 once 闸门在，重复调用无副作用。
            once(0)
        }
    }

    // MARK: - 收尾

    /// 结算一次探测。`shouldCancel` 非 nil 时顺手把任务停掉（提前收够 / 状态不对 / 超时）。
    ///
    /// 注意执行顺序：**先把状态从 recs 里摘掉（fired=true + removeValue），再 cancel**。
    /// `task.cancel()` 会同步回调 didCompleteWithError → 又进一次 finish。
    /// 如果先 cancel 再摘状态，就会重入，虽然 fired 能挡住，但那次重入拿到的
    /// 是"还没结算完的旧记录"，速度会算错。摘完再 cancel，重入时直接 guard 返回，干净。
    private func finish(_ tid: Int, shouldCancel: URLSessionDataTask?) {
        lock.lock()
        guard var r = recs[tid], !r.fired else {
            lock.unlock()
            return
        }
        r.fired = true
        recs.removeValue(forKey: tid)
        lock.unlock()

        shouldCancel?.cancel()

        var speed: Double = 0
        if !r.bad, r.bytes > 0 {
            let elapsed = max(Date().timeIntervalSince(r.started), 0.05)
            speed = Double(r.bytes) / elapsed
            // 长跑折扣：用时不到探测窗口一半就收满的，说明前面撞上了缓存/CDN 边缘节点，
            // 这个速度不能代表整个 104MB 包的长跑表现。
            // 按「用时 / 半个窗口」打折，最低打到 60% —— 只削掉虚假的首包爆发，
            // 不改变量级差距（真快一倍的仍然排前面）。
            if elapsed < probeSeconds * 0.5 {
                let factor = max(0.6, elapsed / (probeSeconds * 0.5))
                speed *= factor
            }
        }
        r.callback?(speed)
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let tid = dataTask.taskIdentifier
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 206 = Range 生效；200 = 服务器忽略 Range，给的是全量，同样能测。
        //
        // 302 不用在这里处理：GitHub Releases 直链本来就返回 302 跳到
        // objects.githubusercontent.com，URLSession 默认会自动跟随，
        // 这个回调拿到的已经是跟随后的最终响应。所以「直连 302」在这条路上
        // 走的是正常分支——而国内真实情况往往是跳到 objects. 之后就卡住不动，
        // 那会表现为速度极低或 0，正是我们想测出来的结果。
        // 真遇到不跟随的极端情况（3xx 原样冒到这里），也当作"没拿到包"标坏，
        // 让它排到最后，而不是误判成"秒回"的第一名。
        if code == 200 || code == 206 {
            completionHandler(.allow)
            return
        }
        // 403 / 404 / 5xx：这是错误页，不是安装包。标坏并立刻结束，别让「秒回」排到第一
        lock.lock()
        if var r = recs[tid] { r.bad = true; recs[tid] = r }
        lock.unlock()
        completionHandler(.cancel)
        finish(tid, shouldCancel: dataTask)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tid = dataTask.taskIdentifier
        var reached = false
        lock.lock()
        if var r = recs[tid] {
            r.bytes += data.count
            if r.bytes >= probeBytes { reached = true }
            recs[tid] = r
        }
        lock.unlock()
        if reached { finish(tid, shouldCancel: dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 正常收够 / 被 cancel / 网络错误，最后都走到这里。fired 标记保证只结算一次。
        finish(task.taskIdentifier, shouldCancel: nil)
    }
}

/// 「保证且只执行一次」的闸门。
///
/// 单独抽出来是因为它要在三个地方被调用（数据回调收满、HTTP 状态判坏、超时兜底），
/// 而这三条路在并发下都可能赢——谁先赢谁结算，后面的必须静默丢弃，
/// 否则 DispatchGroup 会被 leave 两次，直接崩在 "unbalanced call to leave"。
private final class OnceGate {
    private let lock = NSLock()
    private var used = false

    func fire(_ speed: Double, _ completion: (Double) -> Void) {
        lock.lock()
        if used { lock.unlock(); return }
        used = true
        lock.unlock()
        completion(speed)
    }
}
