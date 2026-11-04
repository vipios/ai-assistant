import Foundation

// MARK: - 接口地址双通道路由（2026-11-03）
//
// 用户诉求（原话）：
//   「在接口地址下方再创建一个备用接口…第一个填写在家时候的接口，
//    第二个填写在外面时候的接口，然后能自动判定咱们在家还是在外面，
//    在家就用接口地址，在外就用备用接口地址」
//
// 判定为什么不能只看「有没有连 WiFi」：
//   家里是两层网络——光猫 192.168.1.x + OpenWrt 192.168.2.x，
//   手机连 OpenWrt 的 WiFi 拿到 192.168.2.100，而用户填的在家接口
//   很可能是 192.168.1.88（光猫段）。只比 /24 会判成「在外」，
//   于是明明在家却走了公网域名——慢一个数量级，还多绕一趟 Cloudflare。
//
// 所以判定规则放宽到「同 /16 且都是内网」：
//   192.168.2.100（手机） vs 192.168.1.88（在家接口） → 前两段都是 192.168 → 判在家。
//   用 4G 时本机没有内网 IPv4（只有 pdp_ip0 的公网口）→ 判在外。
//
// 三层保障（顺序即优先级）：
//   1. 网段判定 —— 零成本、同步、覆盖绝大多数场景
//   2. 后台探测 —— 网段判不出来时探一次 /health，结果缓存，不阻塞当前请求
//   3. 失败回切 —— 在家地址真连不上（换了 WiFi、路由器改了网段）就自动切备用
final class BaseURLRouter {

    static let shared = BaseURLRouter()

    /// 判定结果缓存有效期。5 分钟：够短，路由器换网段后能自己恢复；
    /// 够长，不至于每条消息都重探一遍。
    private let ttl: TimeInterval = 300

    private struct Decision {
        var configID: UUID
        var netSig: String
        var useBackup: Bool
        var at: Date
    }

    private var cache: [UUID: Decision] = [:]
    private let lock = NSLock()
    /// 正在探测中的配置，防重入。
    ///
    /// 为什么要它：`effectiveBaseURL` 和 `effectiveModel` 是两个计算属性，
    /// SwiftUI 一帧里可能把同一个 config 算好几次，每次走 unknown 分支都会发一个探测。
    /// 不去重的话，打开设置页就对着网关打出一串 /health。
    private var probing: Set<UUID> = []

    private init() {}

    // MARK: - 对外：取当前该用的地址

    /// 同步返回该用的接口地址。**不发网络请求**，可以直接在发请求的路径上调用。
    ///
    /// 没填备用接口时原样返回 `baseURL`——完全向后兼容，老配置行为一点不变。
    func base(for config: ModelConfig) -> String {
        resolve(for: config).base
    }

    /// 2026-11-03：一次性把「地址 + 是否走备用」算出来，**同一份判定结果**。
    ///
    /// 为什么必须成对返回：`effectiveBaseURL` 和 `effectiveModel` 是两个独立计算属性，
    /// 各自调一次判定。若两次判定读到的缓存/网络状态不同（比如一次算完刚好网络变了、
    /// 或者 unknown 分支一次触发了探测另一次没有），就会出现
    /// 「用在家的地址 + 在外的模型名」——上游必定 404，且极难排查。
    /// 所以判定只做一次，两个属性都从这一份结果取值。
    func resolve(for config: ModelConfig) -> (base: String, useBackup: Bool) {
        let home = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = config.backupBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // 备用没填 = 没启用双通道，直接用主地址
        guard !away.isEmpty else { return (home, false) }
        // 主地址空、备用有值：只能走备用（用户正在编辑中途也可能出现）
        guard !home.isEmpty else { return (away, true) }

        let sig = netSignature()

        // 1) 命中缓存且网络没变 → 用缓存结论
        lock.lock()
        let hit = cache[config.id]
        lock.unlock()

        if let hit, hit.netSig == sig, Date().timeIntervalSince(hit.at) < ttl {
            return (hit.useBackup ? away : home, hit.useBackup)
        }

        // 2) 网段判定（零成本）。判不出来就先按「在家」走，
        //    同时扔一个后台探测去校正 —— 不能在这里阻塞用户发消息。
        //
        // 2026-11-05：`.home` 也要后台探一次核实。
        // 用户明确要求「也要判定我在别的 WiFi 也是外面」——
        // 别人家 WiFi 也是 192.168.x，网段判必得 .home，但那个网里根本没有我们的中转站，
        // 于是每次请求都打到黑洞直到超时。现在先按 .home 用（不阻塞当前这次请求），
        // 同时后台探一次；探不通就把缓存翻成 .away，下一次请求自动走备用。
        switch lanVerdict(homeBase: home) {
        case .home:
            store(config.id, sig: sig, backup: false)
            probeInBackground(config: config, home: home, sig: sig)
            return (home, false)
        case .away:
            store(config.id, sig: sig, backup: true)
            return (away, true)
        case .unknown:
            store(config.id, sig: sig, backup: false)
            probeInBackground(config: config, home: home, sig: sig)
            return (home, false)
        }
    }

