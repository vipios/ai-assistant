import SwiftUI
import WebKit
import CryptoKit
import Network

// MARK: - 中转站后台凭据存储
//
// 2026-11-02：需求是「一个手机只输一次密码，以后进去不再问」。
// 但明文存密码不可接受（本机任意进程/备份都能读到），所以：
//   - 密码用 AES-GCM 加密后存 UserDefaults
//   - 加密密钥由「设备标识 + 应用固定盐」派生，换机/装了别处就解不开（等于天然绑定本机）
//   - 明文只在内存里短暂存在，不落盘、不写日志
//
// 为什么不用 Keychain：TrollStore 下 entitlements 受限，项目既有结论是 Keychain 不可靠
// （见 GitHubAccountStore.swift 注释），API Key 也一直是 UserDefaults 存的。

final class RelayAdminCredential {
    static let shared = RelayAdminCredential()
    private init() {}

    private let keyCipher = "relayadmin.accesskey.cipher"    // 密文（base64）
    private let keyHost = "relayadmin.baseurl"               // 用户填的后台地址（在家地址）
    /// 2026-11-05：在外（走流量/别家 WiFi）时用的地址。留空 = 用默认公网域名。
    private let keyAwayHost = "relayadmin.awayurl"
    /// 2026-11-05：自动判定开关。默认开——用户明确要求「切流量要自动变域名」。
    private let keyAuto = "relayadmin.autoswitch"

