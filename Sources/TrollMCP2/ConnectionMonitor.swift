import Foundation
import Combine

/// 顶栏「模型名」旁边那颗状态灯的**真实**来源（2026-11-03）。
///
/// 改之前那颗点是写死的 `.foregroundColor(.green)`——没配模型、断网、
/// 密钥过期、路由器关机，它都亮着绿灯，等于没有信息。
///
/// 现在三个信号源，按可信度从高到低：
///   1. 真实聊天请求的成败（`OpenAIClient` 每发完一次就回报）——最可信
///   2. 打开聊天页 / 回前台 / 网络恢复时主动探一次 `GET {base}/models`
///   3. 停留聊天页期间每 25 秒兜底探一次（只在页面可见时跑，离开即停）
///
/// 探活走 `effectiveBaseURL`：在家/在外自动选对那条接口，
/// 不会出现「明明在家却拿公网域名去探、慢三秒还误判失败」。
final class ConnectionMonitor: ObservableObject {
    static let shared = ConnectionMonitor()
    private init() {}

    enum State {
        case unknown     // 还没探过 / 没配模型
        case online      // 能用（绿灯）
        case offline     // 连不上（红灯）

        var isOnline: Bool { self == .online }
    }

    /// 对外只暴露「在线/离线/未知」三种稳定状态。
    /// 探测过程中的中间态不写进 state——否则每 25 秒绿灯闪一下灰，很廉价。
    @Published private(set) var state: State = .unknown
    /// 绿灯/红灯的原因，点开模型弹窗或设置页可以显示
    @Published private(set) var detail: String = ""
    /// 是否正在探测（只用于「小转圈」这类轻提示，不影响灯色）
    @Published private(set) var isChecking = false

    private var checkedAt: Date?
    private var probing = false
    private let lock = NSLock()

    private var timer: Timer?
    /// 主动探测的最小间隔：真实请求刚成功过就别再探，省一次往返
    private let minProbeGap: TimeInterval = 12

    // MARK: - 对外：由真实请求回报（最高可信度）

