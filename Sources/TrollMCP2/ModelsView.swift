import SwiftUI
import UIKit   // v2.9.85：UIPasteboard 复制推荐链接
import UniformTypeIdentifiers  // v2.9.107：配置导入/导出

struct ModelsView: View {
    @ObservedObject private var store = ModelStore.shared
    @State private var editing: ModelConfig?
    @State private var isNewModel = false
    // v2.9.107：用量统计 / 导入导出
    @State private var showingUsage = false
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var exportDoc: ConfigDoc?
    @State private var importMessage = ""
    @State private var showImportMessage = false

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // 2026-11-02 按用户要求：顶部加「已添加供应商」快捷条——
                // 横向滑动可看全部供应商名字，点击直接跳到对应分组；列表上滑时本栏固定不动。
                if !store.configs.isEmpty {
                    supplierChipsBar(proxy: proxy)
                    Divider()
                }

                List {
                    if store.configs.isEmpty {
                        Section {
                            HStack {
                                Spacer()
                                VStack(spacing: 8) {
                                    Image(systemName: "cpu")
                                        .font(.system(size: 40))
                                        .foregroundColor(.secondary)
                                    Text(L10n.t("ui_50"))
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.vertical, 40)
                                Spacer()
                            }
                        }
                    } else {
                        // v2.9.107：按分组展示（默认组优先，其余按字典序）
                        let groups = groupedKeys()
                        ForEach(groups, id: \.self) { g in
                            Section(header: HStack {
                                // 2026-11-02 按用户要求：默认分组（group == "default"）不显示分组名，
                                // 只保留右侧数量。否则列表头会把 "default" 自动大写成灰色 "DEFAULT"。
                                // 用户自定义过分组名的仍然照常显示。
                                if !isDefaultGroup(g) {
                                    Text(g)
                                        .font(.subheadline.weight(.semibold))
                                }
                                Spacer()
                                Text(L10n.t("ui_155", count(in: g)))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }) {
                                ForEach(configs(in: g)) { cfg in
                                    ModelRow(config: cfg)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            isNewModel = false
                                            editing = cfg
                                        }
                                        .id(cfg.id)   // 2026-11-02：供顶部供应商条 scrollTo 精确定位
                                }
                                .onDelete { offsets in delete(in: g, at: offsets) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(L10n.t("i18n_1102"))
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // v2.9.108：从剪贴板粘贴导入（借鉴 cc-switch ccswitch:// 一键导入思路，零 URL Scheme 风险）
                Button(action: importFromClipboard) {
                    Image(systemName: "doc.on.clipboard")
                }
                .help(L10n.t("i18n_408"))
                Button(action: { showingUsage = true }) {
                    Image(systemName: "chart.bar.fill")
                }
                .help(L10n.t("i18n_409"))
                Button(action: {
                    isNewModel = true
                    editing = ModelConfig(name: "", provider: "custom", apiProtocol: "OpenAI Chat Completions", baseURL: "", apiKey: "", model: "")
                }) {
                    Image(systemName: "plus")
                }
            }
        }
        // v2.9.180: 用量统计用 fullScreenCover，避免 iOS 14 多 sheet 冲突闪退
        .fullScreenCover(isPresented: $showingUsage) {
            UsageStatsView()
        }
        .sheet(item: $editing, onDismiss: { editing = nil }) { cfg in
            // v2.9.14：改用 .sheet(item:) 绑定。iOS14 的 .sheet(isPresented:)+闭包捕获
            // 存在时序竞争——sheet 内容首次构建可能读到旧 editing(nil)，先用默认预设渲染，
            // 之后才切到真实配置（表现为"先显示 gpt-4o，很久才变成 5.6"）。
            // .sheet(item:) 在 item 变化时以新值重建内容，机制上消除该问题。
            // 注：iOS 14.0-14.4 多 sheet 只生效最后一个声明，因此编辑弹窗必须放最后。
            ModelEditorView(config: isNewModel ? nil : cfg) { newCfg in
                if ModelStore.shared.configs.contains(where: { $0.id == newCfg.id }) {
                    ModelStore.shared.update(newCfg)
                } else {
                    ModelStore.shared.add(newCfg)
                }
            }
            .id(cfg.id)
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        let r = store.importJSON(text)
                        if r.failed > 0 {
                            importMessage = L10n.t("i18n_411", r.ok, r.failed)
                        } else {
                            importMessage = L10n.t("i18n_412", r.ok)
                        }
                    } else {
                        importMessage = L10n.t("i18n_413")
                    }
                } else {
                    importMessage = L10n.t("i18n_414")
                }
            case .failure:
                importMessage = L10n.t("i18n_415")
            }
            showImportMessage = true
        }
        .fileExporter(isPresented: $showingExporter, document: exportDoc, contentType: .json, defaultFilename: "AllInOneAI-models-\(Date().timeIntervalSince1970)") { _ in }
        .alert(isPresented: $showImportMessage) {
            Alert(title: Text(L10n.t("ui_100")), message: Text(importMessage), dismissButton: .default(Text(L10n.t("ui_44"))))
        }
    }

    /// v2.9.108：从剪贴板粘贴 JSON 导入（分享链接/文本一键导入）
    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            importMessage = L10n.t("i18n_416")
            showImportMessage = true
            return
        }
        let r = store.importJSON(text)
        importMessage = r.failed > 0
            ? L10n.t("i18n_411", r.ok, r.failed)
            : L10n.t("i18n_412", r.ok)
        showImportMessage = true
    }

    // MARK: v2.9.107 分组辅助

    /// 2026-11-02：顶部「已添加供应商」横向快捷条——列出全部已添加的配置名（供应商），
    /// 点击直接跳到对应分组；列表上滑滚动时本栏固定不动（VStack 内、List 之外）。
    @ViewBuilder
    private func supplierChipsBar(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已添加供应商（\(store.configs.count)）")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.configs) { cfg in
                        Button(action: {
                            // 跳到该配置所在行（行已挂 .id(cfg.id)，比 Section 定位可靠）
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(cfg.id, anchor: .top)
                            }
                        }) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(cfg.isDefault ? Color.blue : Color.secondary.opacity(0.45))
                                    .frame(width: 6, height: 6)
                                Text(cfg.name)
                                    .font(.footnote.weight(.medium))
                                    .lineLimit(1)
                                Text(cfg.model)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 8)
        }
        .background(Color.secondary.opacity(0.04))
    }

    private func groupedKeys() -> [String] {
        var seen: [String] = []
        for c in store.configs where !seen.contains(c.group) { seen.append(c.group) }
        return seen.sorted {
            if $0 == L10n.t("ui_144") { return true }
            if $1 == L10n.t("ui_144") { return false }
            return $0 < $1
        }
    }

    /// 2026-11-02：是否为「默认分组」——分组名等于 ModelConfig.group 的默认值 "default"
    /// （大小写不敏感，兼容老数据里手写成 "Default" 的情况）
    private func isDefaultGroup(_ g: String) -> Bool {
        g.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "default"
    }

    private func configs(in group: String) -> [ModelConfig] {
        store.configs.filter { $0.group == group }
    }

    private func count(in group: String) -> Int {
        store.configs.filter { $0.group == group }.count
    }

    private func delete(in group: String, at offsets: IndexSet) {
        for i in offsets {
            let list = configs(in: group)
            if i < list.count, let idx = store.configs.firstIndex(where: { $0.id == list[i].id }) {
                store.delete(at: IndexSet(integer: idx))
            }
        }
    }
}