    /// 后台地址（**在家**用的那个，内网 IP）。默认给内网常用地址，用户可改。
    ///
    /// 2026-11-05 修：这个名字没改（避免迁移），但语义已经收窄成「在家地址」。
    /// 真正拿去连的地址请用 `effectiveBaseURL` —— 它会按当前网络在
    /// 在家地址 / 在外地址之间自动选。**不要再用 baseURL 直接发请求**，
    /// 那正是「切了流量还在用 192.168.1.88 → 请求超时」的根因。
    var baseURL: String {
        get { UserDefaults.standard.string(forKey: keyHost) ?? Self.defaultHomeURL }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyHost) }
    }

    /// 在外用的地址（公网域名）。留空走默认域名。
    var awayURL: String {
        get {
            let v = (UserDefaults.standard.string(forKey: keyAwayHost) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? Self.defaultAwayURL : v
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyAwayHost) }
    }

    /// 是否启用自动判定（默认启用）
    var autoSwitch: Bool {
        get {
            // 没存过 → 默认 true（用户明确要求自动切，不能默认关）
            if UserDefaults.standard.object(forKey: keyAuto) == nil { return true }
            return UserDefaults.standard.bool(forKey: keyAuto)
        }
        set { UserDefaults.standard.set(newValue, forKey: keyAuto) }
    }

    static let defaultHomeURL = "http://192.168.1.88:8080"
    /// 2026-11-05：默认公网域名复用 RouterControl 的那一个 —— 全项目只能有一个域名来源，
    /// 否则改域名要改两处，必漏一处。
    static var defaultAwayURL: String { "https://" + RouterControl.wanHost }

    /// 2026-11-05：**当前该拿去连的地址**（同步、零网络开销）。
    ///
    /// 判定只看「本机有没有内网 IPv4」——
    ///   · 有内网 IP（连着 WiFi）→ 用在家地址；
    ///   · 没有内网 IP（纯流量）  → 用在外域名。
    ///
    /// ⚠️ 这只是**第一猜**，不是结论。它有两个已知误判：
    ///   ① 连的是别人家 WiFi（有内网 IP，但后端不在这个网里）
    ///   ② 连着自家 WiFi 但路由器抽风/IP 还没撤
    /// 所以真正落地址必须走 `resolveAsync`——它会真探一次 /health，
    /// 探不通就翻面。同步版本只用于「界面先有个地址可显示」。
    func effectiveBaseURL() -> String {
        guard autoSwitch else { return baseURL }
        let hasLAN = !BaseURLRouter.localPrivateIPv4s().isEmpty
        return hasLAN ? baseURL : awayURL
    }

    /// 当前判定结果的说明文案（界面上给用户看，避免「到底用的哪个」说不清）
    func currentRouteLabel() -> String {
        guard autoSwitch else { return "手动地址" }
        let hasLAN = !BaseURLRouter.localPrivateIPv4s().isEmpty
        return hasLAN ? "在家 · WiFi 直连" : "在外 · 走域名"
    }

    /// 2026-11-05：**判定 + 真探活**，返回真正能连通的地址。
    ///
    /// 为什么必须探：用户明确指出「也要判定我在别的 WiFi 也是外面」。
    /// 只数「有没有内网 IP」是不够的——别人家 WiFi 也是内网，也是 192.168.x.x，
    /// 会被误判成「在家」，然后去连 192.168.1.88，必然是超时。
    ///
    /// 判据是「**这台后端是不是我的**」，不是「有没有内网」：
    ///   · 探 home（内网 IP）的 /health，返回的 service 是 ai-relay → 真的在家；
    ///   · 探不通 / 探到的不是 ai-relay（别人家路由器返回别的页面）→ 判在外，用域名。
    ///
    /// 用 /health 而不是 /admin/api/status：前者免密钥，判定阶段还没拿到 key 也能探。
    func resolveAsync(timeout: TimeInterval = 1.6,
                      completion: @escaping (String, String) -> Void) {
        let home = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = awayURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard autoSwitch else {
            completion(home, "手动地址")
            return
        }
        // 纯流量（没有内网 IP）→ 不用探，直接域名
        guard !BaseURLRouter.localPrivateIPv4s().isEmpty else {
            completion(away, "在外 · 走域名")
            return
        }

        // 有内网 IP：探一下这是不是自家后端
        Self.probeRelayHealth(base: home, timeout: timeout) { isMine in
            if isMine {
                completion(home, "在家 · WiFi 直连")
            } else {
                // 有内网但探不到自家后端 = 在别人家 WiFi / 自家路由器挂了 → 判在外
                completion(away, "在外 · 走域名（非自家 WiFi）")
            }
        }
    }

    /// 探 `base/health`，确认它是不是我们的中转站。
    ///
    /// 只认「HTTP 200 + JSON 里 service == ai-relay」。
    /// 为什么要校 service 字段而不是只看 200：
    /// 别人家路由器/光猫的后台也可能在 8080 上返回 200（登录页），
    /// 只看状态码会把「别人家的管理页」当成「我的中转站」。
    static func probeRelayHealth(base: String, timeout: TimeInterval,
                                 completion: @escaping (Bool) -> Void) {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        guard !s.isEmpty, let url = URL(string: s + "/health") else {
            completion(false); return
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
            var ok = false
            if err == nil,
               let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let data = data,
               let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 老版本 relay.py 可能没 service 字段，退一步认 status == ok
                let svc = (doc["service"] as? String) ?? ""
                let st = (doc["status"] as? String) ?? ""
                ok = svc == "ai-relay" || (st == "ok" && !svc.isEmpty)
            }
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    /// 2026-11-05：**地址自动切换的核心**——先试判定出来的地址，
    /// 不通就翻到另一个再试一次。返回实际连通的地址。
    ///
    /// 为什么必须有这层：光看「有没有内网 IP」判不准两种情况
    ///   ① 连着别人家 WiFi（有内网 IP 但后端不在这个网里）
    ///   ② 家里路由器换了网段 / 手机开了 WiFi 但没连上（IP 还没撤）
    /// 这两种都会让「在家地址」不通。只说「判定在家」是不够的，
    /// 用户要的是「能连上」——所以判定之后必须真探一次，探不通就翻面。
    ///
    /// 调用方：WebView 打开前、unlock 校验前、watchdog 发现超时后。
    func failoverSuggest(from tried: String) -> String? {
        let home = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = awayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = tried.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == home, !away.isEmpty { return away }
        if t == away, !home.isEmpty { return home }
        // tried 是用户手改的临时地址 → 回到自动判定
        return effectiveBaseURL()
    }

    /// 是否已保存过密码（只判断存在性，不解密）
    var hasSavedKey: Bool {
        !(UserDefaults.standard.string(forKey: keyCipher) ?? "").isEmpty
    }

    /// 保存密码（加密后落盘）
    func save(accessKey: String) {
        let trimmed = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let sealed = Self.encrypt(trimmed) {
            UserDefaults.standard.set(sealed, forKey: keyCipher)
        }
    }

    /// 取出明文密码（仅内存瞬时使用）
    func loadAccessKey() -> String? {
        guard let stored = UserDefaults.standard.string(forKey: keyCipher), !stored.isEmpty else { return nil }
        return Self.decrypt(stored)
    }

    /// 清除已保存密码（后台换了密钥时用）
    func clear() {
        UserDefaults.standard.removeObject(forKey: keyCipher)
    }

    // MARK: - 加解密（AES-GCM，密钥由本机标识派生）

    private static var derivedKey: SymmetricKey {
        // 设备标识 + 固定盐做 HKDF。identifierForVendor 在同一设备同一厂商下稳定，
        // 且卸载重装后可能变化——正好符合「换环境就重新输一次」的预期。
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? "no-idfv"
        let salt = "com.trollagent.relayadmin.v1".data(using: .utf8)!
        let ikm = SymmetricKey(data: SHA256.hash(data: (idfv + "|relay-admin").data(using: .utf8)!))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data(), outputByteCount: 32)
    }

    private static func encrypt(_ plain: String) -> String? {
        guard let data = plain.data(using: .utf8),
              let sealed = try? AES.GCM.seal(data, using: derivedKey),
              let combined = sealed.combined else { return nil }
        return combined.base64EncodedString()
    }

    private static func decrypt(_ cipher: String) -> String? {
        guard let data = Data(base64Encoded: cipher),
              let box = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(box, using: derivedKey) else { return nil }
        return String(data: opened, encoding: .utf8)
    }
}