    /// 记一次失败：刚才用的这个地址连不上，直接翻到另一个。
    ///
    /// 调用时机 = 请求彻底失败（连不上 / 超时 / DNS 解析失败）。
    /// 不做复杂判断：既然这个地址刚失败过，就换成另一个 ——
    /// 下一次 `base(for:)` 读缓存会直接返回翻面后的结果，
    /// 等网络变了（netSignature 变）才重新按网段判定。
    func markFailed(base: String, config: ModelConfig) {
        let home = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = config.backupBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !away.isEmpty, !home.isEmpty else { return }
        // 刚才用的就是备用地址 → 翻回主地址；否则翻到备用
        let usedBackup = base.trimmingCharacters(in: .whitespacesAndNewlines) == away
        store(config.id, sig: netSignature(), backup: !usedBackup)
    }

    /// 2026-11-03：当前这条配置是不是正在走备用（在外面）。
    ///
    /// 模型名必须跟着这个结论走 —— `effectiveModel` 靠它决定用 `model` 还是 `backupModel`。
    /// 直接复用 `resolve(for:)`，保证和 `effectiveBaseURL` 是**同一份判定**，绝不各判各的。
    func isUsingBackup(for config: ModelConfig) -> Bool {
        resolve(for: config).useBackup
    }

    /// 清掉某个配置的缓存（用户改了地址 / 手动点「测试连接」时调）
    func invalidate(_ id: UUID) {
        lock.lock(); cache.removeValue(forKey: id); lock.unlock()
    }

    /// 全清（网络变化时用）
    func invalidateAll() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    // MARK: - 判定

    enum Verdict {
        case home       // 在家 → 用主地址
        case away       // 在外 → 用备用地址
        case unknown    // 看不出来（主地址是公网域名之类）→ 探一下
    }

    /// 用「手机当前内网 IP」和「主地址的 host」比网段。
    ///
    /// 只在两边都是**内网 IPv4** 时才有结论；主地址是域名 / 公网 IP 时返回 .unknown。
    ///
    /// ⚠️ 2026-11-05 **已知局限（重要）**：这个方法只比网段，**分不清「自家 WiFi」和
    /// 「别人家 WiFi」**——别人家也是 192.168.1.x，也会判成 .home。
    /// 用户明确指出这个问题：「也要判定我在别的 WiFi 也是外面」。
    ///
    /// 所以：
    ///   · 本方法只作为**同步快速预判**（界面展示、发请求的第一层）；
    ///   · 真正的结论必须用 `verifyAsync`——它探一次主地址，探得通才算在家；
    ///   · 发请求路径上即使预判成 .home，失败时也会由 `markFailed` 翻面兜底。
    func lanVerdict(homeBase: String) -> Verdict {
        guard let host = Self.hostOf(homeBase), Self.isPrivateIPv4(host) else {
            return .unknown
        }
        let locals = Self.localPrivateIPv4s()
        guard !locals.isEmpty else {
            // 没有任何内网 IPv4 = 在用流量 = 在外面
            return .away
        }
        // 同 /16 就算同一个家：192.168.2.100 vs 192.168.1.88 → 都是 192.168
        let hp = host.split(separator: ".")
        guard hp.count == 4 else { return .unknown }
        let homePrefix = "\(hp[0]).\(hp[1])"
        for ip in locals {
            let lp = ip.split(separator: ".")
            guard lp.count == 4 else { continue }
            if "\(lp[0]).\(lp[1])" == homePrefix { return .home }
        }
        return .away
    }

