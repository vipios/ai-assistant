import Foundation
import SwiftUI
// getifaddrs / freeifaddrs / NI_MAXHOST 来自 Darwin；SwiftUI 会间接带入，
// 但这里显式引入，避免依赖头文件传递关系（换 Swift 版本时容易断）
import Darwin

/// 路由器控制通道（2026-11-02 从 AIRelayChat 移植）。
///
/// 为什么要有两条通道：
/// 1. **直连 `/cgi-bin/airboot`**（首选）——路由器上由 uhttpd + C 进程托管，跟 relay.py
///    毫无关系。中转站是这套系统里最容易卡死的组件（Python 单进程，内存一紧张就 swap
///    颠簸），真到了「后台进不去、想重启」的时候，走中转站发重启指令必然也发不出去。
///    所以重启必须有一条不经过 Python 的路。
/// 2. **中转站 `/admin/api/device/reboot`**（兜底）——人在外面没开 ZeroTier 时，
///    只有经过中转站（或其后面的 Cloudflare 隧道）才够得着。
///
/// 判断 airboot 的依据是返回 `"svc":"airboot"`，避免把光猫/别的路由器误认成自家设备。
enum RouterControl {

    /// CGI 路径，对应设备上的 `/www/cgi-bin/airboot`
    static let bootPath = "/cgi-bin/airboot"

    /// 单次探测超时。
    /// 给 1.2 秒而不是 0.4 秒：uhttpd 要 fork+exec 一个 shell 脚本，路由器 CPU 很弱，
    /// 0.4 秒经常还没 exec 完就被判超时，结果「明明在家却显示连不上」。
    static let probeTimeout: TimeInterval = 1.2

    /// 内网候选地址（按可信度排序）。
    /// 用户手动填的 > 真的连通过的历史地址 > 当前 WiFi 网段推导 > 已知固定地址。
    static func lanCandidates() -> [String] {
        var list: [String] = []
        func add(_ h: String) {
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !list.contains(t) else { return }
            list.append(t)
        }

        // 1) 用户手动填的，最可信
        add(UserDefaults.standard.string(forKey: "router.custom_host") ?? "")

        // 2) 学到过的地址池（真的连通过的，比任何猜测可靠）
        if let pool = UserDefaults.standard.array(forKey: "router.host_pool") as? [String] {
            for h in pool { add(h) }
        }

        // 3) 当前 WiFi 网段推导——家用路由常见尾号都列上；
        //    并发探测，多一个候选不增加总耗时（最坏等最慢那个）
        if let myIP = RouterControl.wifiIPv4() {
            let p = myIP.split(separator: ".")
            if p.count == 4 {
                let seg = "\(p[0]).\(p[1]).\(p[2])"
                for tail in ["88", "250", "1", "2", "254", "100", "10", "8", "18", "3"] {
                    add("\(seg).\(tail)")
                }
            }
        }

        // 4) 已知固定地址兜底（192.168.1.88 是家里路由；
        //    10.47.67.100 是它的 ZeroTier 固定 IP，人在外面装了 ZeroTier 也能走）
        for h in ["192.168.1.88", "10.47.67.100", "192.168.1.250", "192.168.2.1"] {
            add(h)
        }
        return list
    }