    /// `OpenAIClient` 每次请求结束都会调这里。
    /// 注意「失败」要分类：参数错/限流说明链路是通的，不该判红。
    func report(success: Bool, error: Error? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.probing = false
            self.lock.unlock()

            if success {
                self.apply(.online, detail: "")
                return
            }
            guard let err = error else {
                self.apply(.offline, detail: "")
                return
            }
            let ns = err as NSError
            if ns.domain == NSURLErrorDomain {
                self.apply(.offline, detail: "网络不通")
                return
            }
            switch ns.code {
            case 401, 403:
                self.apply(.offline, detail: "密钥不对")
            case 429:
                // 限流 = 服务是活的，只是暂时不给。绿灯更贴近事实。
                self.apply(.online, detail: "限流中")
            case 200..<300:
                self.apply(.online, detail: "")
            default:
                self.apply(.offline, detail: "HTTP \(ns.code)")
            }
        }
    }

    // MARK: - 对外：主动探活

    /// - Parameter force: true 时忽略 `minProbeGap`（用户手动触发、回前台等）
    func probe(force: Bool = false) {
        guard let cfg = ModelStore.shared.defaultConfig else {
            apply(.unknown, detail: "未配置模型")
            return
        }
        // 没有地址 / 没有模型 → 根本没得连，直接红
        let base = cfg.effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            apply(.offline, detail: "接口地址为空")
            return
        }

        lock.lock()
        if probing { lock.unlock(); return }
        if !force, let at = checkedAt, Date().timeIntervalSince(at) < minProbeGap {
            lock.unlock()
            return
        }
        probing = true
        lock.unlock()

        DispatchQueue.main.async { [weak self] in self?.isChecking = true }

        guard let req = Self.makeRequest(cfg) else {
            lock.lock(); probing = false; lock.unlock()
            apply(.offline, detail: "接口地址格式不对")
            return
        }
        fire(req, cfg: cfg, allowBaseRetry: true)
    }

    /// 网络一恢复、或用户从后台回来，立刻重判，别让红点挂在那里骗人。
    func refreshNow() {
        probe(force: true)
    }

    // MARK: - 自动探测（只在聊天页可见时跑）

    func startAutoProbe() {
        stopAutoProbe()
        probe()
        let t = Timer(timeInterval: 25, repeats: true) { [weak self] _ in
            self?.probe()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAutoProbe() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 实现

    private func fire(_ req: URLRequest, cfg: ModelConfig, allowBaseRetry: Bool) {
        let conf = URLSessionConfiguration.ephemeral
        conf.timeoutIntervalForRequest = 6
        conf.timeoutIntervalForResource = 8
        conf.waitsForConnectivity = false
        conf.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: conf)

        session.dataTask(with: req) { [weak self] _, resp, err in
            defer { session.finishTasksAndInvalidate() }
            guard let self = self else { return }

            let http = resp as? HTTPURLResponse
            let ns = err as NSError?

            // 纯网络错误：先让路由器翻到备用接口，再用新地址补一发。
            // 光翻面不重试的话，灯会一直红到下一次周期，用户看不到「已经切过去了」。
            if let ns = ns, ns.domain == NSURLErrorDomain {
                let hasBackup = !cfg.backupBaseURL
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if allowBaseRetry && hasBackup {
                    BaseURLRouter.shared.markFailed(base: cfg.effectiveBaseURL, config: cfg)
                    NetworkLog.shared.log("连接检测：\(cfg.name) 主接口不通 → 切备用接口重探")
                    if let retry = Self.makeRequest(cfg) {
                        self.fire(retry, cfg: cfg, allowBaseRetry: false)
                        return
                    }
                }
                self.finish(.offline, detail: Self.describe(ns))
                return
            }

            guard let http = http else {
                self.finish(.offline, detail: "无响应")
                return
            }
            // 200~299 才算真能用；401/403 是密钥问题，5xx 是上游坏了，都红。
            // 429 例外——服务活着，只是不给，绿灯更贴近事实。
            switch http.statusCode {
            case 200..<300:
                self.finish(.online, detail: "")
            case 401, 403:
                self.finish(.offline, detail: "密钥不对（HTTP \(http.statusCode)）")
            case 429:
                self.finish(.online, detail: "限流中")
            default:
                self.finish(.offline, detail: "HTTP \(http.statusCode)")
            }
        }.resume()
    }

    private func finish(_ s: State, detail: String) {
        lock.lock(); probing = false; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.isChecking = false
            self?.apply(s, detail: detail)
        }
    }

    private func apply(_ s: State, detail: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.checkedAt = Date()
            if self.detail != detail { self.detail = detail }
            if self.state != s { self.state = s }
        }
    }

    // MARK: - 请求构造

    private static func makeRequest(_ cfg: ModelConfig) -> URLRequest? {
        // 复用 modelsEndpoint：自动剥 /v1/chat/completions 之类的端点后缀，
        // 纯主机自动补 /v1 → 用户填什么形式都能探。
        let endpoint = ModelConfig.modelsEndpoint(cfg.effectiveBaseURL)
        guard !endpoint.isEmpty, let url = URL(string: endpoint) else { return nil }

        var req = URLRequest(url: url, timeoutInterval: 6)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 必须带正常 UA：中转站前面挂着 Cloudflare Browser Integrity Check，
        // 裸 UA / 空 UA 会被直接甩 error code: 1010（HTTP 403），
        // 表现就是「明明通着却一直红」。
        var ua = "AIRelayChat/1.0 CFNetwork/1410.0.3 Darwin/22.6.0"
        if let v = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !v.isEmpty {
            ua = "AIRelayChat/\(v) CFNetwork/1410.0.3 Darwin/22.6.0"
        }
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let key = cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch cfg.authMethod {
        case "Bearer":
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case "API Key":
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        case "None":
            break
        default:
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        return req
    }

    private static func describe(_ e: NSError) -> String {
        switch e.code {
        case NSURLErrorTimedOut:          return "连接超时"
        case NSURLErrorCannotConnectToHost: return "连不上主机"
        case NSURLErrorCannotFindHost:    return "找不到主机"
        case NSURLErrorNotConnectedToInternet: return "没有网络"
        case NSURLErrorNetworkConnectionLost:  return "连接中断"
        case NSURLErrorDNSLookupFailed:   return "DNS 失败"
        default:                          return "网络错误 \(e.code)"
        }
    }
}