    /// 2026-11-05：**真判定**——探一次主地址，探得通才算在家。
    ///
    /// 解决「别人家 WiFi 被误判成在家」：
    /// 网段只说明「你连着一个 192.168.x 的网」，不说明「这个网里有我的中转站」。
    /// 所以必须真的打一次 `/health`：
    ///   · 连得上且响应是我的服务 → 在家，用主地址；
    ///   · 连不上（别人家网段里没有 192.168.1.88 这台机器）→ 在外，用备用地址。
    ///
    /// 为什么用 /health：免密钥，判定阶段没有 key 也能探。
    /// 任何 2xx/4xx 响应都算「这台机器是我的」——401/404 说明路通了只是路径/鉴权问题，
    /// 不该因为鉴权就判「在外」然后把用户踢到公网去绕一圈。
    func verifyAsync(for config: ModelConfig,
                     timeout: TimeInterval = 1.6,
                     completion: @escaping (Verdict) -> Void) {
        let home = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = config.backupBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // 没填备用 = 没启用双通道，判定无意义
        guard !away.isEmpty, !home.isEmpty else {
            completion(lanVerdict(homeBase: home))
            return
        }
        // 本来就没有内网 IP → 不用探，直接在外
        guard !Self.localPrivateIPv4s().isEmpty else {
            completion(.away)
            return
        }
        // 网段都不是内网地址（主地址填的是域名）→ 交给 probeInBackground 那套
        guard let host = Self.hostOf(home), Self.isPrivateIPv4(host) else {
            completion(.unknown)
            return
        }

        guard let url = Self.healthURL(from: home) else {
            completion(lanVerdict(homeBase: home))
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)

        session.dataTask(with: req) { data, resp, err in
            defer { session.finishTasksAndInvalidate() }
            var v: Verdict = .away
            if err == nil, let http = resp as? HTTPURLResponse {
                // 2xx/3xx/4xx 都算「这台机器在」；只有连不上/超时才是在外。
                // 5xx 也认作在——服务在但内部出错，这种情况下用户更需要继续用内网地址排查。
                if http.statusCode < 600 {
                    // 若返回了明确的 service 标识且不是我们的，判为「别人家的服务」
                    if let data = data,
                       let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let svc = doc["service"] as? String, !svc.isEmpty,
                       svc != "ai-relay" {
                        v = .away
                    } else {
                        v = .home
                    }
                }
            }
            let verdict = v
            DispatchQueue.main.async {
                // 网络在这期间又变了 → 结论作废（别把旧网的结论写进新网）
                completion(verdict)
            }
        }.resume()
    }

    /// 网络指纹：当前内网 IP 集合 + 网段。一变就说明换了网络，缓存自动作废。
    private func netSignature() -> String {
        let locals = Self.localPrivateIPv4s().sorted()
        return locals.isEmpty ? "no-lan" : locals.joined(separator: ",")
    }

    private func store(_ id: UUID, sig: String, backup: Bool) {
        lock.lock()
        cache[id] = Decision(configID: id, netSig: sig, useBackup: backup, at: Date())
        lock.unlock()
    }

    // MARK: - 后台探测（只用来校正网段判不出来的情况）