    /// 取当前 WiFi 的 IPv4（en0）。拿不到（没连 WiFi/用流量）返回 nil。
    static func wifiIPv4() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                addr = String(cString: host)
            }
        }
        return addr
    }

    // MARK: - 探活 / 找地址

    /// 这个地址上有没有 airboot 通道。
    /// 用 ephemeral session：不复用 cookie/连接池，避免拿着已死掉的连接干等。
    static func ping(host: String, timeout: TimeInterval = 1.2) async -> Bool {
        guard let u = bootURL(host: host, query: "action=ping") else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (doc["ok"] as? Bool) == true && (doc["svc"] as? String) == "airboot"
    }

    /// 并发探一批候选，谁先应答用谁（串行最坏要十几秒，并发只等最慢那个 1.2 秒）。
    /// 命中后把地址记进池子，下次换网段也更容易命中。
    static func discover(candidates: [String], timeout: TimeInterval = 1.2) async -> String? {
        var seen = Set<String>()
        let hosts = candidates.compactMap { h -> String? in
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t) else { return nil }
            seen.insert(t)
            return t
        }
        guard !hosts.isEmpty else { return nil }

        let hit = await withTaskGroup(of: String?.self) { group -> String? in
            for h in hosts {
                group.addTask { await ping(host: h, timeout: timeout) ? h : nil }
            }
            for await r in group {
                if let h = r {
                    group.cancelAll()
                    return h
                }
            }
            return nil
        }
        if let hit { remember(host: hit) }
        return hit
    }

    /// 学到一个真的能用的地址（最多留 8 个，最近的排前面）。
    private static func remember(host: String) {
        guard !host.contains("://") else { return }
        var pool = (UserDefaults.standard.array(forKey: "router.host_pool") as? [String]) ?? []
        pool.removeAll { $0 == host }
        pool.insert(host, at: 0)
        if pool.count > 8 { pool = Array(pool.prefix(8)) }
        UserDefaults.standard.set(pool, forKey: "router.host_pool")
    }

    // MARK: - 双通道路由（2026-11-04 新增）
    //
    // 用户诉求（原话）：
    //   「路由器界面点击进去就能自动刷新是链接 wifi 还是没有链接 wifi 自动判定，
    //    在家就用 wifi 直连 ip 进行登录，判定是没链接 wifi 就自动切换成域名，
    //    同时如果我在这个页面停留了，一开始链接了 wifi 他是家里的 ip，
    //    在界面停留期间关闭 wifi 他要自动检测到」
    //
    // 为什么必须拆成两个地址（老代码的真正病根）：
    //   airboot（重启指令）在 uhttpd 的 **80** 端口；
    //   设备状态 / 后台接口在 relay.py 的 **8080** 端口。
    //   老代码只有一个 foundHost（裸 IP，不带端口），同时喂给这两个通道：
    //     - 喂给后台接口 → http://192.168.1.88/admin/api/device → 打到 80 → 404
    //     - 喂给 airboot   → 正确
    //   所以「有时能进有时进不去」不是网络问题，是**一个变量喂错端口**。
    //   现在明确拆成 adminBase（8080 / 域名）和 bootBase（80 / 域名）。

    /// 外网域名（Cloudflare 隧道）。
    /// Gist 里如果带了 domain 字段就优先用那个，没带就用这个常量。
    static let defaultWanHost = "lidongyang.dpdns.org"

    /// 用户可以在设置里改；留空 = 用默认域名
    static var wanHost: String {
        let v = (UserDefaults.standard.string(forKey: "router.wan_host") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? defaultWanHost : v
    }

    /// 一条可用线路。字段含义见上方注释。
    struct Route {
        /// true = 内网直连；false = 走域名（外网）
        var isLan: Bool
        /// 后台接口基地址——设备状态、鉴权接口用它（内网一定带 :8080）
        var adminBase: String
        /// airboot 基地址——重启指令用它（内网是 80，外网是域名）
        var bootBase: String
        /// 界面显示：内网直连 / 外网
        var label: String
        /// 界面显示：实际地址
        var detail: String
    }

    /// 判定当前该走哪条线路。**页面上唯一的「找地址」入口**，别再各找各的。
    ///
    /// 判定顺序（和 BaseURLRouter 的思路一致，避免两套逻辑打架）：
    ///   1. 本机没有任何内网 IPv4  → 在用流量/没连 WiFi → 直接走域名（零成本）
    ///   2. 有内网 IPv4 → 并发探 airboot，探到就是在家 → 内网直连
    ///   3. 连了 WiFi 却探不到 airboot（路由器 80 挂了 / 换了别人家的网）→ 退回域名
    static func resolveRoute() async -> Route {
        let wan = Route(isLan: false,
                        adminBase: "https://" + wanHost,
                        bootBase: "https://" + wanHost,
                        label: "外网",
                        detail: wanHost)

        // 1) 没有任何内网 IPv4 = 没连 WiFi（或用流量）→ 外面的域名
        guard !BaseURLRouter.localPrivateIPv4s().isEmpty else { return wan }

        // 2) 在家：探 airboot，命中才算真的在家
        if let hit = await discover(candidates: lanCandidates()) {
            return Route(isLan: true,
                         adminBase: "http://\(hit):8080",
                         bootBase: "http://\(hit)",
                         label: "内网直连",
                         detail: hit)
        }

        // 3) 连了 WiFi 但 80 探不到 → 走域名。
        //    这时域名后面是 relay.py(8080)，设备状态照样能读到，
        //    比「一直转圈什么也看不到」好。
        return wan
    }

    /// 网络指纹：当前内网 IP 集合。变了就说明换了网络（WiFi↔蜂窝 / 换网段）。
    static func netSignature() -> String {
        let locals = BaseURLRouter.localPrivateIPv4s().sorted()
        return locals.isEmpty ? "no-lan" : locals.joined(separator: ",")
    }

    // MARK: - 发指令

    /// 重启整台路由器（全家断网约 40 秒）。
    /// 服务端先回 200 再真重启（延迟 2 秒），拿到响应只代表「指令已受理」。
    static func reboot(host: String, key: String, timeout: TimeInterval = 8) async throws {
        try await send(action: "reboot", host: host, key: key, timeout: timeout)
    }

    /// 只重启中转站服务，路由器本身不动。
    /// 大部分「后台进不去 / 一直转圈」其实是 relay.py 自己卡了，用这个 1 秒就好；
    /// 重启整台路由器是最后手段。
    static func restartRelay(host: String, key: String, timeout: TimeInterval = 8) async throws {
        try await send(action: "relay", host: host, key: key, timeout: timeout)
    }

    private static func send(action: String, host: String, key: String,
                             timeout: TimeInterval) async throws {
        guard !key.isEmpty else { throw RouterError.noKey }
        guard let u = bootURL(host: host, query: "action=" + action + "&k=" + escaped(key)) else {
            throw RouterError.badHost
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 500/502 也算成功：脚本已经 exec 了 reboot，uhttpd 等不到输出就报错，
        // 这种其实「已经重启了」，当失败处理会让用户重复点。
        if code != 200 && code != 500 && code != 502 {
            throw RouterError.http(code)
        }
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if code == 500 || code == 502 { return }
            throw RouterError.badReply
        }
        if (doc["ok"] as? Bool) == true { return }
        let err = (doc["err"] as? String) ?? ""
        switch err {
        case "bad-key", "no-token": throw RouterError.badKey
        case "lan-only":            throw RouterError.notLan
        default:                    throw RouterError.rejected(err)
        }
    }

    // MARK: - 地址拼装

    /// 候选可以是裸 IP（内网），也可以是带协议的完整地址（公网域名）。
    /// 在家走 `http://192.168.1.88`，在外面走 `https://<域名>`，两者只差一个前缀，
    /// 没必要写两套。
    static func bootURL(host: String, query: String) -> URL? {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix("/") { h = String(h.dropLast()) }
        guard !h.isEmpty else { return nil }
        if !h.contains("://") { h = "http://" + h }
        return URL(string: h + bootPath + "?" + query)
    }

    private static func escaped(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

enum RouterError: LocalizedError {
    case noKey, badHost, badKey, notLan, badReply, http(Int), rejected(String), noAccessKey

    var errorDescription: String? {
        switch self {
        case .noKey:            return L10n.t("i18n_1544")
        case .badHost:          return L10n.t("i18n_1545")
        case .badKey:           return L10n.t("i18n_1546")
        case .notLan:           return L10n.t("i18n_1547")
        case .badReply:         return L10n.t("i18n_1548")
        case .http(let c):      return L10n.t("i18n_1549", c)
        case .rejected(let e):  return L10n.t("i18n_1550", e)
        case .noAccessKey:      return L10n.t("i18n_1551")
        }
    }
}