struct ModelRow: View {
    let config: ModelConfig
    // v2.9.107：行内测速 + 熔断状态 + 一键切换
    @State private var testing = false
    @State private var latencyText = ""
    @State private var latencyColor: Color = .secondary

    var body: some View {
        let info = ModelStore.shared.breaker(for: config.id).stateInfo
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(iconColor(for: info.state))
                    .frame(width: 34, height: 34)
                Image(systemName: info.state == .open ? "bolt.slash" : "cpu")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    // v7.1.109-peers：视觉能力标记（对齐 OpenMinis 模型列表图片小图标）——
                    // 数据源 supportsVision = 动态学习记录优先 + 静态规则兜底
                    if config.supportsVision {
                        Image(systemName: "photo")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.blue)
                            .accessibilityLabel("Vision")
                    }
                    if config.isDefault {
                        Text(L10n.t("ui_144"))
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                    if info.state != .closed {
                        Text(info.state.label)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(iconColor(for: info.state).opacity(0.15))
                            .foregroundColor(iconColor(for: info.state))
                            .cornerRadius(4)
                    }
                }
                Text("\(config.provider.capitalized) · \(config.model)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !latencyText.isEmpty {
                    Text(latencyText)
                        .font(.caption2)
                        .foregroundColor(latencyColor)
                }
            }
            Spacer()
            Button(action: speedTest) {
                if testing {
                    ProgressView()
                } else {
                    Image(systemName: "gauge")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.blue)
                }
            }
            .buttonStyle(.plain)
            .disabled(testing)
            // v2.9.108：复制为副本（借鉴 cc-switch provider duplicate）
            Button(action: duplicate) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.purple)
            }
            .buttonStyle(.plain)
            // v2.9.126：分享深链——trollagent://import?...，对方点链接即可导入
            // v4.3.48：ShareLink 在本设备侧载环境触发 ShareSheet → MobileIcons/CoreImage
            // SIGSEGV（崩溃栈实证），统一改自建分享菜单（拷贝/存储到文件）
            Button(action: {
                ShareCenter.shared.presentShareMenuText(makeDeepLink())
            }) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.teal)
            }
            .buttonStyle(.plain)
            if !config.isDefault {
                Button(action: activate) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.green)
                }
                .buttonStyle(.plain)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func iconColor(for state: CircuitState) -> Color {
        switch state {
        case .closed: return Color.blue
        case .halfOpen: return Color.orange
        case .open: return Color.red
        }
    }

    /// v2.9.107：一键切换为当前使用模型
    private func activate() {
        var c = config
        c.isDefault = true
        ModelStore.shared.update(c)
        ModelStore.shared.markUsed(config.id.uuidString)
        ModelStore.shared.breaker(for: config.id).reset()
    }

    /// v2.9.108：复制为副本（快速起一个新配置改参数，借鉴 cc-switch duplicate）
    private func duplicate() {
        var c = config
        c.id = UUID()
        c.name = config.name + L10n.t("i18n_417")
        c.isDefault = false
        ModelStore.shared.add(c)
        AuditLog.shared.log("model.duplicate", detail: config.name)
    }

    /// v2.9.126：生成导入深链（v4.3.42 改为纯函数，由 ShareLink/按钮调用）
    private func makeDeepLink() -> String {
        let enc = { (s: String) in
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        var link = "trollagent://import?baseURL=\(enc(config.baseURL))&model=\(enc(config.model))&name=\(enc(config.name))"
        if !config.apiKey.isEmpty { link += "&apiKey=\(enc(config.apiKey))" }
        link += "&auth=\(enc(config.authMethod))&group=\(enc(config.group))&protocol=\(enc(config.apiProtocol))"
        if config.temperature != 0.2 { link += "&temperature=\(config.temperature)" }
        if config.maxTokens != 16384 { link += "&maxTokens=\(config.maxTokens)" }
        // 2026-11-05：判定基准从 16000 改成 128000（ModelConfig 的默认值）——
        // 只有和"未配置"的判定基准一致，导出的链接才和实际生效值一致。
        if config.contextTokens != 128_000 { link += "&contextTokens=\(config.contextTokens)" }
        return link
    }

    /// v2.9.107：供应商测速（GET /models，8s 超时）
    private func speedTest() {
        testing = true
        latencyText = ""
        // 2026-11-02 通用接口：自动剥端点后缀 + 纯主机补 /v1（与主流程同一套解析）
        guard let url = URL(string: ModelConfig.modelsEndpoint(config.baseURL)) else {
            latencyText = L10n.t("i18n_1103")
            latencyColor = .red
            testing = false
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        setHTTPMethod("GET", on: &req)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.authMethod == "API Key" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        URLSession.shared.dataTask(with: req) { _, _, error in
            DispatchQueue.main.async {
                testing = false
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if error != nil {
                    latencyText = L10n.t("i18n_418", ms)
                    latencyColor = .red
                } else {
                    latencyText = L10n.t("i18n_1104", ms)
                    latencyColor = ms < 500 ? .green : (ms < 2000 ? .orange : .red)
                }
            }
        }.resume()
    }
}

// MARK: - 推荐卡片区
// 2026-11-02 按用户要求：整块删除（原为「推荐破甲站」+「推荐中转站」两张横幅）
// 保留 RecommendCard 组件定义（可能被其他地方复用），但不再渲染任何推荐内容。

/// 通用推荐卡片：圆角渐变背景 + 距边缘空隙，标题+正文+可复制链接
/// 注意：正文属性命名 message——不能叫 body（与 View.body 计算属性重名，编译报
/// "invalid redeclaration of 'body'"，CI 实测踩坑）。
struct RecommendCard: View {
    let icon: String
    let title: String
    let message: String
    let link: String
    let colors: [Color]
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white)
            }
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.92))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(link)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = link
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }) {
                    Label(copied ? L10n.t("relay_card_copied") : L10n.t("relay_card_copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(copied ? .white : Color(red: 0.82, green: 0.95, blue: 1.0))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: colors,
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(14)   // v4.3.28：卡片圆角（不再贴边直角）
    }
}

// MARK: - 模型 API 编辑器（原版风格）

struct ModelEditorView: View {
    @Environment(\.presentationMode) var presentationMode
    let config: ModelConfig?
    let onSave: (ModelConfig) -> Void

    @State private var name: String
    @State private var provider: String
    @State private var apiProtocol: String
    @State private var baseURL: String
    /// 2026-11-03：备用接口地址（在外面时用）——空 = 不启用双通道
    @State private var backupBaseURL: String
    /// 2026-11-03：备用模型名称（在外面时用）——空 = 在外沿用主模型名
    @State private var backupModel: String
    @State private var apiKey: String
    @State private var model: String
    @State private var authMethod: String
    @State private var isDefault: Bool
    @State private var temperature: Double
    @State private var maxTokens: Int
    @State private var contextTokens: Int
    @State private var group: String
    /// v3.5.13：参数名别名映射编辑（"标准键:供应商键"逗号分隔，如 max_tokens:max_completion_tokens）
    @State private var paramAliasesText: String
    /// v7.1.107：备用模型组（失败自动切换）——主模型请求失败时按序切换，见 OpenAIClient fallback
    @State private var fallbackIDs: [UUID]
    /// v7.1.280-fix：老手固定模式——协议自动修正开关 / 降级链上限
    @State private var protocolAutoFixEnabled: Bool
    @State private var compatMaxLevel: Int
    /// v7.1.281-fix：流式传输开关（关=直接非流式；中转首字节超时自动置关）
    @State private var streamEnabled: Bool

    @State private var showKey = false
    @State private var showingQuickPicker = false
    @State private var testStatus = ""
    @State private var testColor: Color = .secondary
    @State private var isTesting = false
    @State private var fetchedModels: [String] = []
    @State private var showingModelPicker = false
    /// 2026-11-03：弹窗选择的目标是主模型还是备用模型
    @State private var pickerForBackup = false
    /// 备用接口自己的模型清单（拉的是备用接口的上游模型，和主接口可能不是同一批）
    @State private var fetchedBackupModels: [String] = []
    @State private var savedFlag = false

    private let providers = ["openai", "deepseek", "anthropic", "custom"]

    // 在 init 中一次性初始化，避免 iOS 14 上 .onAppear 重复触发把用户输入冲回默认值
    init(config: ModelConfig?, onSave: @escaping (ModelConfig) -> Void) {
        self.config = config
        self.onSave = onSave
        let p = ModelConfig.providerPresets.first
        _name = State(initialValue: config?.name ?? (p?.name ?? ""))
        _provider = State(initialValue: config?.provider ?? (p?.provider ?? "custom"))
        _apiProtocol = State(initialValue: config?.apiProtocol ?? (p?.protocol ?? "OpenAI Chat Completions"))
        _baseURL = State(initialValue: config?.baseURL ?? (p?.baseURL ?? ""))
        _backupBaseURL = State(initialValue: config?.backupBaseURL ?? "")
        _backupModel = State(initialValue: config?.backupModel ?? "")
        _apiKey = State(initialValue: config?.apiKey ?? "")
        _model = State(initialValue: config?.model ?? (p?.model ?? ""))
        _authMethod = State(initialValue: config?.authMethod ?? (p?.auth ?? "Bearer"))
        _isDefault = State(initialValue: config?.isDefault ?? false)
        _temperature = State(initialValue: config?.temperature ?? 0.2)
        _maxTokens = State(initialValue: config?.maxTokens ?? 16384)
        // 2026-11-05：新建模型时**不要**写 16000。
        // 16000 是历史遗留的"显式上限"，会被 effectiveContextTokens 当成用户设过上限，
        // 于是新加的模型永远只能用 16K，明明上游给 128K/256K 也用不上。
        // 用 ModelConfig 的默认值 128000 —— 这个值在 effectiveContextTokens 里
        // 被当作"未配置"，会自动走模型真实窗口（用户要的"按选中的模型调节"）。
        _contextTokens = State(initialValue: config?.contextTokens ?? 128_000)
        _group = State(initialValue: config?.group ?? L10n.t("ui_144"))
        _paramAliasesText = State(initialValue: ModelEditorView.aliasesString(config?.paramAliases))
        _fallbackIDs = State(initialValue: config?.fallbackIDs ?? [])
        _protocolAutoFixEnabled = State(initialValue: config?.protocolAutoFixEnabled ?? true)
        _compatMaxLevel = State(initialValue: config?.compatMaxLevel ?? 5)
        _streamEnabled = State(initialValue: !(config?.streamUnsupported ?? false))
    }

    var body: some View {
        CompatNav {
            List {
                Section(header: sectionHeader(apiProtocol.uppercased())) {
                    quickConfigRow
                    editorRow(L10n.t("i18n_919"), text: $name, placeholder: "OpenAI")
                    pickerRow(L10n.t("i18n_1105"), selection: $apiProtocol, options: ModelConfig.apiProtocols)
                }

                // 2026-11-02 按用户要求重排：接口地址 → API Key（带测试连接）→ 模型名称（点击弹出选择）
                Section(header: sectionHeader(L10n.t("i18n_1106"))) {
                    // 2026-11-03 用户要求：接口地址下面加一个「备用接口」。
                    //   上面这条 = 在家用的接口；下面那条 = 在外面用的接口。
                    //   在家/在外自动判定，不用手动切（判定见 BaseURLRouter）。
                    editorRow("接口地址", text: $baseURL, placeholder: "在家用这个，如 http://192.168.1.88:8080")

                    HStack {
                        Text("备用接口")
                            .foregroundColor(.primary)
                        Spacer()
                        TextField("选填 · 在外面时用这个", text: $backupBaseURL)
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }

                    // 当前实际在用哪一条 —— 让用户一眼看到自动判定的结果，
                    // 免得「我填了备用怎么没生效」这种疑问。
                    if !backupBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.caption2)
                            Text(activeRouteNote)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                        .foregroundColor(.secondary)
                    }

                    // 2026-11-02 通用接口：实时回显最终请求地址，填什么形式都能用
                    // 2026-11-03：回显的是**真正会用的那条**（自动判定后的），不是干巴巴的原值
                    if !effectivePreviewEndpoint.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.caption2)
                            Text("实际请求：\(effectivePreviewEndpoint)")
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundColor(.secondary)
                    }

                    // API Key 行 + 右侧「测试连接」按钮（对齐用户参考图）
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(authMethod == "None" ? L10n.t("i18n_425") : "API Key")
                                .font(.body)
                            if showKey {
                                TextField("sk-...", text: $apiKey)
                                    .font(.system(.body, design: .monospaced))
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } else {
                                SecureField("sk-...", text: $apiKey)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                        Button(action: { showKey.toggle() }) {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                        Button(action: { fetchAndPickModels() }) {
                            if isTesting {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Text("测试连接")
                                    .font(.subheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundColor(.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isTesting)
                    }
                    .padding(.vertical, 4)

                    // 模型名称：点击整行 → 拉取上游模型列表 → 弹窗里挑（上游全量模型都在里面）
                    // 2026-11-03 用户要求：标题改成「模型名称」；点击是弹窗形式。
                    Button(action: { openPicker(forBackup: false) }) {
                        HStack {
                            Text(L10n.t("i18n_421"))
                                .foregroundColor(.primary)
                            Spacer()
                            Text(model.isEmpty ? "点击选择模型" : model)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(model.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting)

                    // 2026-11-03 用户要求：模型名称下方再加一行「备用模型」。
                    //   接口地址 ↔ 模型名称（在家用）
                    //   备用接口   ↔ 备用模型（在外面用）
                    // 这样在家和在外的模型可以是两个不同的，各自指定。
                    Button(action: { openPicker(forBackup: true) }) {
                        HStack {
                            Text("备用模型")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(backupModel.isEmpty ? "选填 · 在外面时用这个" : backupModel)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(backupModel.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isTesting)

                    // 状态提示（拉取结果 / 错误）
                    if !testStatus.isEmpty {
                        Text(testStatus)
                            .font(.caption2)
                            .foregroundColor(testColor)
                    }

                    // 高级项：鉴权方式（默认 Bearer，一般不用改）
                    pickerRow(L10n.t("i18n_422"), selection: $authMethod, options: ModelConfig.authMethods)
                    Text(L10n.t("ui_auth_method_hint"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // 2026-11-03 用户要求：整块「备用模型（失败自动切换）」删除、界面不再显示。
                // 现在「在家/在外」的模型切换由「模型名称 / 备用模型」这两行负责
                // （配 接口地址 / 备用接口），不再靠这里的 fallback 勾选列表。
                // fallbackIDs 字段本身保留：老配置仍然能读，模型组的兜底链也照旧生效。

                // v7.1.280-fix：老手固定模式——默认自适应（新手），可关自动修正/限降级链（老手要可预测）
                Section(header: sectionHeader("固定模式（老手可选）")) {
                    Toggle(isOn: $protocolAutoFixEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("协议自动修正")
                                .font(.subheadline)
                            Text("开=按模型自动纠偏并记住（默认）；关=尊重手动选择，失败按所选协议报错")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Picker("降级链上限", selection: $compatMaxLevel) {
                        Text("固定 L0（失败即报错）").tag(0)
                        Text("L0-L1").tag(1)
                        Text("L0-L2").tag(2)
                        Text("L0-L3").tag(3)
                        Text("L0-L4").tag(4)
                        Text("全链自适应 L0-L5（默认）").tag(5)
                    }
                    // v7.1.281-fix：流式传输开关——首字节超时自动置关（持久化），可手动恢复
                    Toggle(isOn: $streamEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("流式传输")
                                .font(.subheadline)
                            Text("开=请求走 SSE 流式（默认）；关=直接非流式。首字节超时会自动置关并记住")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // v6.1.5-14bi：参数(Temperature/Max Tokens/上下文预算)不再让用户填——
                // 按行业标准默认值自动生效(参考Codex等AI同行)：temperature 0.7 / maxTokens 2048 / 上下文预算默认，
                // 保存时沿用默认值，无需手动配置

                Section(header: sectionHeader(L10n.t("i18n_906"))) {
                    Button(action: fetchUpstreamModels) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 20))
                                .foregroundColor(.blue)
                            Text(L10n.t("ui_128"))
                                .foregroundColor(.blue)
                            Spacer()
                            if isTesting && fetchedModels.isEmpty {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)

                    Button(action: saveOnly) {
                        Text(L10n.t("ui_26"))
                            .foregroundColor(.blue)
                    }

                    Button(action: saveAndTest) {
                        HStack {
                            Text(L10n.t("ui_27"))
                                .foregroundColor(.blue)
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                    // v2.9.107：测速（只测延迟，不保存）
                    Button(action: speedTestOnly) {
                        HStack(spacing: 12) {
                            Image(systemName: "gauge")
                                .font(.system(size: 20))
                                .foregroundColor(.orange)
                            Text(L10n.t("ui_105"))
                                .foregroundColor(.orange)
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                }

                if savedFlag {
                    Section(header: sectionHeader(L10n.t("ui_110"))) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(L10n.t("ui_52"))
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                    }
                }

                if !testStatus.isEmpty {
                    Section(header: sectionHeader(L10n.t("i18n_423"))) {
                        Text(testStatus)
                            .font(.caption)
                            .foregroundColor(testColor)
                    }
                }

                Section(header: sectionHeader(L10n.t("ui_132"))) {
                    Text(L10n.t("ui_138"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(config == nil ? L10n.t("i18n_424") : name)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.t("ui_40")) { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("i18n_1180")) { saveOnly() }
                }
            }
            .sheet(isPresented: $showingQuickPicker) {
                QuickConfigPicker { applyPreset(name: $0) }
            }
            .sheet(isPresented: $showingModelPicker) {
                // 2026-11-03：一个弹窗服务两行——主模型 / 备用模型。
                // 绑定的清单也跟着切换：备用模型拉的是备用接口的上游，
                // 两个接口的模型可能完全不同（家里中转站 vs 外面中转站）。
                ModelPickerSheet(
                    models: pickerForBackup ? fetchedBackupModels : fetchedModels,
                    selected: pickerForBackup ? $backupModel : $model
                )
            }
        }
    }

    // MARK: - 子视图

    private var quickConfigRow: some View {
        Button(action: { showingQuickPicker = true }) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
                Text(L10n.t("ui_25"))
                    .foregroundColor(.blue)
                Spacer()
            }
        }
    }

    private func editorRow(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .autocapitalization(.none)
                .disableAutocorrection(true)
        }
    }

    private func pickerRow(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        HStack {
            Text(label)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .frame(maxWidth: 220)
            .labelsHidden()
        }
    }

    private var tokenRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(authMethod == "None" ? L10n.t("i18n_425") : "\(authMethod) Token")
                    .font(.body)
                if showKey {
                    TextField("sk-...", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } else {
                    SecureField("sk-...", text: $apiKey)
                        .font(.system(.body, design: .monospaced))
                }
            }
            Spacer()
            Button(action: { showKey.toggle() }) {
                Image(systemName: showKey ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
    }

    /// 当前「自动判定」会走哪一条接口——直接说人话，不用用户猜。
    ///
    /// ⚠️ 2026-11-05：这里只是**网段预判**，不是最终结论。
    /// 用户明确指出「也要判定我在别的 WiFi 也是外面」——而网段预判做不到这件事：
    /// 别人家 WiFi 也是 192.168.x，一样被判成「在家」。
    /// 真正发请求时会有后台 /health 探活核实（BaseURLRouter.probeInBackground），
    /// 探不通会自动翻到备用地址。所以这里的文案必须写「预判」，
    /// 不能让用户以为「界面说在家就一定走内网」。
    private var activeRouteNote: String {
        let home = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return "备用接口已填，但主接口为空，会直接用备用接口" }
        switch BaseURLRouter.shared.lanVerdict(homeBase: home) {
        case .home:
            return "当前预判：在内网（若连的是别人家 WiFi，发请求时会自动改用备用接口）"
        case .away:
            return "当前判定：在外面（无内网 / 非自家网段）→ 用下面的备用接口"
        case .unknown:
            return "主接口不是内网地址，看不出在家还是在外 → 先试主接口，连不上自动换备用"
        }
    }

    /// 「实际请求」那一行要显示的地址：自动判定后会用的那条，再解析成完整端点。
    private var effectivePreviewEndpoint: String {
        let picked = pickedBaseForPreview
        guard !picked.isEmpty else { return "" }
        return ModelConfig.resolveEndpoint(picked, apiProtocol: apiProtocol)
    }

    /// 按当前输入框内容推断会用哪一条（不写缓存、不影响真实判定）。
    private var pickedBaseForPreview: String {
        let home = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = backupBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !away.isEmpty else { return home }
        guard !home.isEmpty else { return away }
        switch BaseURLRouter.shared.lanVerdict(homeBase: home) {
        case .home:    return home
        case .away:    return away
        case .unknown: return home
        }
    }

    // MARK: - 操作

    private func applyPreset(at index: Int) {
        let p = ModelConfig.providerPresets[min(index, ModelConfig.providerPresets.count - 1)]
        name = p.name
        provider = p.provider
        apiProtocol = p.protocol
        baseURL = p.baseURL
        model = p.model
        authMethod = p.auth
    }

    private func applyPreset(name presetName: String) {
        if let p = ModelConfig.providerPresets.first(where: { $0.name == presetName }) {
            name = p.name
            provider = p.provider
            apiProtocol = p.protocol
            baseURL = p.baseURL
            model = p.model
            authMethod = p.auth
        }
    }

    private func makeConfig() -> ModelConfig {
        ModelConfig(
            id: config?.id ?? UUID(),
            name: name.isEmpty ? model : name,
            provider: provider,
            apiProtocol: apiProtocol,
            baseURL: baseURL,
            backupBaseURL: backupBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            backupModel: backupModel.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey,
            model: model,
            authMethod: authMethod,
            isDefault: isDefault,
            temperature: temperature,
            maxTokens: maxTokens,
            contextTokens: contextTokens,
            group: group,
            paramAliases: ModelEditorView.parseAliases(paramAliasesText),
            fallbackIDs: fallbackIDs,
            protocolAutoFixEnabled: protocolAutoFixEnabled,
            compatMaxLevel: compatMaxLevel,
            streamUnsupported: !streamEnabled
        )
    }

    /// v3.5.13：字典 → 编辑文本（"key:value,key2:value2"）
    private static func aliasesString(_ aliases: [String: String]?) -> String {
        guard let a = aliases, !a.isEmpty else { return "" }
        return a.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
    }

    /// v3.5.13：编辑文本 → 字典（容忍中文逗号/空格，跳过非法项）
    private static func parseAliases(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for piece in text.components(separatedBy: CharacterSet(charactersIn: ",，;")) {
            let p = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = p.firstIndex(of: ":") else { continue }
            let k = String(p[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let v = String(p[p.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty, !v.isEmpty, k != v { out[k] = v }
        }
        return out
    }

    private func saveOnly() {
        let cfg = makeConfig()
        onSave(cfg)
        savedFlag = true
        presentationMode.wrappedValue.dismiss()
    }

    private func saveAndTest() {
        let cfg = makeConfig()
        onSave(cfg)
        savedFlag = true
        isTesting = true
        testStatus = L10n.t("i18n_426")
        testColor = .secondary
        // v7.1.95：保存后只做轻量'测试连接'（GET /models 测连通+延迟）——不再 POST
        // chat/completions 完整调用（耗 token 且慢——用户要求'保存只需要测试连接'）
        speedTestCore(config: cfg)
    }

    /// 2026-11-02：一键拉取上游模型并弹出滑动选择列表
    /// 流程：填好接口地址 + API Key → 点「测试连接」或「模型名称」→ GET {base}/models
    /// → 成功则弹出 ModelPickerSheet（滑动选择），失败则在行下方显示错误原因
    ///
    /// 2026-11-03：同时判定「在家 / 在外面」，把结论写进状态栏——
    /// 用户点「测试连接」就能顺带确认当前网络该走哪条接口，
    /// 不用自己猜「我在家用的是哪个地址」。
    private func fetchAndPickModels() {
        let cfg = makeConfig()
        let who = makeAtHomeNote()
        isTesting = true
        testStatus = "正在测试连接（\(who)）…"
        testColor = .secondary
        ModelAPIClient.shared.fetchModelList(config: cfg) { result in
            isTesting = false
            switch result {
            case .success(let models):
                fetchedModels = models
                if models.isEmpty {
                    testStatus = "\(who) · 接口连通，但未返回任何模型（请检查该地址是否支持 /models）"
                    testColor = .orange
                } else {
                    testStatus = "\(who) · 连接成功，获取到 \(models.count) 个模型"
                    testColor = .green
                    pickerForBackup = false
                    showingModelPicker = true
                }
            case .failure(let error):
                testStatus = "\(who) · 连接失败：\(error)"
                testColor = .red
            }
        }
    }

    /// 2026-11-03：点「模型名称 / 备用模型」→ 拉该地址的上游模型 → 弹窗挑。
    ///
    /// 备用模型拉的是**备用接口**的模型清单：家里中转站和外面中转站
    /// 未必是同一批模型，用主接口的清单去挑备用模型会挑到不存在的名字。
    private func openPicker(forBackup: Bool) {
        pickerForBackup = forBackup

        // 该行对应的接口地址：主模型配主接口，备用模型配备用接口
        let targetBase = forBackup
            ? backupBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetBase.isEmpty else {
            testStatus = forBackup
                ? "先填上面的「备用接口」，才能获取它的模型列表"
                : "先填「接口地址」，才能获取模型列表"
            testColor = .orange
            return
        }

        // 备用接口还没填时，退回用主地址取清单（至少让用户能看到可选模型）
        var probe = makeConfig()
        probe.baseURL = targetBase
        probe.backupBaseURL = ""
        probe.model = forBackup ? (backupModel.isEmpty ? model : backupModel) : model

        isTesting = true
        testStatus = "正在获取模型列表（\(makeAtHomeNote())）…"
        testColor = .secondary
        ModelAPIClient.shared.fetchModelList(config: probe) { result in
            isTesting = false
            switch result {
            case .success(let models):
                if forBackup { fetchedBackupModels = models } else { fetchedModels = models }
                if models.isEmpty {
                    testStatus = "接口连通，但未返回任何模型（请检查该地址是否支持 /models）"
                    testColor = .orange
                } else {
                    testStatus = "连接成功，获取到 \(models.count) 个模型"
                    testColor = .green
                    showingModelPicker = true
                }
            case .failure(let error):
                testStatus = "连接失败：\(error)"
                testColor = .red
            }
        }
    }

    /// 「在家 / 在外面」的一句人话结论，测试连接时直接显示。
    private func makeAtHomeNote() -> String {
        let home = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { return "未填接口地址" }
        switch BaseURLRouter.shared.lanVerdict(homeBase: home) {
        case .home:    return "预判：在内网，走接口地址（连不上会自动换备用）"
        case .away:    return "判定：在外面，走备用接口"
        case .unknown: return "判定：主接口非内网地址，先试主接口"
        }
    }

    private func fetchUpstreamModels() {
        let cfg = makeConfig()
        onSave(cfg)
        savedFlag = true
        isTesting = true
        testStatus = L10n.t("i18n_427")
        testColor = .secondary
        ModelAPIClient.shared.fetchModelList(config: cfg) { result in
            isTesting = false
            switch result {
            case .success(let models):
                fetchedModels = models
                if models.isEmpty {
                    testStatus = L10n.t("i18n_428")
                    testColor = .orange
                } else {
                    testStatus = L10n.t("i18n_429", models.count)
                    testColor = .green
                    showingModelPicker = true
                }
            case .failure(let error):
                testStatus = error
                testColor = .red
            }
        }
    }

    /// v2.9.107：只测接口延迟（不保存）
    private func speedTestOnly() {
        isTesting = true
        testStatus = L10n.t("i18n_430")
        testColor = .secondary
        speedTestCore(config: makeConfig())
    }

    /// v7.1.95：轻量测试连接（GET {base}/models 测连通+延迟）——saveAndTest 与 speedTestOnly 共用
    private func speedTestCore(config: ModelConfig) {
        // 2026-11-02 通用接口：自动剥端点后缀 + 纯主机补 /v1（与主流程同一套解析）
        // 2026-11-03：用 effectiveBaseURL，「测试连接」测的就是真正会用的那条接口
        guard let url = URL(string: ModelConfig.modelsEndpoint(config.effectiveBaseURL)) else {
            isTesting = false
            testStatus = L10n.t("i18n_1103")
            testColor = .red
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        setHTTPMethod("GET", on: &req)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.authMethod == "API Key" {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
        } else if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        URLSession.shared.dataTask(with: req) { _, _, error in
            DispatchQueue.main.async {
                isTesting = false
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                if error != nil {
                    testStatus = L10n.t("i18n_418", ms)
                    testColor = .red
                } else {
                    testStatus = L10n.t("i18n_431", ms)
                    testColor = ms < 500 ? .green : (ms < 2000 ? .orange : .red)
                }
            }
        }.resume()
    }
}

// MARK: - 快速配置选择器

struct QuickConfigPicker: View {
    @Environment(\.presentationMode) var presentationMode
    let onSelect: (String) -> Void

    var body: some View {
        CompatNav {
            List(ModelConfig.providerPresets, id: \.name) { preset in
                Button(action: {
                    onSelect(preset.name)
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.blue)
                                .frame(width: 34, height: 34)
                            Image(systemName: "sparkles")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.body)
                            Text("\(preset.protocol) · \(preset.baseURL)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("ui_25"))
            .toolbar {
                Button(L10n.t("ui_177")) { presentationMode.wrappedValue.dismiss() }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 模型选择 Sheet（2026-11-02 改造：半屏弹出 + 搜索 + 滑动选择 + 分组标注）

struct ModelPickerSheet: View {
    let models: [String]
    @Binding var selected: String
    @Environment(\.presentationMode) var presentationMode
    @State private var query = ""
    /// 2026-11-03：手填模型名的独立输入（与搜索框分开，免得互相干扰）
    @State private var handInput = ""

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    /// 按供应商前缀分组（deepseek-*/gpt-*/claude-*/glm-* 等），方便滑动查找
    private var grouped: [(String, [String])] {
        var dict: [String: [String]] = [:]
        for m in filtered {
            let key: String
            let lower = m.lowercased()
            if lower.hasPrefix("gpt") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") { key = "OpenAI" }
            else if lower.hasPrefix("deepseek") { key = "DeepSeek" }
            else if lower.hasPrefix("claude") { key = "Anthropic" }
            else if lower.hasPrefix("glm") { key = "智谱 GLM" }
            else if lower.hasPrefix("qwen") { key = "通义千问" }
            else if lower.hasPrefix("kimi") || lower.hasPrefix("moonshot") { key = "Kimi" }
            else if lower.hasPrefix("gemini") { key = "Gemini" }
            else if lower.hasPrefix("grok") { key = "xAI" }
            else if lower.hasPrefix("llama") || lower.hasPrefix("mixtral") || lower.hasPrefix("mistral") { key = "Meta/Mistral" }
            else { key = "其他" }
            dict[key, default: []].append(m)
        }
        let order = ["DeepSeek", "OpenAI", "Anthropic", "智谱 GLM", "通义千问", "Kimi", "Gemini", "xAI", "Meta/Mistral", "其他"]
        return order.compactMap { k in dict[k].map { (k, $0.sorted()) } }
    }

    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                // 搜索框
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索模型", text: $query)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    if !query.isEmpty {
                        Button(action: { query = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                List {
                    ForEach(grouped, id: \.0) { section in
                        Section(header: Text(section.0)) {
                            ForEach(section.1, id: \.self) { m in
                                Button(action: {
                                    selected = m
                                    presentationMode.wrappedValue.dismiss()
                                }) {
                                    HStack(spacing: 10) {
                                        // 选中标记
                                        Image(systemName: selected == m ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(selected == m ? .blue : Color.secondary.opacity(0.45))
                                        Text(m)
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        if ModelConfig.modelSupportsVision(m) {
                                            Image(systemName: "photo")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(.blue)
                                                .accessibilityLabel("Vision")
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text(models.isEmpty ? "还没有模型清单：点行尾箭头重新拉取，或直接在下面手填" : "没有匹配的模型")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // 2026-11-03：手填兜底。
                    // 上游 /models 未必返回（有的中转关了这接口，或关键模型不在清单里），
                    // 用户得能自己敲一个名字，不能因为拉不到列表就选不了模型。
                    // 独立字段 handInput：不跟搜索框共用，避免「搜着搜着搜出个模型名」的歧义。
                    Section(header: Text("手动输入")) {
                        HStack(spacing: 8) {
                            TextField("直接填模型 ID，如 gpt-4o-mini", text: $handInput)
                                .font(.system(.subheadline, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            Button("用这个") {
                                let t = handInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !t.isEmpty else { return }
                                selected = t
                                presentationMode.wrappedValue.dismiss()
                            }
                            .font(.subheadline.weight(.semibold))
                            .disabled(handInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("选择模型（\(models.count)）")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("ui_177")) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheetDetentsHeight(520)
    }
}

// MARK: - v2.9.107 配置导入导出（FileDocument）

struct ConfigDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - v2.9.107 用量统计页（聚合本地 usage.jsonl）

struct UsageStatsView: View {
    @Environment(\.presentationMode) var presentationMode
    @State private var records: [[String: Any]] = []

    var body: some View {
        CompatNav {
            List {
                let agg = aggregate()
                Section(header: Text(L10n.t("ui_60"))) {
                    // v7.1.109-minis：6 卡分列（对齐 OpenMinis TokenUsageSheet 的 Input/Output 分列）
                    HStack {
                        statCell(title: L10n.t("i18n_433"), value: "\(agg.total)", color: .blue)
                        statCell(title: L10n.t("i18n_434"), value: agg.total > 0 ? "\(Int(Double(agg.ok) / Double(agg.total) * 100))%" : "-", color: .green)
                        statCell(title: L10n.t("i18n_435"), value: agg.total > 0 ? "\(agg.elapsed / agg.total)ms" : "-", color: .orange)
                    }
                    // v7.1.109-peers：缓存四件套（对齐 OpenMinis TokenUsageSheet）——
                    // 总输入(含缓存)/输出/缓存读取/命中率，直读中转站 usage
                    HStack {
                        statCell(title: "总输入(含缓存)", value: "\(fmtK(agg.inputTokens + agg.cacheRead))", color: .blue)
                        statCell(title: "输出 Token", value: "\(fmtK(agg.outputTokens))", color: .purple)
                        statCell(title: "缓存读取", value: "\(fmtK(agg.cacheRead))", color: .green)
                        statCell(title: "缓存命中率", value: cacheRateText(agg.cacheRead, agg.byProvider), color: .indigo)
                    }
                }

                if !agg.byProvider.isEmpty {
                    Section(header: Text(L10n.t("ui_69"))) {
                        ForEach(agg.byProvider.sorted(by: { $0.total > $1.total }), id: \.self) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(row.name).font(.subheadline.weight(.medium))
                                    Spacer()
                                    // v7.1.109-peers：总输入(含缓存) / 输出（对齐 Minis 行右侧）
                                    Text("\(fmtK(row.inputTokens + row.cacheReadTokens)) / \(fmtK(row.outputTokens))")
                                        .font(.caption.weight(.medium))
                                        .foregroundColor(.secondary)
                                }
                                // v7.1.109-peers：缓存明细行（输入(新)/输出/缓存读取/命中率）
                                HStack(spacing: 8) {
                                    Text("输入 \(fmtK(row.inputTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("输出 \(fmtK(row.outputTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("缓存 \(fmtK(row.cacheReadTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("命中率 \(Int(row.cacheHitRate * 100))%").font(.caption2).foregroundColor(.secondary)
                                    Spacer()
                                }
                                // v7.1.109-peers：日均/会话均值/会话/活跃天数（对齐 Minis 明细）
                                HStack(spacing: 8) {
                                    Text("日均 \(fmtK(row.dailyTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("会话均值 \(fmtK(row.perSessionTokens))").font(.caption2).foregroundColor(.secondary)
                                    Text("会话 \(row.sessionCount)").font(.caption2).foregroundColor(.secondary)
                                    Text("活跃 \(row.activeDays.count) 天").font(.caption2).foregroundColor(.secondary)
                                    Spacer()
                                }
                                // v7.1.109-minis：token 输入/输出比例条（Input 蓝 / Output 紫——同列可视）
                                if row.totalTokens > 0 {
                                    HStack(spacing: 3) {
                                        GeometryReader { geo in
                                            HStack(spacing: 0) {
                                                let inRatio = row.totalTokens > 0 ? CGFloat(row.inputTokens) / CGFloat(row.totalTokens) : 0
                                                Rectangle()
                                                    .fill(Color.purple.opacity(0.75))
                                                    .frame(width: max(4, geo.size.width * min(inRatio, 1)))
                                                Rectangle()
                                                    .fill(Color.indigo.opacity(0.5))
                                            }
                                        }
                                        .frame(height: 6)
                                        .clipShape(Capsule())
                                        Text("\(fmtK(row.inputTokens)) → \(fmtK(row.outputTokens))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                ProgressView(value: row.total > 0 ? Double(row.ok) / Double(row.total) : 0)
                                    .accentColor(.green)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !records.isEmpty {
                    Section(header: Text(L10n.t("ui_96"))) {
                        ForEach(0..<min(records.count, 30), id: \.self) { i in
                            requestRow(records[i])
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.t("i18n_409"))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.t("i18n_436")) {
                        UsageRecorder.shared.clear()
                        records = []
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("i18n_1180")) { presentationMode.wrappedValue.dismiss() }
                }
            }
            .onAppear {
                // 后台线程读取，避免主线程卡死
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = UsageRecorder.shared.records
                    DispatchQueue.main.async {
                        records = result
                    }
                }
            }
        }
    }

    private func fmtK(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        return n >= 1000 ? String(format: "%.1fk", Double(n) / 1000.0) : "\(n)"
    }

    /// v7.1.109-peers：总缓存命中率——cache/(cache+miss) 标准口径；无 miss 时按 cache/总输入
    private func cacheRateText(_ cacheRead: Int, _ byProvider: [ProviderAgg]) -> String {
        let miss = byProvider.reduce(0) { $0 + $1.cacheMissTokens }
        if cacheRead + miss > 0 {
            return "\(Int(Double(cacheRead) / Double(cacheRead + miss) * 100))%"
        }
        return "-"
    }

    private func statCell(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline).foregroundColor(color)
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func requestRow(_ r: [String: Any]) -> some View {
        let ts = r["ts"] as? Double ?? 0
        let ok = r["ok"] as? Bool ?? false
        let el = r["elapsedMs"] as? Int ?? 0
        let name = r["name"] as? String ?? "-"
        let model = r["model"] as? String ?? "-"
        let error = r["error"] as? String ?? ""
        // v7.1.98：token 显示——优先真实 usage total_tokens，无则回退估算输入
        // v7.1.267-precision：精确拆分——真实 usage 按 prompt/completion 分开读，
        // 缓存命中/新增（cacheRead/cacheMiss）单列——显示从"≈total"升级为"输入+输出+缓存+新增"
        let realIn = r["promptTokens"] as? Int ?? 0
        let realOut = r["completionTokens"] as? Int ?? 0
        let cacheR = r["cacheReadTokens"] as? Int ?? 0
        let cacheM = r["cacheMissTokens"] as? Int ?? 0
        let estTok = r["estInputTokens"] as? Int ?? 0
        let tokText: String
        if realIn > 0 || realOut > 0 {
            tokText = "≈\(fmtK(realIn + realOut)) tok"
        } else if estTok > 0 {
            tokText = "≈\(fmtK(estTok)) tok(估)"
        } else {
            tokText = ""
        }
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(ok ? .green : .red)
                    .font(.system(size: 13))
                Text(name).font(.subheadline).lineLimit(1)
                Spacer()
                if !tokText.isEmpty {
                    Text(tokText).font(.caption2).foregroundColor(.purple)
                }
                Text("\(el)ms").font(.caption).foregroundColor(.secondary)
                Text(f.string(from: d)).font(.caption2).foregroundColor(.secondary)
            }
            Text(model).font(.caption).foregroundColor(.secondary).lineLimit(1)
            // v7.1.267-precision：每条请求精确拆分——输入(全量)/缓存命中/新增/输出，
            // 一眼看清真实计费口径（缓存命中按低价计、新增按全价、输出单独）
            if realIn > 0 || cacheR > 0 || cacheM > 0 || realOut > 0 {
                Text("输入 \(fmtK(realIn)) · 缓存 \(fmtK(cacheR)) · 新增 \(fmtK(cacheM)) · 输出 \(fmtK(realOut))")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if !ok, !error.isEmpty {
                Text(error).font(.caption2).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private struct ProviderAgg: Hashable {
        let name: String
        var total: Int = 0
        var ok: Int = 0
        var elapsed: Int = 0
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var totalTokens: Int = 0
        // v7.1.109-peers：缓存统计（直读中转站 usage）——缓存读取/未命中/命中率/会话/活跃天数
        var cacheReadTokens: Int = 0
        var cacheMissTokens: Int = 0
        var sessionCount: Int = 0
        var activeDays: Set<String> = []
        var lastTs: Double = 0
        /// 缓存命中率（标准口径 cache / (cache+miss)；无 miss 数据时按 cache / 总输入）
        var cacheHitRate: Double {
            let denom = cacheReadTokens + cacheMissTokens
            if denom > 0 { return Double(cacheReadTokens) / Double(denom) }
            let totalIn = inputTokens + cacheReadTokens
            return totalIn > 0 ? Double(cacheReadTokens) / Double(totalIn) : 0
        }
        var dailyTokens: Int {
            let totalInOut = inputTokens + outputTokens
            return activeDays.isEmpty ? totalInOut : totalInOut / max(1, activeDays.count)
        }
        var perSessionTokens: Int {
            let totalInOut = inputTokens + outputTokens
            return sessionCount > 0 ? totalInOut / sessionCount : totalInOut
        }
    }

    /// v7.1.109-minis：token 分列聚合（对齐 OpenMinis TokenUsageSheet / ModelStats）——
    /// 真实 usage(prompt/completion/total) 优先，无则回退估算输入(estInputTokens)；
    /// total 无真实值按 input+output 推算。
    /// v7.1.109-peers：缓存四件套直读中转站 usage；会话按时间间隔>30min 分桶，活跃天数按日期去重。
    private func aggregate() -> (total: Int, ok: Int, elapsed: Int, inputTokens: Int, outputTokens: Int, totalTokens: Int, cacheRead: Int, byProvider: [ProviderAgg]) {
        var total = 0, ok = 0, elapsed = 0, inputTokens = 0, outputTokens = 0, totalTokens = 0, cacheRead = 0
        var map: [String: ProviderAgg] = [:]
        for r in records {
            total += 1
            let o = r["ok"] as? Bool ?? false
            if o { ok += 1 }
            elapsed += r["elapsedMs"] as? Int ?? 0
            let pt = r["promptTokens"] as? Int ?? 0
            let ct = r["completionTokens"] as? Int ?? 0
            let tt = r["totalTokens"] as? Int ?? 0
            let ei = r["estInputTokens"] as? Int ?? 0
            let inT = pt > 0 ? pt : ei
            let outT = ct
            let totT = tt > 0 ? tt : (inT + outT)
            let cr = r["cacheReadTokens"] as? Int ?? 0
            let cm = r["cacheMissTokens"] as? Int ?? 0
            inputTokens += inT
            outputTokens += outT
            totalTokens += totT
            cacheRead += cr
            let name = r["name"] as? String ?? "-"
            let ts = r["ts"] as? Double ?? 0
            var a = map[name] ?? ProviderAgg(name: name)
            a.total += 1
            if o { a.ok += 1 }
            a.elapsed += r["elapsedMs"] as? Int ?? 0
            a.inputTokens += inT
            a.outputTokens += outT
            a.totalTokens += totT
            a.cacheReadTokens += cr
            a.cacheMissTokens += cm
            if ts > 0 {
                // 会话分桶：与上一条间隔 > 30 分钟 → 新会话
                if a.lastTs > 0, ts - a.lastTs > 1800 { a.sessionCount += 1 }
                a.lastTs = max(a.lastTs, ts)
                let day = String(Int(ts / 86400))
                a.activeDays.insert(day)
            }
            map[name] = a
        }
        for (k, v) in map {
            var v = v
            if v.total > 0 { v.sessionCount += 1 }   // 首条也算一个会话
            map[k] = v
        }
        return (total, ok, elapsed, inputTokens, outputTokens, totalTokens, cacheRead, Array(map.values))
    }
}
