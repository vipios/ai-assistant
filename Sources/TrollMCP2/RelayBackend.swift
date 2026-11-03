import Foundation

// MARK: - 中转站后台数据读取
//
// 2026-11-03 新增。为路由器页的「设备状态卡」和「公网地址卡」提供数据。
//
// 所有字段都按设备**实测返回**来写（2026-11-03 实测 /admin/api/device 返回）：
//   {"uptime":34530, "uptime_text":"9 小时 35 分钟", "mem_total_kb":119220,
//    "mem_avail_kb":13732, "swap_used_pct":77, "load":[1.04,0.69,0.67],
//    "relay_rss_kb":11836, "should_reboot":false}
// 字段缺失一律给默认值，绝不因为某个字段没返回就整张卡报错。

// MARK: 设备状态

struct RelayDeviceStatus {
    var uptimeSeconds: Double = 0
    var uptimeText: String = "—"
    var memTotalKB: Int = 0
    var memAvailKB: Int = 0
    var swapUsedPct: Double = 0
    var load: [Double] = []
    var relayRssKB: Int = 0
    var shouldReboot: Bool = false

    /// 可用内存显示。低于 20MB 标黄——实测这台设备可用经常只有 13MB，很紧张。
    var memAvailText: String {
        guard memAvailKB > 0 else { return "—" }
        let mb = Double(memAvailKB) / 1024
        let total = memTotalKB > 0 ? String(format: "/%.0fM", Double(memTotalKB) / 1024) : ""
        return String(format: "%.0fM%@", mb, total)
    }

    var memLow: Bool { memAvailKB > 0 && memAvailKB < 20 * 1024 }

    /// 负载显示：取 1 分钟值，>1 说明单核算力已经吃满（这设备就是单核）
    var loadText: String {
        guard let first = load.first else { return "—" }
        return String(format: "%.2f", first)
    }

    var loadHigh: Bool { (load.first ?? 0) > 1.0 }

    /// 中转站进程占用
    var relayRssText: String {
        guard relayRssKB > 0 else { return "—" }
        return String(format: "%.0f MB", Double(relayRssKB) / 1024)
    }

    /// 交换内存用到 70% 以上基本就是「后台进不去、一直转圈」的前兆。
    var swapHigh: Bool { swapUsedPct >= 70 }
}

// MARK: 公网地址

struct RelayPublicAddress {
    var ipv6: [String] = []
    var port: Int = 8080
    var updated: String = ""
    var service: String = ""

    /// 显示哪个地址：优先域名（页面里如果 Gist 带了 domain 字段），
    /// 否则用第一个 IPv6。都没有就给一句人话。
    var bestAddress: String {
        if let d = domain, !d.isEmpty { return d }
        if let first = ipv6.first, !first.isEmpty { return "http://[\(first)]:\(port)" }
        return "（Gist 里还没写地址）"
    }

    /// 可选域名（Gist 里可能有，没有就 nil）
    var domain: String? = nil

    /// 「12:45」这种短时间；Gist 里的 updated 是 "2026-11-03 12:45:39"
    var updatedText: String {
        guard !updated.isEmpty else { return "未知" }
        if let t = updated.split(separator: " ").last {
            let parts = t.split(separator: ":")
            if parts.count >= 2 { return "\(parts[0]):\(parts[1])" }
        }
        return updated
    }
}

// MARK: 网络层

enum RelayBackend {