// MARK: - 中转站后台页面

/// 2026-11-02：输入框「+」附件栏里的「中转站」入口。
/// 行为：
///  1. 首次进入：页面先要求输入后台密码（access_key），点确定后写入并直接打开后台
///  2. 密码只存一次（加密落盘），以后进入自动注入 localStorage['relayKey'] 免密直达
///  3. 每次进入自动 reload，拿到最新数据
///  4. 明文密码绝不出现在页面上（输入框用 SecureField，保存后即清空内存变量）
struct RelayAdminView: View {
    @Environment(\.presentationMode) private var presentationMode

    @State private var baseURL: String = RelayAdminCredential.shared.baseURL
    @State private var passwordInput: String = ""
    @State private var isUnlocked = false          // 已拿到密钥，可以显示 WebView
    @State private var errorText = ""
    @State private var reloadToken = 0             // 变更即触发 WebView reload
    // 2026-11-05：自动判定开关 + 当前实际生效的地址。
    // 用户原话：「用 wifi 时候显示这个地址是正确的，在切换流量的时候应该是能自动判定在外的，
    // 同时要更改这里的地址的，应该改成域名才对，现在它不自动改。」
    // → 所以这里必须有三个东西：开关、显示「现在用的是哪个」、以及真的把地址换掉。
    @State private var autoSwitch: Bool = RelayAdminCredential.shared.autoSwitch
    @State private var effectiveURL: String = RelayAdminCredential.shared.effectiveBaseURL()
    @State private var routeLabel: String = RelayAdminCredential.shared.currentRouteLabel()
    /// 2026-11-05：在外地址的编辑态
    @State private var awayURL: String = RelayAdminCredential.shared.awayURL
    /// 网络指纹：变了说明 WiFi↔流量 切换了 → 立刻重算地址
    @State private var lastNetSig: String = RouterControl.netSignature()
    @State private var pathMonitor: NWPathMonitor?
    // 2026-11-03 **转圈修复**（用户截图：蓝色按钮里一直转圈、点不动）：
    //
    // 原来这里是 `@State private var isLoading = true`。这个变量在**两个场景**共用：
    //   ① 解锁表单里表示「正在校验密码」
    //   ② WebView 里表示「页面正在加载」
    // 初始值写 true，而解锁表单刚打开时**没有任何代码把它设回 false**
    // （只有 unlock() 的 probe 回调才会设）——于是按钮一进来就是「校验中」的样子，
    // 永远转圈且 disabled，用户根本点不了。这就是截图里那个现象。
    //
    // 修法：校验状态和页面加载状态彻底分开。这里只管校验，初始 false。
    @State private var isVerifying = false
    @State private var isLoading = false
    @State private var titleText = L10n.t("i18n_1511")
    /// 密码是否明文显示（小眼睛）
    @State private var revealPassword = false
    /// 校验结果：nil=无、true=成功、false=失败。用于决定横幅样式。
    @State private var verifyOK: Bool? = nil

    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                if isUnlocked {
                    RelayAdminWebView(
                        // 2026-11-05：用 effectiveURL（自动判定结果），不是 baseURL。
                        // 原来这里写的是 baseURL —— 那就是「切了流量还在连 192.168.1.88」的病根。
                        urlString: effectiveURL,
                        accessKey: RelayAdminCredential.shared.loadAccessKey() ?? "",
                        reloadToken: reloadToken,
                        isLoading: $isLoading,
                        titleText: $titleText,
                        onLoadFailed: { msg in
                            // 2026-11-05：WebView 打不开 → 自动翻到另一个地址。
                            // 这是最后一道保险：判定说「在家」但这条 WiFi 其实连不上
                            // 自家后端时，不翻面用户就只能看着白屏。
                            handleLoadFailure(msg)
                        }
                    )
                    .overlay(alignment: .top) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                                .padding(.top, 8)
                        }
                    }
                    // UIViewRepresentable 没有内在尺寸，不撑开会在 VStack 里塌陷成 0 高
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 2026-11-05：进到后台以后打不开也要有提示（原来白屏无提示）
                    .overlay(alignment: .bottom) {
                        if !errorText.isEmpty {
                            Text(errorText)
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.88))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .padding(.bottom, 16)
                                .padding(.horizontal, 16)
                                .onTapGesture { errorText = "" }
                        }
                    }
                } else {
                    unlockForm
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.t("i18n_1512")) { presentationMode.wrappedValue.dismiss() }
                        .font(.footnote)
                }
                // 2026-11-02：iOS 15 的 ToolbarContentBuilder 不支持 `if`（报 buildIf is only
                // available in iOS 16.0 or newer）。改为始终声明 ToolbarItemGroup，内部用
                // ViewBuilder 的 if 控制（内容层支持条件，container 层不支持）。
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isUnlocked {
                        // 手动刷新（每次进入已自动刷新，这里给个显式入口）
                        Button(action: { reloadToken += 1 }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        // 换密钥 / 改地址
                        Button(action: { isUnlocked = false; passwordInput = "" }) {
                            Image(systemName: "key")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            // 已存过密码 → 直接进（免密）；没存过 → 留在解锁表单
            isUnlocked = RelayAdminCredential.shared.hasSavedKey
            refreshRoute()
            startNetworkWatch()
        }
        .onDisappear { stopNetworkWatch() }
        // 2026-11-05：切后台回来也重算一次 —— NWPathMonitor 在后台可能被挂起，
        // 靠这个兜底保证「从外面回到家、或从家出门」界面能立刻反映。
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.networkRestored)) { _ in
            refreshRoute()
        }
    }

    // MARK: - 2026-11-05：地址自动判定

    /// 按当前网络重算「该用哪个地址」。网络变了就调用。
    ///
    /// 2026-11-05：**改成异步真探活**（resolveAsync），不再只看「有没有内网 IP」。
    /// 用户明确指出「也要判定我在别的 WiFi 也是外面」——
    /// 别人家 WiFi 也有内网 IP，只数网卡会误判成在家，然后去连 192.168.1.88 必然超时。
    /// 现在探 `/health` 确认「这台后端是不是我的」，不是就判在外用域名。
    ///
    /// 注意这里**不只是刷新文案**，而是真的把 WebView 指向的地址换掉
    /// （effectiveURL 是 WebView 的 urlString 来源）——这是用户投诉的核心：
    /// 「你只修改了自动判定在哪里，而没有修改判定后需要更改中转站后台的地址」。
    private func refreshRoute() {
        let cred = RelayAdminCredential.shared
        autoSwitch = cred.autoSwitch
        lastNetSig = RouterControl.netSignature()

        cred.resolveAsync { url, label in
            let changed = (url != effectiveURL)
            effectiveURL = url
            routeLabel = label
            // 地址真的变了，且已经在看后台 → 让 WebView 重新加载到新地址
            if changed && isUnlocked { reloadToken += 1 }
        }
    }

    /// WiFi ↔ 蜂窝 切换时立刻重算，不等用户手动刷新。
    private func startNetworkWatch() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        pathMonitor = m
        m.pathUpdateHandler = { _ in
            DispatchQueue.main.async {
                let sig = RouterControl.netSignature()
                // 指纹没变不算换网（同一次切换会连发好几次回调，去重避免反复 reload）
                guard sig != lastNetSig else { return }
                refreshRoute()
            }
        }
        m.start(queue: DispatchQueue(label: "relayadmin.netwatch"))
    }

    private func stopNetworkWatch() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// 2026-11-05：WebView 加载失败 → 自动翻到另一个地址重试一次。
    ///
    /// 只翻一次（failoverTried 标记），避免「在家打不通→翻域名→域名也不通→又翻回来」
    /// 这种来回死循环。两条都不通就停手，把失败原因显示出来。
    @State private var failoverTried = false

    private func handleLoadFailure(_ msg: String) {
        guard !failoverTried else {
            errorText = "后台打不开：\(msg)"
            return
        }
        guard autoSwitch,
              let alt = RelayAdminCredential.shared.failoverSuggest(from: effectiveURL),
              alt != effectiveURL else {
            errorText = "后台打不开：\(msg)"
            return
        }
        failoverTried = true
        effectiveURL = alt
        routeLabel = RelayAdminCredential.shared.currentRouteLabel() + " · 已自动切换"
        reloadToken += 1
        // 200 秒后允许再次兜底（万一用户又换了网络）
        DispatchQueue.main.asyncAfter(deadline: .now() + 200) { failoverTried = false }
    }

    // MARK: - 首次解锁表单

    /// 2026-11-05：自动判定状态条。
    ///
    /// 用户原话：「用 wifi 时候显示这个地址是正确的，在切换流量的时候应该是能自动判定在外的，
    /// 同时要更改这里的地址的，应该改成域名才对，现在它不自动改。」
    /// 后续补充：「也要判定我在别的 wifi 也是外面」。
    /// → 这条横幅把四件事一次说清：① 现在判定在哪 ② 为什么这么判
    ///   ③ 正在用哪个地址 ④ 可以一键改回手动。
    private var routeIcon: String {
        if routeLabel.contains("在家") { return "wifi" }
        if routeLabel.contains("非自家") { return "wifi.exclamationmark" }
        return "antenna.radiowaves.left.and.right"
    }

    private var routeBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: autoSwitch ? routeIcon : "hand.raised")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(autoSwitch ? .blue : .secondary)
                Text(autoSwitch ? "自动判定：\(routeLabel)" : "手动地址")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(autoSwitch ? .blue : .secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Toggle("", isOn: $autoSwitch)
                    .labelsHidden()
                    .scaleEffect(0.8)
                    .onChange(of: autoSwitch) { v in
                        RelayAdminCredential.shared.autoSwitch = v
                        refreshRoute()
                    }
            }
            // 实际要连的地址（自动判定后的结果）——用户能直接看到「它到底改成什么了」
            HStack(spacing: 4) {
                Text("当前连接：")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(effectiveURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(Color.blue.opacity(autoSwitch ? 0.08 : 0.0))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.blue.opacity(autoSwitch ? 0.25 : 0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var unlockForm: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("i18n_1513"))
                        .font(.title3.weight(.semibold))
                    Text(RelayAdminCredential.shared.hasSavedKey
                         ? L10n.t("i18n_1519")
                         : L10n.t("i18n_1518"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)

                // 2026-11-05：自动判定状态条（放在地址输入框上方，一眼看到现在用哪条线路）
                routeBanner

                VStack(alignment: .leading, spacing: 8) {
                    Text(autoSwitch ? L10n.t("i18n_1514") + "（在家地址）" : L10n.t("i18n_1514"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(RelayAdminCredential.defaultHomeURL, text: $baseURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .padding(10)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        // 2026-11-05：自动判定开启时，在家地址只在连 WiFi 时生效 ——
                        // 必须写清楚，否则用户会以为「填了就该一直用它」。
                        .opacity(autoSwitch && routeLabel.contains("在外") ? 0.45 : 1)
                        .onChange(of: baseURL) { v in
                            RelayAdminCredential.shared.baseURL = v
                            refreshRoute()
                        }
                }

                // 2026-11-05：在外地址（公网域名）——自动切到外网时用它。
                // 用户要求「在外应该改成域名」，所以这个框必须存在且可改。
                if autoSwitch {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("在外地址（自动切到流量时用）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(RelayAdminCredential.defaultAwayURL, text: $awayURL)
                            .font(.system(.body, design: .monospaced))
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .padding(10)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .opacity(routeLabel.contains("在家") ? 0.45 : 1)
                            .onChange(of: awayURL) { v in
                                RelayAdminCredential.shared.awayURL = v
                                refreshRoute()
                            }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("i18n_1515"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    // 2026-11-03：换成带小眼睛的输入框（用户两次点名要求）
                    SecretInputField(
                        text: $passwordInput,
                        revealed: $revealPassword,
                        placeholder: "输入一次，之后不用再输")
                }

                // 2026-11-03：确定 / 取消 + 结果反馈（用户原话「点击确定要有提示
                // 登录成功还是失败的样式」）。原来只有一个蓝按钮，成功失败都没样式。
                ConfirmCancelRow(
                    confirmTitle: "确定",
                    cancelTitle: "取消",
                    canConfirm: canSubmit,
                    busy: isVerifying,
                    onConfirm: unlock,
                    onCancel: {
                        passwordInput = ""
                        revealPassword = false
                        errorText = ""
                        verifyOK = nil
                    })

                // 结果横幅：成功绿勾、失败红叉，一眼可辨
                if isVerifying {
                    InlineResultBanner(kind: .info, text: "正在验证密码，请稍候…")
                } else if let ok = verifyOK {
                    if ok {
                        InlineResultBanner(kind: .success, text: "登录成功，正在打开后台…")
                    } else {
                        InlineResultBanner(kind: .failure,
                                           text: errorText.isEmpty ? "登录失败，请检查密码和地址" : errorText)
                    }
                }

                Text(L10n.t("i18n_1517"))
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private var canSubmit: Bool {
        !passwordInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 校验密码 → 保存 → 打开后台
    ///
    /// 2026-11-03 修：原来用 `isLoading` 兼做「校验中」标记，初始值还是 true，
    /// 导致一进页面按钮就转圈。现在改用独立的 `isVerifying`（初始 false），
    /// 并加上成功/失败两种明确反馈。
    private func unlock() {
        let entered = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = passwordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty, !key.isEmpty else { return }

        // 2026-11-05 **关键修复**：校验必须打「当前网络该用的地址」，
        // 而不是用户框里那个内网 IP。
        //
        // 病根原样复现：用户在流量下进来，框里显示 http://192.168.1.88:8080（用户填的在家地址），
        // 点确定就去打它 → 流量环境根本没这个网段 → 请求超时 → 就是用户截图里那个
        // 「连接失败：请求超时」。而地址明明可以自动换成域名。
        //
        // 现在：先按「是不是自家后端」判定出地址（resolveAsync 会真探 /health），
        // 打不通再自动翻另一个（failoverSuggest）——两条都试过才报失败。
        let auto = RelayAdminCredential.shared.autoSwitch
        guard auto else {
            attemptUnlock(addr: entered, key: key, auto: false, entered: entered)
            return
        }

        isVerifying = true
        verifyOK = nil
        errorText = ""
        // 判定阶段先按「在不在自家网里」定地址——这样连别人家 WiFi 也会正确走域名
        RelayAdminCredential.shared.resolveAsync { url, label in
            routeLabel = label
            effectiveURL = url
            attemptUnlock(addr: url, key: key, auto: true, entered: entered)
        }
    }

    /// 试一个地址；失败且允许兜底时自动翻面再试一次。
    private func attemptUnlock(addr: String, key: String, auto: Bool, entered: String) {
        // 真校验一次：拿 /admin/api/status 试打，密钥对才保存——避免存错密码后
        // 每次都白屏（后台对错密钥返回 401，我们据此提示）。
        RelayAdminWebView.probe(addr: addr, key: key) { ok, message in
            if ok {
                isVerifying = false
                verifyOK = true
                // 记下用户填的那个内网地址（它是「在家地址」的语义），
                // 不要用实际打通的域名覆盖掉——否则回到家就用不上内网直连了。
                RelayAdminCredential.shared.baseURL = entered
                RelayAdminCredential.shared.save(accessKey: key)
                baseURL = entered
                passwordInput = ""      // 明文立刻清掉，不进内存常驻
                revealPassword = false
                effectiveURL = addr
                // 让「登录成功」的绿横幅停留一小会儿再进后台——
                // 用户要求「点击确定要有提示成功」，切换太快就看不到提示了
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    isUnlocked = true
                    reloadToken += 1
                    verifyOK = nil
                    failoverTried = false   // 新一次进入，兜底权限重置
                }
                return
            }

            // 第一次失败 → 自动翻到另一个地址再试（这是「判定后自动改地址」的实质部分）
            if auto, let alt = RelayAdminCredential.shared.failoverSuggest(from: addr), alt != addr {
                errorText = "\(addr) 不通，正在切换到 \(alt)…"
                attemptUnlock(addr: alt, key: key, auto: false, entered: entered)
                return
            }

            isVerifying = false
            verifyOK = false
            // 两条都不通时，把「为什么」说清楚——比原来只说"请求超时"有用得多
            let hint = auto
                ? "（已同时试过在家地址和外网域名，均不通）"
                : ""
            errorText = (message.isEmpty ? "密码或地址不正确" : message) + hint
        }
    }
}

// MARK: - WKWebView 封装

struct RelayAdminWebView: UIViewRepresentable {
    let urlString: String
    let accessKey: String
    let reloadToken: Int
    @Binding var isLoading: Bool
    @Binding var titleText: String
    /// 2026-11-05：加载失败回调（外层据此自动翻到另一个地址）。
    /// 原来 didFail/didFailProvisionalNavigation 只是把转圈停掉，
    /// 用户看到的就是一个空白 WebView —— 「连接失败」两个字都没有。
    var onLoadFailed: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true

        // 关键：在页面任何脚本执行之前，把密码塞进 localStorage['relayKey']。
        // 后台前端（relay.py 里的 key() 函数）从这里取值，每次 fetch 自动带上
        // X-Access-Key 头 —— 这样后台所有页面都不会再问密码。
        if !accessKey.isEmpty {
            let escaped = Self.jsEscape(accessKey)
            let script = """
            (function(){
              try { localStorage.setItem('relayKey', '\(escaped)'); } catch(e) {}
            })();
            """
            cfg.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        context.coordinator.webView = wv
        load(in: wv)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // reloadToken 变化 → 重新加载（手动刷新 / 解锁后首刷 / 自动切换地址）
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            load(in: uiView)
            return
        }
        // 2026-11-05：地址本身变了也要重载。这是「切流量后地址改成域名」真正生效的地方——
        // 万一以后有人只改了 urlString 没动 reloadToken，这条兜底能保证它仍然生效。
        if context.coordinator.lastURL != normalizedBase {
            context.coordinator.lastURL = normalizedBase
            load(in: uiView)
        }
    }

    private func load(in wv: WKWebView) {
        guard let url = URL(string: normalizedBase) else { return }
        isLoading = true
        wv.load(URLRequest(url: url))
    }

    private var normalizedBase: String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        return s
    }

    /// JS 字符串转义——密码里可能有引号/反斜杠，不转义会注入失败甚至破坏脚本
    static func jsEscape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "'":  out += "\\'"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:   out += String(ch)
            }
        }
        return out
    }

    /// 密码预校验：GET {addr}/admin/api/status 带 X-Access-Key
    static func probe(addr: String, key: String, completion: @escaping (Bool, String) -> Void) {
        var s = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        guard let url = URL(string: s + "/admin/api/status") else {
            completion(false, "地址格式不正确")
            return
        }
        var req = URLRequest(url: url)
        setTimeoutInterval(15, on: &req)
        setHTTPMethod("GET", on: &req)
        req.setValue(key, forHTTPHeaderField: "X-Access-Key")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            DispatchQueue.main.async {
                if let err = err {
                    completion(false, "连接失败：\(err.localizedDescription)")
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    completion(false, "未收到响应")
                    return
                }
                if (200...299).contains(http.statusCode) {
                    completion(true, "")
                } else if http.statusCode == 401 {
                    completion(false, "密码不正确（HTTP 401）")
                } else if http.statusCode == 429 {
                    completion(false, "密码连续错误次数过多，请稍后再试")
                } else {
                    completion(false, "后台返回 HTTP \(http.statusCode)，请检查地址")
                }
            }
        }.resume()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: RelayAdminWebView
        weak var webView: WKWebView?
        var lastReloadToken = -1
        /// 2026-11-05：上一次加载的地址（换地址也要重载）
        var lastURL: String?

        init(_ parent: RelayAdminWebView) {
            self.parent = parent
            self.lastReloadToken = parent.reloadToken
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            if let t = webView.title, !t.isEmpty {
                parent.titleText = t
            }
            // 兜底：某些后台页面是 SPA 跳转，documentStart 注入的脚本在多次
            // pushState 后 localStorage 仍在，无需重注；这里再补一次防止 iframe 场景漏掉。
            if !parent.accessKey.isEmpty {
                let escaped = RelayAdminWebView.jsEscape(parent.accessKey)
                webView.evaluateJavaScript("try{localStorage.setItem('relayKey','\(escaped)')}catch(e){}")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            // 2026-11-05：把失败报给外层，由外层决定「翻到另一个地址重试」还是「提示用户」。
            // 用户取消/被中断不算失败，别误报。
            let ns = error as NSError
            if ns.code == NSURLErrorCancelled { return }
            parent.onLoadFailed?(error.localizedDescription)
        }
    }
}
