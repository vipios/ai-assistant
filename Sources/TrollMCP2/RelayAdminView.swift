import SwiftUI
import WebKit
import CryptoKit

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
    private let keyHost = "relayadmin.baseurl"               // 用户填的后台地址

    /// 后台地址（默认给内网常用地址，用户可改）
    var baseURL: String {
        get { UserDefaults.standard.string(forKey: keyHost) ?? "http://192.168.1.88:8080" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: keyHost) }
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
    @State private var isLoading = true
    @State private var titleText = L10n.t("i18n_1511")

    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                if isUnlocked {
                    RelayAdminWebView(
                        urlString: baseURL,
                        accessKey: RelayAdminCredential.shared.loadAccessKey() ?? "",
                        reloadToken: reloadToken,
                        isLoading: $isLoading,
                        titleText: $titleText
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
                if isUnlocked {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
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
        }
    }

    // MARK: - 首次解锁表单

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

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("i18n_1514"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("http://192.168.1.88:8080", text: $baseURL)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .padding(10)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("i18n_1515"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("输入一次，之后不用再输", text: $passwordInput)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .padding(10)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                if !errorText.isEmpty {
                    Text(errorText)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Button(action: unlock) {
                    HStack {
                        Spacer()
                        if isLoading {
                            ProgressView().scaleEffect(0.85)
                        } else {
                            Text(L10n.t("i18n_1516"))
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(canSubmit ? Color.blue : Color.secondary.opacity(0.25))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(!canSubmit || isLoading)

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
    private func unlock() {
        let addr = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = passwordInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty, !key.isEmpty else { return }

        isLoading = true
        errorText = ""

        // 真校验一次：拿 /admin/api/status 试打，密钥对才保存——避免存错密码后
        // 每次都白屏（后台对错密钥返回 401，我们据此提示）。
        RelayAdminWebView.probe(addr: addr, key: key) { ok, message in
            isLoading = false
            if ok {
                RelayAdminCredential.shared.baseURL = addr
                RelayAdminCredential.shared.save(accessKey: key)
                baseURL = addr
                passwordInput = ""      // 明文立刻清掉，不进内存常驻
                isUnlocked = true
                reloadToken += 1
            } else {
                errorText = message.isEmpty ? "密码或地址不正确" : message
            }
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
        // reloadToken 变化 → 重新加载（手动刷新 / 解锁后首刷）
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
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
        }
    }
}