    /// 规范化基地址：补协议、去尾斜杠
    private static func normalize(_ base: String) -> String? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        return s
    }

    private static func get(_ url: URL, key: String?,
                            timeout: TimeInterval = 8,
                            done: @escaping (Data?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        // **必须用项目封装的 setHTTPMethod**，不能写 req.httpMethod = "GET"。
        // 原因见 UIComponents.swift 的注释：URLRequest.httpMethod 的 Swift setter
        // 是 iOS 16+ 的 ABI 符号，iOS 15.6 上会 dyld: Symbol not found 直接闪退。
        setHTTPMethod("GET", on: &req)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // 必须带正常 UA：中转站前面挂着 Cloudflare，裸 UA 会被 1010 拒掉
        req.setValue("AIRelayChat/1.0 CFNetwork/1410.0.3 Darwin/22.6.0",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let k = key, !k.isEmpty {
            req.setValue(k, forHTTPHeaderField: "X-Access-Key")
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                done((200...299).contains(code) ? data : nil)
            }
        }.resume()
    }

    // MARK: 设备状态

    /// GET {base}/admin/api/device —— 失败时返回中文原因，页面直接展示
    static func fetchDeviceStatus(base: String,
                                  key: String,
                                  done: @escaping (Result<RelayDeviceStatus, String>) -> Void) {
        guard let b = normalize(base), let url = URL(string: b + "/admin/api/device") else {
            done(.failure("后台地址格式不对"))
            return
        }
        get(url, key: key) { data in
            guard let data = data,
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                done(.failure("连不上后台。在家请确认连着 WiFi，在外面先开 ZeroTier；密钥错也会这样。"))
                return
            }
            var d = RelayDeviceStatus()
            d.uptimeSeconds = (doc["uptime"] as? Double) ?? Double(doc["uptime"] as? Int ?? 0)
            if let t = doc["uptime_text"] as? String, !t.isEmpty { d.uptimeText = t }
            d.memTotalKB = (doc["mem_total_kb"] as? Int) ?? Int(doc["mem_total_kb"] as? Double ?? 0)
            d.memAvailKB = (doc["mem_avail_kb"] as? Int) ?? Int(doc["mem_avail_kb"] as? Double ?? 0)
            d.swapUsedPct = (doc["swap_used_pct"] as? Double) ?? Double(doc["swap_used_pct"] as? Int ?? 0)
            if let arr = doc["load"] as? [Any] {
                d.load = arr.compactMap { ($0 as? NSNumber)?.doubleValue }
            }
            d.relayRssKB = (doc["relay_rss_kb"] as? Int) ?? Int(doc["relay_rss_kb"] as? Double ?? 0)
            d.shouldReboot = (doc["should_reboot"] as? Bool) ?? false
            done(.success(d))
        }
    }

    // MARK: 公网地址（Gist）

    /// 设备把当前地址写到这个 Gist，每 3 分钟一次。
    /// 用户要求：「点击开 ipa 就自动刷新 Gist ID 获取最新的公网地址」。
    ///
    /// 走 api.github.com（实测 200），不走上游 raw 域名——
    /// 后者对 `raw/<文件名>` 这种路径会 404，我之前踩过。
    static let gistID = "a96bdb5d96de46975334ca3276476901"

    static func fetchPublicAddress(done: @escaping (Result<RelayPublicAddress, String>) -> Void) {
        guard let url = URL(string: "https://api.github.com/gists/" + gistID) else {
            done(.failure("Gist 地址无效"))
            return
        }
        get(url, key: nil, timeout: 12) { data in
            guard let data = data,
                  let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = doc["files"] as? [String: Any] else {
                done(.failure("取不到公网地址（可能是网络问题）。这不影响在家用内网地址。"))
                return
            }
            // 文件名不写死：设备端以后改名字也不该让这里瞎掉
            var content: [String: Any]?
            if let f = files["relay-addr.json"] as? [String: Any] {
                content = f
            } else {
                for (_, v) in files {
                    if let f = v as? [String: Any], f["content"] != nil { content = f; break }
                }
            }
            guard let f = content,
                  let text = f["content"] as? String,
                  let raw = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                done(.failure("Gist 内容看不懂，设备可能还没写过地址"))
                return
            }
            var p = RelayPublicAddress()
            p.service = (obj["service"] as? String) ?? ""
            p.updated = (obj["updated"] as? String) ?? ""
            p.port = (obj["port"] as? Int) ?? 8080
            if let v6 = obj["ipv6"] as? [String] { p.ipv6 = v6 }
            if let dm = obj["domain"] as? String, !dm.isEmpty { p.domain = dm }
            done(.success(p))
        }
    }
}