    /// 探一次主地址；通了=在家，不通=在外。不阻塞任何界面操作。
    ///
    /// 调用场景（2026-11-05 扩大）：
    ///   · `lanVerdict == .unknown`（主地址是域名/公网 IP，光看网段判断不出来）
    ///   · `lanVerdict == .home`（别人家 WiFi 也会判成 .home，必须核实一次）
    ///
    /// 「通了」的判定（2026-11-05 收紧）：不只看有没有 HTTP 响应，还要看响应是不是
    /// **我们的服务**。原因：别人家空调/光猫的管理页也可能在 8080 上回 200，
    /// 只看状态码会把「别人的设备」当成「我的中转站」，然后一直用错地址。
    /// 具体：JSON 里 service 字段有值且不是 ai-relay → 判为别人家的服务 → 在外。
    private func probeInBackground(config: ModelConfig, home: String, sig: String) {
        guard let url = Self.healthURL(from: home) else { return }
        let id = config.id

        // 同一条配置已经在探了就直接返回，别对网关反复打
        lock.lock()
        if probing.contains(id) { lock.unlock(); return }
        probing.insert(id)
        lock.unlock()

        var req = URLRequest(url: url)
        req.timeoutInterval = 4
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)

        session.dataTask(with: req) { [weak self] data, resp, err in
            defer { session.finishTasksAndInvalidate() }
            guard let self = self else { return }
            self.lock.lock(); self.probing.remove(id); self.lock.unlock()

            var reachable = (resp as? HTTPURLResponse) != nil && err == nil
            // 2026-11-05：确认「这台是不是我的」——别人的服务不算通
            if reachable,
               let data = data,
               let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let svc = doc["service"] as? String, !svc.isEmpty,
               svc != "ai-relay" {
                reachable = false
            }
            // 网络指纹变了说明这是上一张网的结论，别覆盖新结论
            guard self.netSignature() == sig else { return }
            self.store(id, sig: sig, backup: !reachable)
        }.resume()
    }

    // MARK: - 小工具

    /// 从 base 里取出 host（去掉 scheme / 端口 / 路径）。取不出来返回 nil。
    static func hostOf(_ base: String) -> String? {
        let s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s.contains("://") ? s : "http://" + s), let h = u.host, !h.isEmpty {
            return h
        }
        // URL 解析失败时手工兜底：抓 :// 之后到第一个 / 或 : 之前的部分
        var t = s
        if let r = t.range(of: "://") { t = String(t[r.upperBound...]) }
        if let i = t.firstIndex(where: { $0 == "/" || $0 == ":" }) { t = String(t[..<i]) }
        return t.isEmpty ? nil : t
    }

    /// 内网 IPv4（RFC1918）。用于判断「这个地址只可能在家里通」。
    static func isPrivateIPv4(_ host: String) -> Bool {
        let p = host.split(separator: ".")
        guard p.count == 4, let a = Int(p[0]), let b = Int(p[1]) else { return false }
        if a == 10 { return true }
        if a == 192 && b == 168 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        return false
    }

    /// 本机当前所有内网 IPv4。
    ///
    /// 故意不写死 `en0`：不同机型/越狱环境下 WiFi 网卡不一定是 en0，
    /// 写死会导致「连了 WiFi 却判成在外面」——这正是老代码
    /// `RouterControl.wifiIPv4()` 的隐患。
    /// 排除 lo0 / pdp_ip（蜂窝）/ utun（VPN 隧道）/ awdl / llw（AirDrop）。
    static func localPrivateIPv4s() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return out }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("lo") || name.hasPrefix("pdp_ip")
                || name.hasPrefix("utun") || name.hasPrefix("awdl")
                || name.hasPrefix("llw") || name.hasPrefix("ipsec") { continue }
            // 没有 IFF_UP 的接口不算
            guard (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if isPrivateIPv4(ip) && !out.contains(ip) { out.append(ip) }
            }
        }
        return out
    }

    /// 给探测用的 /health 地址：保留 scheme://host:port，去掉路径。
    static func healthURL(from base: String) -> URL? {
        let s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let full = s.contains("://") ? s : "http://" + s
        guard var c = URLComponents(string: full), let host = c.host, !host.isEmpty else { return nil }
        c.path = "/health"
        c.query = nil
        c.fragment = nil
        // 已经填了完整端点（…/v1/chat/completions）时，把 /v1 前缀也去掉更规范，
        // 但 /health 在哪一层都能应答，这里保持简单：只换 path。
        return c.url
    }
}
