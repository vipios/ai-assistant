import SwiftUI
import UIKit
import RSKGrowingTextView
import UniformTypeIdentifiers

// v7.4.1-fix73h：滚动位置检测（悬浮按钮用）——由 ScrollGeometryBridge（UIKit KVO）上报，
// 不再用 PreferenceKey + named coordinateSpace（iOS 16.0-16.3 滚动时不重新提交，见 ScrollGeometryBridge.swift）

struct ChatView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var modelStore = ModelStore.shared
    /// 2026-11-03：顶栏那颗状态灯的真实数据源（探活 / 真实请求结果双向回报）
    @ObservedObject private var conn = ConnectionMonitor.shared
    @ObservedObject private var tts = TTSService.shared
    // 2026-11-02：语音输入（复用 GirlVoice 的 SFSpeechRecognizer 实现，不另造一套）
    @ObservedObject private var voice = GirlVoice.shared

    @State private var inputText = ""
    @State private var inputHeight: CGFloat = 36
    // v7.2.3-fix14：工具卡参数行折叠——默认一行+▽，点击展开完整命令/参数
    /// v7.2.3-fix20：连续工具折叠展开状态（按组 id）
    @State private var toolsRunExpanded: Set<String> = []
    // v2.9.234：推理强度/智能搜索持久化(@AppStorage)——之前纯@State,关app重开必丢
    @AppStorage("chat_reasoning") private var reasoning = 0   // 0=低 1=中 2=高 3=最高(xhigh) 4=极限(max)
    @AppStorage("chat_smart_search") private var smartSearch = true
    // v3.1.25：思考模型总开关——关闭时完全不思考，直接回复（reasoning_effort=none）
    @AppStorage("chat_think_enabled") private var thinkEnabled = true
    @State private var keyboardHeight: CGFloat = 0   // v2.9.234：键盘高度(消息列表跟随上移)
    // 2026-11-02：语音录入时的呼吸动画相位（仅控制麦克风按钮透明度）
    @State private var micPulse = false
    @State private var attachmentSheet: AttachmentSheet?
    // fix73j：子代理详情 sheet——点主会话"子代理完成卡"进入独立轨迹界面
    @State private var subAgentDetailTaskID: String?
    @State private var subAgentDetailFallback: String?
    // v3.1.67：文件选择改用 UIKit UIDocumentPickerViewController（asCopy: true）从顶层 VC present——
    // .fileImporter 在真机 iPhone 上有已知 bug（Apple 论坛 775056：选择器打不开/无法交互/回调不触发），
    // UIKit 方案真机稳定。标记位 + sheet onDismiss 触发，保证面板完全关闭后再 present（不再猜时间延迟）。
    @State private var pendingFilePick = false
    @State private var showModelPicker = false  // v2.9.36：聊天框切换上游模型
    @State private var showVoicePicker = false  // v7.2.4：长按全局喇叭切音色（萝莉/猫娘御姐/兔娘）——聊天界面可改，HUD 角色音色固定不变
    @State private var showToolCenter = false  // v6.1.5-14bm：/tools 打开工具中心
    @State private var showTerminal = false  // v7.0.4：终端按钮 → 简易终端
    // v3.3.4：输入框 + 号展开"应用/相册/文件/浏览器"快捷行（点 + 变 x 收起）
    @State private var attachExpanded = false
    // 2026-11-02：中转站后台（附件栏入口）——呈现样式对齐「文件」选择器的 formSheet 卡片效果
    @State private var showRelayAdmin = false
    // 2026-11-02：路由器控制（附件栏入口）——中转站重启 / 路由器重启
    @State private var showRouterControl = false
    // 2026-11-03：聊天诊断（顶栏听诊器图标）——看每次请求为什么停了、崩前在做什么
    @State private var showDiagnostics = false

    // v2.9.9：多模态图片（data URL）。选择相册图片后转 base64 暂存，发送时随消息传给模型
    @State private var pendingImages: [String] = []
    // v2.9.10：统一待发送附件（图片缩略图 / 应用图标 / 文件），输入栏上方预览
    @State private var pendingAttachments: [PendingAttachment] = []

    // 2026-11-05：本轮「真的跑完了没有」——用户反馈分不清 AI 是停了还是在干活。
    //   只在 isLoading 翻转时写，不参与流式输出的高频更新，所以不会牵动 body 重算。
    //   turnStartedAt 给顶部状态条走秒表；lastTurnSeconds 给列表末尾那行「本轮结束」。
    @State private var turnStartedAt: Date?
    @State private var lastTurnSeconds: Double?
    @State private var turnEnded = false

    // v2.9.2：多选模式（勾选会话内容 → 复制 / 分享到其他 App）
    @State private var selectionMode = false
    @State private var selectedIds = Set<UUID>()
    @State private var showToast = false
    @State private var toastText = L10n.t("i18n_1197")
    // 2026-11-05 fix-freeze-4：**必须**用 @StateObject。
    //
    // `@StateObject` 的语义 = 「本视图订阅该对象的 objectWillChange」，与 body 读不读它无关。
    // 所以真正要修的不是"取消订阅"（取消后 fastScrolling 降级就永久失效了），
    // 而是**让这个对象别乱发通知**。修法分三处，全部在外层对象上：
    //
    //   ① canScrollUp / canScrollDown 搬去独立的 ChatScrollFlags（只有那个 40pt 圆钮订阅）。
    //      它们原本是本对象的 @Published，而流式输出时翻得极频繁
    //      （变高→不在底→贴底→又在底→下一条又变高），几十次全量 body 重算。
    //   ② offset / contentHeight / viewportHeight 早就是普通属性（上一轮改的），不发通知。
    //   ③ objectWillChange 现在只剩 activity 的转发 —— 而 activity 只由**用户手指真的
    //      拖拽/惯性滚动**触发（见 ScrollGeometryBridge.onUserScroll），每轮滚动翻转 2 次。
    //
    // 结果：滚动期间 body 重算次数从「每帧」降到「每轮 2 次」，而这两次正是
    // 「正文降级为轻量 Text / 恢复 UITextView」所必需的。滚动性能优化保留，卡死根除。
    @StateObject private var scroll = ChatScrollState()

    var body: some View {
        CompatNav {
            VStack(spacing: 0) {
                if modelStore.configs.isEmpty {
                    emptyState
                } else if store.currentMessages.isEmpty {
                    homeState
                } else {
                    messageList
                }
                // 2026-11-05：固定状态条（不随列表滚动）。
                // 用户原话「我都不知道他是停止工作了还是正在工作」——列表里的
                // ThinkingPanel 一往上翻就看不见，而「运行了 N 个工具 12.7s」那行是
                // **已完成工具的汇总**，长得像结论。所以把实时状态钉在输入框上方。
                RunStatusStrip(startedAt: turnStartedAt)
                // v2.9.72：工作流可视化步骤条
                WorkflowProgressView()
            }
            // v2.9.244：输入框改用 safeAreaInset 挂底部——标准键盘避让，不再手动 padding 双重压缩内容区
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inputBar
            }
            .navigationTitle(selectionMode ? L10n.t("i18n_1031", selectedIds.count) : store.currentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v3.4.3：标题 + 模型名（🟢 deepseek v4 ▽）与右侧图标放同一平行线（导航栏 principal）
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text(selectionMode ? L10n.t("i18n_1031", selectedIds.count) : store.currentTitle)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Button(action: { showModelPicker = true }) {
                            HStack(spacing: 4) {
                                // 2026-11-03 用户要求：这颗灯要「变成真实的」。
                                // 以前写死 green——断网、密钥错、路由器关机都还亮着，等于骗人。
                                // 现在由 ConnectionMonitor 驱动：真连通绿、连不上红、没配模型灰。
                                Image(systemName: conn.state == .unknown ? "circle" : "circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundColor(connTint)
                                // 2026-11-02 按用户要求：顶栏显示模型名（不是供应商名）
                                Text(modelStore.defaultConfig?.model ?? L10n.t("i18n_1032"))
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectionMode {
                        Button(L10n.t("ui_40")) { exitSelection() }
                    } else {
                        HStack(spacing: 14) {
                            Button(action: { withAnimation { AppUIState.shared.drawerOpen.toggle() } }) {
                                Image(systemName: "line.horizontal.3")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            // v6.0.28：加号按钮放在左边（三横线后面，新建会话）
                            Button(action: { store.newConversation() }) {
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectionMode {
                        HStack(spacing: 14) {
                            Button(action: copySelected) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 18, weight: .semibold))
                            }
                            .disabled(selectedIds.isEmpty)
                            SharePresenter.toolbarShare(text: exportText())
                                .disabled(selectedIds.isEmpty)
                        }
                    } else {
                        // 2026-11-02 按用户要求重排顶栏：喇叭 → 终端 → 勾选
                        // 三个图标统一 18pt 字号 + 24×24 命中框，保证视觉尺寸与基线和喇叭一致
                        HStack(spacing: 12) {
                            // v4.4.18：全局朗读开关——开着时 AI 流式回复自动朗读
                            // v7.2.4：长按弹音色切换（萝莉/猫娘御姐/兔娘）；点按仍切换开关。HUD 角色音色固定，聊天界面独立可改。
                            Button(action: { withAnimation { tts.speakerEnabled.toggle() } }) {
                                Image(systemName: tts.speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")   // v6.1.5-14bg：关闭态用带斜杠喇叭（标准静音图标），不再普通喇叭灰显
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(tts.speakerEnabled ? .tmCyan : .secondary)
                                    .frame(width: 24, height: 24)
                            }
                            .simultaneousGesture(LongPressGesture().onEnded { _ in showVoicePicker = true })
                            .confirmationDialog("音色：\(tts.voicePreset.displayName)", isPresented: $showVoicePicker, titleVisibility: .visible) {
                                ForEach(VoicePreset.allCases, id: \.self) { v in
                                    Button(v.displayName) { withAnimation { tts.voicePreset = v } }
                                }
                                // v7.1.41：手动压缩当前会话（对齐 Claude Code /compact）——AI 摘要替换旧历史，持久化
                                Button("压缩当前会话") { compactNow() }
                                Button("取消", role: .cancel) {}
                            }
                            // 终端：从输入框移到顶栏，占「喇叭与勾选之间」的位置
                            Button(action: { showTerminal = true }) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                            // 勾选/选择按钮
                            Button(action: enterSelection) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 24, height: 24)
                            }
                            .disabled(store.currentMessages.isEmpty)
                            // 2026-11-03：诊断入口。
                            // 用户要求「出问题自动回日志让我查看」——这里就是查看的地方。
                            // 平时不打扰；有异常请求时图标带一个小红点提示去看。
                            Button(action: { showDiagnostics = true }) {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: "stethoscope")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, height: 24)
                                    if ChatDiagnostics.shared.abnormalCount > 0 {
                                        Circle()
                                            .fill(Color.orange)
                                            .frame(width: 6, height: 6)
                                            .offset(x: 1, y: -1)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }
            }
            // v2.9.244：删除手动 keyboardHeight padding（会与键盘避让叠加导致内容区被拉高/压缩），键盘避让交给 safeAreaInset
            // v2.9.235：键盘监听仍保留——用于键盘弹出时消息列表滚到底部

            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                let h = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = h }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.easeOut(duration: 0.25)) { keyboardHeight = 0 }
            }
            .overlay(Group {
                if showToast {
                    Text(toastText)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.top, 8)
                }
            }, alignment: .top)
            // v6.0.7：去掉聊天页右下角小女孩 overlay——桌面悬浮 HUD 已是小女孩，再叠一个会重复成两个。
            // （原 v4.5.0 的 GirlCompanionView 悬浮已移除；GirlCompanion.enabled 仍用于 AppMain 自动拉起桌面悬浮）
        }
        .navigationViewStyle(.stack)
        // fix73j：子代理详情 sheet——点主会话"子代理完成卡"进入独立轨迹界面
        .sheet(isPresented: Binding(
            get: { subAgentDetailTaskID != nil },
            set: { if !$0 { subAgentDetailTaskID = nil } })) {
            if let tid = subAgentDetailTaskID {
                SubAgentDetailView(taskID: tid, fallbackJSON: subAgentDetailFallback)
            }
        }
        // v2.9.31：授权弹窗已整体移除（工具搜索即自动授权，无弹窗）。
        .sheet(item: $attachmentSheet, onDismiss: {
            // v3.1.67：面板完全关闭后再触发文件选择（UIKit 从顶层 VC present，真机稳定）
            // v3.1.70：延迟 0.6s 再 present——onDismiss 触发时 SwiftUI sheet 的关闭动画
            // （约 0.5s）还没完全结束，立即 present 的 UIDocumentPicker 会被 sheet 收尾逻辑
            // 顶掉，表现为"弹出 0.5 秒后自动退回聊天界面"（真机实测 bug）
            if pendingFilePick {
                pendingFilePick = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    Self.presentDocumentPicker { urls in
                        handlePickedFiles(urls)
                    }
                }
            }
        }) { sheet in
            switch sheet {
            case .panel:
                // v2.9.35：传已选数量，面板右上角显示"已选 N"（对齐老 MCP）
                // 紧凑半屏（老 MCP"添加内容"卡片式）；presentationDetents 需 iOS16+
                if #available(iOS 16.0, *) {
                    AttachmentPanelView(onPick: { pick in
                        // v2.9.39：浏览器入口直接开悬浮窗（不占 sheet）
                        // v3.1.67：文件入口不再用 .fileImporter（真机有 bug），改记 pendingFilePick，
                        // 由 sheet onDismiss 在面板完全关闭后触发 UIKit 文档选择器
                        if pick == .browser {
                            self.attachmentSheet = nil
                            FloatingBrowser.shared.show()
                        } else if pick == .documentPicker {
                            self.pendingFilePick = true
                            self.attachmentSheet = nil
                        } else {
                            self.attachmentSheet = pick
                        }
                    }, selectedCount: pendingAttachments.count)
                        .sheetDetentsHeight(340)   // v2.9.37：4 入口 2×2 网格需更高
                } else {
                    AttachmentPanelView(onPick: { pick in
                        if pick == .browser {
                            self.attachmentSheet = nil
                            FloatingBrowser.shared.show()
                        } else if pick == .documentPicker {
                            self.pendingFilePick = true
                            self.attachmentSheet = nil
                        } else {
                            self.attachmentSheet = pick
                        }
                    }, selectedCount: pendingAttachments.count)
                }
            case .browser:
                // v2.9.39：浏览器已改为悬浮窗，面板入口在 onPick 闭包里直接开悬浮窗
                EmptyView()
            case .appPicker:
                AppPickerView { app in
                    // v2.9.10：应用选择 → 附件预览（图标 + 名称 + bundleId）
                    let icon = Self.appIcon(for: app.path)
                    let att = PendingAttachment(
                        kind: .app,
                        displayName: app.name,
                        dataURL: nil,
                        thumbnail: icon,
                        bundleId: app.bundleId,
                        fileURL: nil
                    )
                    self.pendingAttachments.append(att)
                    // v2.9.61：不再往输入框塞 [📱应用] 标签，附件只在上方预览条显示（微信风格），发送时自动生成描述
                }
            case .photoPicker:
                PhotoPickerView { urls in
                    // v2.9.9：真正把图片内容转 base64 传给模型（不再只是文件名）
                    var dataURLs: [String] = []
                    var names: [String] = []
                    for u in urls {
                        if let d = Self.imageDataURL(for: u) {
                            dataURLs.append(d)
                            names.append(u.lastPathComponent)
                            // v2.9.10：同时生成带缩略图的附件，输入栏预览
                            let thumb = UIImage(contentsOfFile: u.path)
                            self.pendingAttachments.append(PendingAttachment(
                                kind: .image,
                                displayName: u.lastPathComponent,
                                dataURL: d,
                                thumbnail: thumb,
                                bundleId: nil,
                                fileURL: u
                            ))
                        }
                    }
                    // v2.9.61：图片缩略图在预览条显示，不再往输入框塞 [🖼图片] 标签
                    if dataURLs.isEmpty {
                        self.pendingImages = []
                    } else {
                        self.pendingImages = dataURLs
                    }
                }
            case .documentPicker:
                // v3.1.67：文件选择已改用 UIKit UIDocumentPickerViewController（见 onDismiss + presentDocumentPicker），
                // .fileImporter 在真机 iPhone 有已知 bug，弃用
                EmptyView()
            }
        }
        // v2.9.36：聊天框切换上游模型（点"当前模型"弹出，老 MCP 风格半屏）
        .sheet(isPresented: $showModelPicker) {
            // 2026-11-02：弹窗改为「模型列表为主」——高度从固定 360 提到中档位（约屏高 55%），
            // 模型多时可直接滚动；用户也可下拉放大到全屏。
            if #available(iOS 16.0, *) {
                ChatModelPickerSheet { cfg in
                    // 点选即切换默认模型
                    var c = cfg
                    c.isDefault = true
                    modelStore.update(c)
                    showModelPicker = false
                    showToast(L10n.t("i18n_1033", cfg.name))
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            } else {
                ChatModelPickerSheet { cfg in
                    var c = cfg
                    c.isDefault = true
                    modelStore.update(c)
                    showModelPicker = false
                    showToast(L10n.t("i18n_1033", cfg.name))
                }
            }
        }
        // v3.0.76：快捷标签 sheet
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickTerminalPresented }, set: { AppUIState.shared.quickTerminalPresented = $0 })) {
            RemoteTerminalView()
        }
        // v7.0.4：聊天框终端按钮 → 简易终端（统一环境 shell.exec）
        .sheet(isPresented: $showTerminal) {
            TerminalView()
        }
        // 2026-11-02：中转站后台——呈现样式对齐「文件」选择器（formSheet 卡片效果 + 大高度）
        .sheet(isPresented: $showRelayAdmin) {
            if #available(iOS 16.0, *) {
                RelayAdminView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            } else {
                RelayAdminView()
            }
        }
        // 2026-11-02：路由器控制——中转站重启 / 路由器重启（各带确认取消）
        .sheet(isPresented: $showRouterControl) {
            if #available(iOS 16.0, *) {
                RouterControlView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            } else {
                RouterControlView()
            }
        }
        // 2026-11-03：聊天诊断——「AI 莫名停止」「闪退」都在这里看原因
        .sheet(isPresented: $showDiagnostics) {
            if #available(iOS 16.0, *) {
                ChatDiagnosticsView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            } else {
                ChatDiagnosticsView()
            }
        }
        // v6.1.5-14bm：/tools → 工具中心（三层工具总览，给用户看）
        .sheet(isPresented: $showToolCenter) {
            ToolCenterView()
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickToolsPresented }, set: { AppUIState.shared.quickToolsPresented = $0 })) {
            ToolCenterView()   // v6.1.5-14bo：快捷"工具"入口统一到工具中心（原 ToolsView 分类浏览与工具中心重复）
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickSkillsPresented }, set: { AppUIState.shared.quickSkillsPresented = $0 })) {
            AgentsAndSkillsView()
        }
        .sheet(isPresented: Binding(get: { AppUIState.shared.quickFilesPresented }, set: { AppUIState.shared.quickFilesPresented = $0 })) {
            WorkspaceBrowserView()
        }
        // v2.9.10：网络恢复 / 回前台提示（配合后台自动重连）
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.networkRestored)) { _ in
            showToast(L10n.t("i18n_1034"))
            // 网络刚恢复：灯必须立刻重判，不能等下个 25 秒周期
            conn.refreshNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppLifecycleMonitor.willEnterForeground)) { _ in
            if AppLifecycleMonitor.shared.isNetworkAvailable {
                showToast(L10n.t("i18n_1035"))
            }
            conn.refreshNow()
        }
        .onAppear {
            // 只在聊天页可见时跑周期探活，离开就停——省电、也省一次往返
            conn.startAutoProbe()
        }
        .onDisappear {
            conn.stopAutoProbe()
        }
    }

    /// 顶栏状态灯的灯色。
    /// 绿=真的连通；红=连不上；灰=还没探过 / 没配模型。
    private var connTint: Color {
        switch conn.state {
        case .online:  return .green
        case .offline: return .red
        case .unknown: return .secondary
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "message.badge")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(L10n.t("home_empty_title"))
                .font(.headline)
            Text(L10n.t("home_empty_sub"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var homeState: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 30)
                // v6.0.28：首页直接显示App图标，去掉外面的蓝色圆环，避免两层蓝色叠在一起
                ZStack {
                    Group {
                        if let appIcon = UIImage(named: "AppIcon60x60@3x") ?? UIImage(named: "AppIcon1024x1024") {
                            Image(uiImage: appIcon)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 140, height: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                                .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 8)
                        } else {
                            Image(systemName: "cpu")
                                .font(.system(size: 56))
                                .foregroundColor(.white)
                                .frame(width: 140, height: 140)
                                .background(
                                    LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                )
                                .cornerRadius(26)
                        }
                    }
                }

                VStack(spacing: 8) {
                    Text(L10n.t("home_greeting"))
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(L10n.t("home_subtitle"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 28)
                }

                // 两大主卡
                VStack(spacing: 12) {
                    QuickActionCard(
                        icon: "square.grid.2x2",
                        title: L10n.t("home_analyze_apps"),
                        subtitle: L10n.t("home_analyze_apps_sub"),
                        colors: [.tmCyan, .blue]
                    ) {
                        runQuickPrompt(L10n.t("i18n_1243"))
                    }
                    QuickActionCard(
                        icon: "memorychip",
                        title: L10n.t("home_check_device"),
                        subtitle: L10n.t("home_check_device_sub"),
                        colors: [.green, .tmTeal]
                    ) {
                        runQuickPrompt(L10n.t("i18n_1244"))
                    }
                }
                .padding(.horizontal, 20)

                // v2.9.78：快速开始引导区（能力卡片，点击即发示例指令）
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.tmCyan)
                        Text(L10n.t("home_quick_title"))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    Text(L10n.t("home_quick_sub"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 22)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    miniCard("hammer.fill", L10n.t("home_quick_compile"), L10n.t("home_quick_compile_sub"), [.orange, .tmBrown], promptId: "developer") {
                        runQuickPrompt(L10n.t("i18n_1233"))
                    }
                    miniCard("syringe.fill", L10n.t("home_quick_inject"), L10n.t("home_quick_inject_sub"), [.green, .tmTeal], promptId: "reverse") {
                        runQuickPrompt(L10n.t("i18n_1234"))
                    }
                    miniCard("memorychip.fill", L10n.t("home_quick_memory"), L10n.t("home_quick_memory_sub"), [.purple, .tmIndigo], promptId: "gamehacker") {
                        runQuickPrompt(L10n.t("i18n_1235"))
                    }
                    miniCard("cursorarrow.click.2", L10n.t("home_quick_ui"), L10n.t("home_quick_ui_sub"), [.tmCyan, .blue], promptId: "uicontrol") {
                        runQuickPrompt(L10n.t("i18n_1236"))
                    }
                    miniCard("stethoscope", L10n.t("home_quick_env"), L10n.t("home_quick_env_sub"), [.tmCyan, .teal], promptId: "qa") {
                        runQuickPrompt(L10n.t("i18n_1237"))
                    }
                    miniCard("antenna.radiowaves.left.and.right", L10n.t("home_quick_capture"), L10n.t("home_quick_capture_sub"), [.orange, .red], promptId: "pentester") {
                        runQuickPrompt(L10n.t("i18n_1238"))
                    }
                    miniCard("trash.circle.fill", L10n.t("home_quick_clean"), L10n.t("home_quick_clean_sub"), [.purple, .blue], promptId: "privacy") {
                        runQuickPrompt(L10n.t("i18n_1239"))
                    }
                    miniCard("globe", L10n.t("home_quick_browser"), L10n.t("home_quick_browser_sub"), [.red, .orange], promptId: "default") {
                        runQuickPrompt(L10n.t("i18n_1240"))
                    }
                    miniCard("bolt.fill", L10n.t("home_quick_automation"), L10n.t("home_quick_automation_sub"), [.blue, .purple], promptId: "default") {
                        runQuickPrompt(L10n.t("i18n_1241"))
                    }
                    miniCard("wrench.and.screwdriver.fill", L10n.t("home_quick_dev"), L10n.t("home_quick_dev_sub"), [.green, .blue], promptId: "developer") {
                        runQuickPrompt(L10n.t("i18n_1242"))
                    }
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 24)
            }
            .padding(.top, 16)
        }
    }

    /// v2.9.78：首页能力小卡片（两列网格）
    /// v3.1.1: 点卡片时自动切换到对应的系统指令模式
    private func miniCard(_ icon: String, _ title: String, _ subtitle: String, _ colors: [Color], promptId: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            // 自动切换到对应的系统指令模式
            if let pid = promptId {
                SystemPrompts.shared.select(pid)
            }
            action()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.headline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(colors[0].opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func runQuickPrompt(_ text: String) {
        guard let cfg = modelStore.defaultConfig else { return }
        if store.selectedId == nil { store.newConversation() }
        inputText = ""
        store.send(text, using: cfg, reasoningLevel: thinkEnabled ? reasoning : 5, smartSearch: smartSearch)
    }

    /// 2026-11-03 **编译修复**（CI 实测报错）：
    ///
    ///   ChatView.swift:673:41: error: the compiler is unable to type-check
    ///   this expression in reasonable time
    ///
    /// 原因：MessageBubble 有 11 个参数，其中 5 个是闭包、3 个是 @State 相关的
    /// 表达式（isStreaming/forceType 都是 `store.xxx == msg.id` 的比较）。
    /// 这样的构造直接内联在 `ForEach { switch { case .msg } }` 两层泛型嵌套里时，
    /// Swift 的类型推断器要枚举的组合数爆炸，直接在 60 秒上限处放弃。
    ///
    /// 修法：把这个构造提成独立方法并显式给出返回类型。
    /// 类型锚点一给出，推断器就不用再猜整棵树，很快就能过。
    /// 这是 Apple 官方推荐的解法（"try breaking up the expression"）。
    ///
    /// 2026-11-05 **编译修复（fix-equatable-1）**：返回类型从 `some View` 改成 `MessageBubble`。
    ///
    /// 上一轮在调用处加了 `.equatable()`，但 `some View` 是不透明的，编译器只知道
    /// 「某个 View」而不知道它就是 `MessageBubble`（也就不知道它 conform Equatable），于是：
    ///   error: referencing instance method 'equatable()' on 'View'
    ///          requires that 'some View' conform to 'Equatable'
    /// 而且这个错误会顺带把外层 `ForEach(ChatListGrouping.group(...), id: \.id)` 的
    /// 类型推断一起拖崩（报成 "cannot convert [ChatListGrouping.Item] to Binding<C>"，
    /// 极具误导性 —— 数组本身完全没问题）。
    ///
    /// 写具体类型既修了报错，也让 `.equatable()` 真正开始工作。
    /// 注意：函数体里**只能有一条**返回 `MessageBubble` 的表达式，不能带 `if`/`switch`
    /// 分支（那就必须用 @ViewBuilder + some View，也就不可能拿到具体类型）。
    /// 当前实现满足这个前提。
    /// 2026-11-05 **编译修复二（fix-equatable-2）**：
    /// 去掉 @ViewBuilder 后，函数体前面有一堆 `let` 语句，编译器就不再把它当
    /// 「单表达式隐式返回」了，必须显式写 `return`。否则：
    ///   error: missing return in instance method expected to return 'MessageBubble'
    private func bubble(for msg: ChatMessage) -> MessageBubble {
        // 注意：isScrollingFast 在 scroll.activity 上，**不在 scroll 上**。
        // 这是刻意拆分（见 ChatScrollState.swift）：它跟 offset/contentHeight 放一起的话，
        // body 一订阅就会连每帧的 offset 更新一起收，等于把修好的滚动性能问题退回去。
        //
        // 内层 activity 的变更由 ChatScrollState.init 里的 sink 转发到外层 objectWillChange，
        // 所以这里直接读是能触发刷新的（之前漏了这段转发，导致 fastScrolling 恒为 false，
        // 「滚动降级为轻量 Text」的优化从未生效 —— 这是滑动卡死的真正原因）。
        let fast = scroll.activity.isScrollingFast
        let sel = selectionMode
        let picked = selectedIds.contains(msg.id)
        let streaming = store.streamingMessageId == msg.id
        let produced = store.liveProducedID == msg.id
        return MessageBubble(
            message: msg,
            fastScrolling: fast,
            selectionMode: sel,
            isSelected: picked,
            onToggleSelect: { toggleSelect(msg.id) },
            onCopy: { copyMessage(msg) },
            onShare: { shareMessage(msg) },
            onWithdraw: { withdraw(msg) },
            onOpenSubAgent: { tid, fallback in
                subAgentDetailTaskID = tid
                subAgentDetailFallback = fallback
            },
            isStreaming: streaming,
            forceType: produced,
            thinkEnabled: thinkEnabled
        )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    // v7.4.1-fix73h：滚动检测改为 UIKit KVO 桥接（替代原 preference marker）。
                    // 原实现（preference + frame(in: .named("chatScroll"))）在 iOS 16.0-16.3 的
                    // ScrollView 下滚动时不重新提交 → chatScrollOffset 恒 0 → ↑ 永不显示、⬇️ 永不隐藏
                    // （fix73f-7 / fix73g 连续修复无效的实测根因）。作为内容首个子视图（高 0 不撑内容），
                    // superview 链直达底层 UIScrollView，KVO 精确上报 contentOffset/contentSize/bounds。
                    // offset 已按原 marker 语义转换（顶部=0，向下为负），下方显示矩阵判断无需改动。
                    ScrollGeometryBridge(
                        onOffset: { v in
                            // 2026-11-05：改走 setOffset —— 内部同时刷新按钮显隐位。
                            // offset 本身是普通属性，写它不再产生任何 SwiftUI 通知；
                            // 只有 canScrollUp/Down 真翻转时才发一次。
                            //
                            // 2026-11-05 fix-freeze-2：setOffset 里**不再**调 noteScrolled。
                            // 那一行会把「程序性贴底」误判成「用户在滚动」→ 全部气泡换控件
                            // → 行高全变 → 又触发贴底 → 死循环。降级改由下面的 onUserScroll 触发。
                            scroll.setOffset(v)
                        },
                        onContentHeight: { scroll.setContentHeight($0) },
                        onViewportHeight: { scroll.setViewportHeight($0) },
                        // **仅用户手指拖拽/惯性滚动**才走这里（桥接层用
                        // UIScrollView.isTracking/isDragging/isDecelerating 判定）。
                        // 这是「滚动期间正文降级为轻量 Text」优化的唯一入口。
                        onUserScroll: { scroll.noteUserScrolled() }
                    )
                    .frame(height: 0)
                    LazyVStack(spacing: 12) {
                        // v7.2.3-fix20：连续工具折叠——相邻已完成工具消息聚合成组，
                        // 组默认一行"运行了 N 个工具"，展开显示各工具卡
                        ForEach(ChatListGrouping.group(store.currentMessages), id: \.id) { item in
                            switch item {
                            case .msg(let msg):
                                bubble(for: msg)
                                // 2026-11-05：配合 MessageBubble: Equatable ——
                                // 参数没变的行直接跳过整棵子树重算（见 MessageBubble 上方的说明）。
                                // 没有 .equatable() 的话，== 实现了也不会被调用。
                                .equatable()
                                .id(msg.id)
                            case .tools(let msgs):
                                // 2026-11-03 修「怎么滑都回不到最底部 / 上滑到底内容还在动」：
                                // 这个分支以前没有 .id()。scrollToBottom 用 last.id 定位，
                                // 最后一条若刚好落在折叠组里就找不到锚点 → 表现为滑不到底；
                                // 缺 id 时 LazyVStack 复用还会把整组子视图当新内容重建
                                // → 滚动过程中持续重排 = 视觉上内容在跳。
                                toolsRunGroup(msgs)
                                    .id(ChatListGrouping.Item.tools(msgs).id)
                            }
                        }
                        // 2026-11-05 **关键修复（fix-freeze-1）**：把「思考中」面板抽成独立子视图。
                        //
                        // 原来这段直接内联在 ChatView.body 里，读的是 store.liveTrail /
                        // store.statusText / store.requestRound —— 这三个都是 @Published，
                        // AI 干活时每执行一步就写一次（工具开始/结束/换轮次）。
                        //
                        // 后果（用户实测：「发完我说的话就卡死了，屏幕点什么都没反应」）：
                        // 每写一次 → ChatView.body 全量重算 → LazyVStack 里**所有**
                        // MessageBubble 重新求值 → 每条消息的 ContentBlocks.split、
                        // MarkdownBlocks.parse、coloredBody 正则全部重跑。
                        // 用户那条指令粘了几千字（截图里可见），单次 parse 就要几毫秒，
                        // 几十条消息叠加 = 主线程被占满 = 点哪都没反应。
                        //
                        // 抽成 ThinkingPanel 后，这些 @Published 只在**它自己**内部读，
                        // 刷新范围收缩到这一小块，消息列表不再被牵连。
                        if store.isLoading {
                            ThinkingPanel()
                        }
                        // 2026-11-05：本轮结束标记（用户要求「需要加结束话语」）。
                        // 判据只有一条：isLoading 真的变回 false。所以不会提前冒出来
                        // 骗人说跑完了——模型还在跑下一轮时这里什么都没有。
                        if turnEnded, !store.isLoading, let secs = lastTurnSeconds {
                            TurnEndedNote(seconds: secs)
                        }
                    }
                    // v3.4.0：去掉整行水平 padding —— AI 气泡改为真正占满左右屏边缘；
                    // 用户气泡的右留白由 MessageBubble 内部按 isUser 处理
                    .padding(.vertical, 12)
                }
                // 点击聊天区空白处收起键盘（v2.9.9）
                .simultaneousGesture(
                    TapGesture().onEnded { dismissKeyboard() }
                )
                // v7.4.1-fix73h：内容总高/视口高/滚动偏移全部由 ScrollGeometryBridge 的 KVO 上报
                // （不再依赖 preference 的 onPreferenceChange——其到达顺序与更新时机在 iOS 16 不可靠）
                // v7.4.0-fix73d：悬浮滚动按钮（对齐 Minis 显示矩阵：顶部只显 down、中间 up+down、底部全隐）
                floatingButtons(proxy)
                // 2026-11-02：右侧消息导航条——点竖条弹出「我说过的话」列表，点条目跳回当时对话
                // 外层给满屏 frame 只为把竖条定位到右侧垂直居中；命中区域只由竖条自身
                // 的 contentShape 决定，不会吃掉聊天区滑动/点击。
                MessageNavigator(
                    messages: store.currentMessages,
                    onJump: { id in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .allowsHitTesting(true)
            }
            .onChange(of: store.currentMessages.count) { _ in
                // 2026-11-05 **重写（fix-jitter-3）**——这里是「AI 回复一直上下跳动」的直接来源。
                //
                // 老逻辑：count 变了 → 判一下在不在底部 → 在的话
                //         withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                //
                // 为什么必然抖：
                //   1) LazyVStack 的内容高度是**估算**的。scrollTo 内部先按当前估算算目标，
                //      滚过去之后又新渲染出几个 cell，contentSize 突变几十上百 pt，
                //      于是「刚滚到底」立刻又不在底了；
                //   2) withAnimation 给这个过程套了一层 spring 插值，每来一条新消息就重新起跳一次；
                //   3) AI 干活时工具卡一条接一条追加，count 一秒能变好几次 → 一秒起跳好几次。
                //   三者叠加 = 用户看到的「消息一直在那上下跳，下面说什么都看不到」。
                //
                // 新做法：**这里不再做任何滚动**。跟随底部交给 ScrollGeometryBridge 在 UIKit 层
                // 用 setContentOffset(animated:false) 一次钉到位（见该文件 pinToBottom 注释：
                // 无插值、无估算误差、不与手势打架）。这里只负责一件事：用户**刚刚自己发了消息**
                // 时，强制把吸附状态重置为「跟随底部」——发完消息必须看到自己的话。
                //
                // 判断「刚发的」用最后一条是不是 user：AI 的流式追加永远是 assistant/tool，
                // 只有用户自己发消息才会让最后一条变成 user。
                if let last = store.currentMessages.last, last.role == "user", !last.isTool {
                    scroll.requestStickToBottom()
                    // 2026-11-05 fix-blank-2 **关键改动**：这里**不再**调 proxy.scrollTo。
                    //
                    // 用户现象：「我回复出去以后，界面内容全被顶没了，出现空白，
                    //           下滑第二次才出来之前的聊天内容」。
                    //
                    // 病根就是这一行 scrollTo(last.id, anchor: .bottom)：
                    //   1) 新气泡刚进 LazyVStack，cell 还没建，SwiftUI 只能按**估算高度**
                    //      算目标位置，而 LazyVStack 对未渲染内容一律往大了估
                    //      → 目标 offset 越过真实 contentSize 底部；
                    //   2) setContentOffset 到内容之外不会报错也不会自动夹回，
                    //      视口就停在一片空白上；
                    //   3) 紧接着 offset 观察者跑起来，看到「不在底部」→ 把 stickToBottom
                    //      判成 false（以为用户主动上滑看历史）→ 自动跟随被关掉，
                    //      空白就永久留在那儿，只有手指下滑才回到内容里。
                    //
                    // 现在只发吸附请求，由桥接层按**真实 contentSize** 分步贴底；
                    // 万一还是越界（内容先鼓后缩），桥接层的 isOverscrolled 会夹回底部。
                    // 连排两次：第一次让状态立刻置位，第二次等新气泡真正进布局后再落位。
                    DispatchQueue.main.async {
                        scroll.requestStickToBottom()
                    }
                }
            }
            // v2.9.12：打开/切换会话时自动滚到底（老会话不再停在顶部）
            // 2026-11-05 fix-blank：吸附请求与分步落位都收进 scrollToBottom 了，
            // 这里不再重复 requestStickToBottom（重复发只会多排一次分步贴合，白做功）。
            .onAppear {
                scrollToBottom(proxy)
            }
            .onChange(of: store.selectedId) { _ in
                // 2026-11-05：换会话就清掉上一轮的「本轮结束」标记——否则切到别的会话
                // 底部还挂着上一条会话的结束语，看着像这轮已经跑完了。
                turnEnded = false
                lastTurnSeconds = nil
                scrollToBottom(proxy)
            }
            // v2.9.72：AI 回复完成时结束工作流
            .onChange(of: store.isLoading) { loading in
                if !loading {
                    WorkflowManager.shared.finishRun(success: true)
                    // 2026-11-05：本轮真的结束了——记下用时，列表末尾落一行「✓ 本轮结束」。
                    // 只有走到这里才算结束（工具循环中途 isLoading 一直是 true，不会误触发）。
                    if let start = turnStartedAt {
                        lastTurnSeconds = Date().timeIntervalSince(start)
                        turnEnded = true
                    }
                    turnStartedAt = nil
                } else {
                    // 新的一轮开始（用户发送 / 网络恢复自动重试）
                    if turnStartedAt == nil { turnStartedAt = Date() }
                    turnEnded = false
                }
                // v7.1.109-peers：请求完成 → 刷新上下文环形指示器（records 读文件，仅此刻读一次）
                if !loading { refreshRingTok() }
            }
            .onAppear { refreshRingTok() }
            // v2.9.235：键盘高度变化→自动滚到底（高度本身由外层 VStack 监听，空会话也能避让键盘）
            .onChange(of: keyboardHeight) { _ in
                if keyboardHeight > 0 {
                    // 2026-11-05 fix-blank-2：这里原来也是 proxy.scrollTo(last.id, anchor: .bottom)。
                    // 键盘弹出时视口刚变矮、contentSize 还没稳定，scrollTo 的估算落位同样会
                    // 冲到内容之外 → 整屏空白。改走吸附请求（桥接层用真实 contentSize + 越界夹回）。
                    // 延迟 0.3s 保留：等键盘弹出动画（0.25s）结束、视口高度定下来再贴底。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        scroll.requestStickToBottom()
                    }
                }
            }
        }
    }

    // v7.4.0-fix73d：悬浮按钮（独立函数——减主表达式 type-check 负担）
    // v7.1.281-fix：箭头 ↑↓ 改 ︿﹀（chevron 风格，用户指定）
    // 2026-11-03：改为独立订阅 ChatScrollState 的子视图——ChatView.body 本身不读滚动状态，
    // 这样滚动每帧只重算这一个 40pt 圆钮，不再牵动整个聊天列表。
    private func floatingButtons(_ proxy: ScrollViewProxy) -> some View {
        FloatingScrollButtons(
            scroll: scroll,
            onUp: {
                // 2026-11-05：去掉 withAnimation —— 用户点「回到顶部」时希望在 0.1 秒内
                // 到位，而不是看一段 0.35 秒的 spring 动画；且动画期间桥接层如果判定
                // 「还在底部附近」会反向吸附，两者互扯就是「点了没反应/回弹」。
                // 先解除吸附（用户明确要离开底部），再定位。
                scroll.releaseStick()
                if let first = store.currentMessages.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            },
            onDown: {
                scroll.requestStickToBottom()
                scrollToBottom(proxy)
            }
        )
    }

    // 2026-11-03：原来的 chatCanScrollUp / chatCanScrollDown / chatFloatingButton 三个成员
    // 已整体迁入 FloatingScrollButtons（见下方 struct）——它们是唯一需要订阅滚动状态的视图，
    // 留在 ChatView 里会让 body 每帧重算。

    /// v2.9.12：滚到当前会话最新一条
    ///
    /// 2026-11-05 fix-blank **重写**——修「打开会话偶尔整屏空白，往上滑几下才出内容」。
    ///
    /// 老实现是一次（加一次 0.08s 兜底）`proxy.scrollTo(last.id, anchor: .bottom)`。
    /// 这个调用有两个问题，正好凑成空白：
    ///   1) `LazyVStack` 里 `last.id` 对应的 cell 在 `onAppear` 那一刻**还没被创建**
    ///      （懒栈只建可见范围附近的），`scrollTo` 一个不存在的锚点会静默失败；
    ///   2) 即使找到了，它也是「按当前估算高度一步跳到底」——和桥接层一次性
    ///      setContentOffset 是同一个毛病：跳过去那帧可见范围还没重算，视口落在
    ///      未渲染区域 = 整屏空白，手指一动才补出来。
    ///
    /// 现在只做两件事，顺序很关键：
    ///   · 先用 `scrollTo` 把「最后一条」拉进渲染范围 —— 目的是**逼 LazyVStack 立刻
    ///     创建末尾的 cell**，而不是精确落位（锚点用 .bottom，让末尾尽量靠下，
    ///     与「停在最新消息处」一致，避免先跳到别处再回来）；
    ///   · 再通知桥接层恢复吸附，由它分步靠近真正底部，每步给 SwiftUI 一帧去建 cell。
    ///
    /// 为什么必须有第一步：只靠 setContentOffset 时 SwiftUI 是按可见范围被动建 cell 的，
    /// 第一步一旦落到空白区就可能一直不建；scrollTo 是唯一能主动"告诉" LazyVStack
    /// 「现在需要这几条」的手段。
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = store.currentMessages.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
        // 落位交给桥接层分步完成（无动画、不与手势打架、不会落到未渲染区）。
        scroll.requestStickToBottom()
        // 兜底：内容多时第一次 scrollTo 可能因锚点尚未创建而落空，下一帧再要一次。
        // 注意这里**不能写 [weak self]**：ChatView 是 struct（值类型），
        // 'weak' 只能用于类/类约束协议 —— 编译期直接报错。
        // 也不需要：闭包按值捕获这个 struct（含 @ObservedObject 包装器与 ScrollViewProxy），
        // 一次性执行完即释放，不会形成引用环。
        DispatchQueue.main.async {
            guard let last = store.currentMessages.last else { return }
            proxy.scrollTo(last.id, anchor: .bottom)
            scroll.requestStickToBottom()
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// v3.4.3：模型名已移入导航栏 principal（与标题、右侧图标同一平行线），此处不再占用正文顶部
    private var chatModeBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // v3.4.5：六个胶囊统一同宽同高（76×32），比例完全一致、长度略长
                // v3.4.7：推理用"大脑"图标、思考用"灯泡"图标（用户指定，勿对调）
                ChatChip(label: L10n.t("i18n_1037", reasoningLabel()), action: {
                    reasoning = (reasoning + 1) % 5
                }, accent: true, icon: "brain").frame(height: 36)
                ChatChip(label: L10n.t("i18n_1086", thinkEnabled ? L10n.t("i18n_1088") : L10n.t("i18n_1089")), action: {
                    thinkEnabled.toggle()
                }, accent: thinkEnabled, icon: "lightbulb").frame(height: 36)
                ChatChip(label: L10n.t("i18n_1087", smartSearch ? L10n.t("i18n_1088") : L10n.t("i18n_1089")), action: {
                    smartSearch.toggle()
                }, accent: smartSearch, icon: "magnifyingglass").frame(height: 36)
                QuickTabButton(icon: "bolt", label: L10n.t("i18n_1038")) {
                    AppUIState.shared.quickSkillsPresented = true
                }.frame(height: 36)
                QuickTabButton(icon: "doc.text", label: L10n.t("i18n_1039")) {
                    // v4.4.16：点"指令"→ 打开设置并真正跳到系统指令页(此前只打开设置,未定位到 SystemPromptsView, 用户实测'没真正跳到')
                    AppUIState.shared.settingsJumpToModels = false
                    AppUIState.shared.settingsJumpToSystemPrompts = true
                    AppUIState.shared.settingsPresented = true
                }.frame(height: 36)
                QuickTabButton(icon: "folder", label: L10n.t("i18n_1040")) {
                    AppUIState.shared.quickFilesPresented = true
                }.frame(height: 36)
                // v7.1.109-peers：上下文指示（Minis 式文字 + Cursor 式圆环）——行尾，不占胶囊位
                contextText
                    .padding(.leading, 4)
                contextRing
                    .padding(.leading, 2)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            // v2.9.10：待发送附件预览（图片缩略图 / 应用图标 / 文件）
            AttachmentPreviewStrip(attachments: pendingAttachments) { att in
                withAnimation { pendingAttachments.removeAll { $0.id == att.id } }
            }
            // v3.4.5：功能行（推理/思考/搜索/系统指令/技能/工作区）——胶囊与输入框、与上方都留
            // 等距 16pt 间隙（上下对称，间距比之前加大）
            // v7.1.109-peers：环形指示器并入行尾（用户去掉了输出模式胶囊条，保留 token 占用环）
            chatModeBar
                // v4.4.11：左边距 12→16（用户反馈推理贴左无空格）
                .padding(.horizontal, 16)
                // v3.4.7：顶部间距减半(16→8)，用户反馈上方空太多；底部 16 保留(胶囊到输入框的加大间距)
                .padding(.top, 8)
                .padding(.bottom, 16)

            // v3.0.83：输入栏 —— 语音 + 输入框 + +号 + 发送键 统一放进同一个大圆角框
            // 2026-11-02 按用户要求：原「终端」按钮位置改为「语音输入」（终端已移到顶栏）
            HStack(spacing: 6) {
                Button(action: {
                    // 语音输入：点一下开始听，再点一下结束并填入输入框
                    if voice.isListening {
                        voice.stop()
                    } else {
                        // GirlVoice 是单例，GirlCompanion 也用它——每次开录前重新挂回调，
                        // 确保识别结果进的是当前输入框（而不是被小女孩页面的回调抢走）。
                        voice.onFinalText = { text in
                            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !t.isEmpty else { return }
                            if inputText.isEmpty { inputText = t }
                            else { inputText += (inputText.hasSuffix(" ") ? "" : " ") + t }
                        }
                        voice.onPermissionDenied = { showToast("语音权限未开启，请到设置中允许麦克风与语音识别") }
                        voice.start()
                    }
                }) {
                    Image(systemName: voice.isListening ? "waveform" : "mic.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(voice.isListening ? .red : .secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                // 2026-11-02：录音中图标呼吸提示（只作用于这个按钮，不进全局动画）
                .opacity(voice.isListening ? (micPulse ? 0.45 : 1.0) : 1.0)
                .onChange(of: voice.isListening) { listening in
                    micPulse = false
                    guard listening else { return }
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        micPulse = true
                    }
                }

                ChatInputTextView(text: $inputText, onSend: { send() }, height: $inputHeight)
                    .frame(maxWidth: .infinity)
                    .frame(height: inputHeight)

                // v3.3.4：+ 号 → 展开"应用/相册/文件/浏览器"快捷行；再点变 x 收起
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        attachExpanded.toggle()
                    }
                }) {
                    Image(systemName: attachExpanded ? "xmark" : "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(attachExpanded ? Color.gray : Color.blue)
                        .clipShape(Circle())
                }
                // v2.9.35：+号 → 半屏"添加内容"面板（对齐老 MCP 设计），不再用 actionSheet
                // （iOS16 actionSheet 偶发点击无响应 + 无"已选 N"徽标）
                // v2.9.36：移除麦克风按钮（语音无实际作用）

                // v2.9.13：请求中时按钮变为"停止"，点击取消当前请求 (v4.5.8：仅当前选中会话在请求时显示，
                // 切到别的会话不误显示停止）
                if store.selectedIsRequesting {
                    Button(action: { store.cancelCurrent() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.red)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: send) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(inputText.isEmpty ? Color.gray : Color.blue)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    // v7.4.0-fix71：会话异步加载完成前禁用发送（防 conversations 为空时丢消息）
                    .disabled(inputText.isEmpty || store.isLoadingData)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            // v3.3.4：整行放进一个大圆角框（终端键/输入框/+号/发送键 一体）
            .background(Color(.secondarySystemBackground))
            .cornerRadius(20)
            // v3.4.5：输入框外阴影渐变，往外扩散越来越淡（多层 shadow 叠加模拟渐变发光）
            // v3.4.7：改为灰色扩散、且收敛——用户反馈蓝色扩散太多，应偏灰
            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
            .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 4)
            .padding(.horizontal, 12)
            // v6.1.5-14bl：/命令 与 @提及 快捷菜单（输入框上方弹出）
            .overlay(alignment: .bottom) {
                if inputText.hasPrefix("/") {
                    commandQuickMenu
                } else if inputText.hasPrefix("@") {
                    appMentionQuickMenu
                }
            }

            // v3.4.2：点 + 底部弹出 应用/相册/文件/浏览器，把聊天框顶起来（位于输入框下方）
            if attachExpanded {
                attachQuickRow
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 8)
        .background(Color(.systemBackground))
        // v2.9.30：授权弹窗已移出到 NavigationView 外层（见 body 链），
        // 此处不再挂 actionSheet，避免与上方 +号 的 actionSheet 同 view 覆盖。
    }

    private func reasoningLabel() -> String {
        // v4.3.40：档位扩为 低/中/高/最高/极限——最高档=xhigh, 极限档=max (破甲站 gpt-6.1-sol 实测支持 low/medium/high/xhigh/max)
        let labels = [L10n.t("i18n_1041"), L10n.t("i18n_1042"), L10n.t("i18n_1043"), L10n.t("i18n_1044"), L10n.t("i18n_1045")]
        return reasoning >= 0 && reasoning < labels.count ? labels[reasoning] : L10n.t("i18n_1043")
    }

    // v7.1.109-peers：上下文环形指示器（Cursor 式）+ 文字指示（Minis 式"5%·53.7k/1000k"）——
    // 最近请求真实/估算 token 占当前模型实际上下文窗口比例
    // 数据缓存于 @State（audit：records 每次读全文件，不能在 body 渲染里高频读）
    @State private var ringTok = 0
    private func refreshRingTok() {
        let rec = UsageRecorder.shared.records.last
        let total = rec?["totalTokens"] as? Int ?? 0
        let est = rec?["estInputTokens"] as? Int ?? 0
        ringTok = total > 0 ? total : est
    }
    // v7.1.109-peers：上下文指示总量——与压缩预算同源（effectiveContextTokens：收录模型=真实窗口，
    // 未收录=用户配置 contextTokens），避免"UI 显示 200k、实际预算 16k"的显示/行为矛盾
    private var currentContextWindow: Int {
        modelStore.defaultConfig?.effectiveContextTokens ?? 200_000
    }
    private func fmtTok(_ t: Int) -> String {
        if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
        if t >= 1000 { return String(format: "%.1fk", Double(t) / 1000) }
        return "\(t)"
    }
    // v7.1.109-peers：Minis 式上下文文字——"5%·53.7k/1000k"（百分比·当前/总量）
    private var contextText: some View {
        let tok = ringTok
        let window = currentContextWindow
        let pct = window > 0 ? min(100, Int(Double(tok) / Double(window) * 100)) : 0
        return Text("\(pct)%·\(fmtTok(tok))/\(fmtTok(window))")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.secondary)
            .accessibilityLabel(L10n.t("i18n_1254"))
    }
    private var contextRing: some View {
        let tok = ringTok
        let window = currentContextWindow
        let ratio: CGFloat = tok > 0 ? min(1.0, CGFloat(tok) / CGFloat(window)) : 0
        return ZStack {
            Circle()
                .stroke(Color(.systemGray4), lineWidth: 2)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(tokText(tok))
                .font(.system(size: 7, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .frame(width: 24, height: 24)
        .accessibilityLabel(L10n.t("i18n_1254"))
    }

    private func tokText(_ t: Int) -> String {
        if t >= 1000 { return String(format: "%.0fk", Double(t) / 1000) }
        return "\(t)"
    }

    /// v3.3.4：+ 展开的快捷附件行（应用 / 相册 / 文件 / 浏览器），对齐微信式附件栏
    /// v3.4.2：从左屏幕边缘到右屏幕边缘均匀分布——四格等宽、间隙一致（含两侧边缘间隙）
    private var attachQuickRow: some View {
        // 2026-11-02（用户要求「展示成一排」）：改成单行横向均分——6 个入口排一排不折行。
        // 用 GeometryReader 按屏幕宽度算每格宽度，格子间距固定 8，两侧各留 12 边距，
        // 这样 6 个图标在任意机型上都是等宽等距、整体居中，不会因为 flex 分配出现左右不匀。
        GeometryReader { geo in
            let count: CGFloat = 6
            let sideInset: CGFloat = 12
            let gap: CGFloat = 8
            // 可用宽度扣掉两侧边距与 5 个间隙，再均分给 6 格
            let tile = max(40, (geo.size.width - sideInset * 2 - gap * (count - 1)) / count)
            HStack(spacing: gap) {
            attachQuickButton("apps.iphone", L10n.t("i18n_1046"), tileWidth: tile) {
                withAnimation { attachExpanded = false }
                attachmentSheet = .appPicker
            }
            attachQuickButton("photo.on.rectangle", L10n.t("i18n_1047"), tileWidth: tile) {
                withAnimation { attachExpanded = false }
                attachmentSheet = .photoPicker
            }
            attachQuickButton("folder", L10n.t("i18n_1048"), tileWidth: tile) {
                withAnimation { attachExpanded = false }
                // v3.3.4：快捷行直接弹 UIKit 文档选择器（无需半屏面板中转）
                Self.presentDocumentPicker { urls in
                    handlePickedFiles(urls)
                }
            }
            attachQuickButton("globe", L10n.t("i18n_1049"), tileWidth: tile) {
                withAnimation { attachExpanded = false }
                attachmentSheet = nil
                FloatingBrowser.shared.show()
            }
            // 2026-11-02（用户指定顺序）：浏览器之后依次是 中转站 → 路由器。
            // 图标沿用本行原版规格（SF Symbols / 22pt / 蓝色 / 52×52 圆角瓦片），不另配色。
            // 「中转站」：打开中转站后台（首次输一次密码，之后免密直达）
            attachQuickButton("server.rack", L10n.t("i18n_1510"), tileWidth: tile) {
                withAnimation { attachExpanded = false }
                beginRelayAdmin()
            }
            // 「路由器」：弹出中转站重启 / 路由器重启（各带确认框）
            attachQuickButton("wifi.router", L10n.t("i18n_1535"), tileWidth: tile) {
                withAnimation { attachExpanded = false }
                beginRouterControl()
            }
            }
            .frame(width: geo.size.width, alignment: .center)
        }
        .frame(height: 78)
        // v3.4.8：附件行与输入框之间留出明显间隔（参考图）
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    /// v3.4.8：方形圆角瓦片（相机/图片/文件/浏览器 那一套样式）。
    /// 2026-11-02：新增 tileWidth 参数——6 个入口排一排时，格子比原来 4 格窄，
    /// 瓦片尺寸跟着收（图标与圆角按比例缩），保证「一排排得下、彼此间距一样」。
    /// 不传时保持原版 52×52，4 格场景视觉完全不变。
    private func attachQuickButton(_ icon: String, _ label: String,
                                   tileWidth: CGFloat? = nil,
                                   action: @escaping () -> Void) -> some View {
        let w = tileWidth ?? 52
        // 图标随瓦片等比缩：52 → 22pt，44 → 19pt
        let iconSize = max(17, (w / 52) * 22)
        let radius = max(10, (w / 52) * 14)
        return Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundColor(.blue)
                    .frame(width: w, height: w)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: w)
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// v2.9.93：按模型名识别供应商图标
    private func modelIcon(for model: String) -> String {
        let m = model.lowercased()
        if m.contains("deepseek") { return "d.circle.fill" }
        if m.contains("claude") { return "c.circle.fill" }
        if m.contains("gpt") || m.contains("o1") || m.contains("o3") || m.contains("o4") { return "sparkles" }
        if m.contains("glm") || m.contains("qwen") || m.contains("kimi") { return "brain" }
        if m.contains("gemini") { return "sparkle.magnifyingglass" }
        return "cpu"
    }

    private func send() {
        // v7.4.0-fix71：会话异步加载完成前直接拦截（按钮 disabled 之外的双保险）
        guard !store.isLoadingData else { return }
        guard let cfg = modelStore.defaultConfig,
              (!inputText.isEmpty || !pendingAttachments.isEmpty || !pendingImages.isEmpty) else { return }
        // v3.1.5: 自动提取关键信息（App 名、bundle id、文件路径等）
        AutoContextExtractor.shared.extract(from: inputText)
        // v3.1.1: 模型不支持视觉时，自动 OCR 识别图片文字，拼到消息里
        var imagesToSend = pendingImages
        if !pendingImages.isEmpty && !cfg.supportsVision {
            // 自动 OCR：把图片文字识别出来，拼到消息里
            var ocrTexts: [String] = []
            for (i, imgData) in pendingImages.enumerated() {
                if let data = Data(base64Encoded: imgData.replacingOccurrences(of: "data:image/png;base64,", with: "").replacingOccurrences(of: "data:image/jpeg;base64,", with: "")) {
                    let tmpPath = NSTemporaryDirectory() + "ocr_\(i).png"
                    try? data.write(to: URL(fileURLWithPath: tmpPath))
                    if let ocrResult = try? OCRImageTool().invoke(["path": tmpPath]),
                       let text = ocrResult["text"] as? String, !text.isEmpty {
                        ocrTexts.append(L10n.t("i18n_1050", i+1, text))
                    }
                    try? FileManager.default.removeItem(atPath: tmpPath)
                }
            }
            if !ocrTexts.isEmpty {
                inputText = inputText + "\n\n" + ocrTexts.joined(separator: "\n\n")
                imagesToSend = [] // 去掉图片，只发文字
                showToast(L10n.t("i18n_1051"))
            }
        }
        // v2.9.72：启动工作流可视化
        WorkflowManager.shared.startRun(L10n.t("i18n_1052"))
        if store.selectedId == nil { store.newConversation() }
        var text = inputText
        let imgs = pendingImages
        // v2.9.61：输入框不再有 [📱应用] 占位标签，发送时自动把应用/文件附件拼成描述文字
        let appAtts = pendingAttachments.filter { if case .app = $0.kind { return true }; return false }
        let fileAtts = pendingAttachments.filter { if case .file = $0.kind { return true }; return false }
        var attDesc: [String] = []
        for att in appAtts {
            let bid = att.bundleId ?? "unknown"
            attDesc.append(L10n.t("i18n_1053", att.displayName, bid))
        }
        for att in fileAtts {
            // v2.9.291：文件附件自动复制到工作区 uploads/ 并附加路径——
            // 之前只发 [📎文件：xxx] 描述，AI 根本没有文件内容/路径可读，
            // 导致"找不到 .deb"（文件在用户本地文件App里，AI 视野外）
            let saved = Self.saveAttachmentToWorkspace(att)
            if let sp = saved {
                // v3.1.70：去掉"可用 artifact / shell.exec 读取分析"工具残留（用户反馈），
                // 只保留路径——AI 的 fs 工具集本身就能读，无需在消息里提示
                attDesc.append(L10n.t("i18n_1054", att.displayName, sp))
            } else {
                attDesc.append(L10n.t("i18n_1055", att.displayName, Workspace.root.path))
            }
        }
        if !attDesc.isEmpty {
            text = text.isEmpty ? attDesc.joined(separator: " ") : text + " " + attDesc.joined(separator: " ")
        }
        inputText = ""
        pendingImages = []
        // v2.9.10：附件预览与发送联动——从附件里取图片 dataURL（若预览被删则不再发送）
        let attImgs = pendingAttachments.compactMap { $0.dataURL }
        pendingAttachments = []
        let finalImgs = attImgs.isEmpty ? imagesToSend : attImgs
        // v3.4.1：思考总开关接入主发送路径（此前漏传，思考·开/关在输入框无效）
        store.send(text, using: cfg, imageDataURLs: finalImgs, reasoningLevel: thinkEnabled ? reasoning : 3, smartSearch: smartSearch)
        AuditLog.shared.log("chat", detail: L10n.t("i18n_1056"))
    }

    /// v2.9.9：图片文件 → base64 data URL
    /// v2.9.292：降采样到最长边 1200px + JPEG q60 压缩——之前只限 3MB 不压缩，
    /// 单张原图 base64 可达 2-4MB，历史里每张图每次请求全量重发 → 卡住/超时。
    /// 压缩后单张 ~100-250KB，省 token 且不卡。
    static func imageDataURL(for url: URL) -> String? {
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        let maxDim: CGFloat = 1200
        var out = img
        if max(img.size.width, img.size.height) > maxDim {
            let scale = maxDim / max(img.size.width, img.size.height)
            let newSize = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            img.draw(in: CGRect(origin: .zero, size: newSize))
            out = UIGraphicsGetImageFromCurrentImageContext() ?? img
            UIGraphicsEndImageContext()
        }
        guard let data = out.jpegData(compressionQuality: 0.6) else { return nil }
        let limit = 3 * 1024 * 1024
        if data.count > limit { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    /// v2.9.291：把聊天文件附件复制到工作区 uploads/ 目录，返回保存后的绝对路径
    /// - 处理 security-scoped URL（UIDocumentPicker 返回的 URL 需 startAccessing）
    /// - 文件名冲突时追加时间戳，避免覆盖
    static func saveAttachmentToWorkspace(_ att: PendingAttachment) -> String? {
        guard let src = att.fileURL else { return nil }
        var scoped = false
        if src.startAccessingSecurityScopedResource() { scoped = true }
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: src), data.count > 0 else { return nil }
        let uploads = Workspace.root.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        var name = src.lastPathComponent
        if name.isEmpty { name = att.displayName }
        var dest = uploads.appendingPathComponent(name)
        // 重名冲突：追加 -<时间戳>
        if FileManager.default.fileExists(atPath: dest.path) {
            let ts = Int(Date().timeIntervalSince1970)
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            dest = uploads.appendingPathComponent("\(base)-\(ts).\(ext)")
        }
        do {
            try data.write(to: dest)
            return dest.path
        } catch {
            return nil
        }
    }

    /// v2.9.10：读取应用图标（用于输入栏附件预览）
    // v6.0.30: app图标内存缓存，所有用到图标的地方自动秒开
    private static let iconCache = NSCache<NSString, UIImage>()
    static func appIcon(for path: String) -> UIImage? {
        // 先查缓存
        if let cached = iconCache.object(forKey: path as NSString) {
            return cached
        }
        guard let info = Bundle(path: path)?.infoDictionary,
              let icons = info["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let last = files.last else { return nil }
        let p = (path as NSString).appendingPathComponent(last + "@2x.png")
        let img = UIImage(contentsOfFile: p) ?? UIImage(contentsOfFile: (path as NSString).appendingPathComponent(last + ".png"))
        if let img = img {
            iconCache.setObject(img, forKey: path as NSString)
        }
        return img
    }

    // MARK: - v3.1.67：UIKit 文档选择器（真机稳定方案，替代 .fileImporter）

    /// 从顶层 VC present UIDocumentPickerViewController（asCopy: true）。
    /// - 真机 iPhone 上 .fileImporter 有已知 bug（Apple 论坛 775056：选择器打不开/无法交互/回调不触发），
    ///   UIKit 方案在真机完全正常（最早版本能打开文件就是用的 UIKit 方案）。
    /// - asCopy: true 让系统把所选文件复制进 App 沙盒，返回的 URL 直接可读、不会失效，
    ///   无需 startAccessingSecurityScopedResource，也彻底绕开"临时 URL 失效"问题。
    static func presentDocumentPicker(onPick: @escaping ([URL]) -> Void) {
        guard let top = Self.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.modalPresentationStyle = .formSheet
        // coordinator 必须被强引用，否则 delegate 回调不触发
        let coordinator = DocumentPickerCoordinator(onPick: onPick)
        picker.delegate = coordinator
        objc_setAssociatedObject(picker, &DocumentPickerCoordinator.assocKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        top.present(picker, animated: true)
    }

    /// 找到当前最顶层的 UIViewController（绕开 SwiftUI sheet 层级问题，直接往 key window 上 present）
    private static func topViewController() -> UIViewController? {
        var vc: UIViewController?
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        } else if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        }
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }

    /// 2026-11-02：打开中转站后台。
    /// 附件栏收起有 0.2s 动画，立刻 present sheet 会被收尾逻辑顶掉（同「文件」入口踩过的坑），
    /// 所以等动画结束再弹。
    private func beginRelayAdmin() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showRelayAdmin = true
        }
    }

    /// 2026-11-02：打开路由器控制面板（同样的 0.25s 延迟，避开附件栏收起动画）
    private func beginRouterControl() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showRouterControl = true
        }
    }

    /// 选择完成：复制到工作区 uploads/（asCopy 已复制进沙盒，这里再落到 uploads 统一管理 + 防重名）
    private func handlePickedFiles(_ urls: [URL]) {
        for u in urls {
            let att = PendingAttachment(
                kind: .file,
                displayName: u.lastPathComponent,
                dataURL: nil,
                thumbnail: nil,
                bundleId: nil,
                fileURL: u
            )
            if let saved = Self.saveAttachmentToWorkspace(att) {
                self.pendingAttachments.append(PendingAttachment(
                    kind: .file,
                    displayName: u.lastPathComponent,
                    dataURL: nil,
                    thumbnail: nil,
                    bundleId: nil,
                    fileURL: URL(fileURLWithPath: saved)
                ))
            } else {
                self.pendingAttachments.append(att)
            }
        }
    }

    // MARK: - 多选 / 复制 / 分享（v2.9.2）

    private func enterSelection() {
        selectionMode = true
        selectedIds = []
    }

    private func exitSelection() {
        selectionMode = false
        selectedIds = []
    }

    private func toggleSelect(_ id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func copyMessage(_ m: ChatMessage) {
        UIPasteboard.general.string = m.content
        showToast(L10n.t("i18n_1197"))
    }

    /// v7.1.41：手动压缩当前会话（对齐 Claude Code /compact）——AI 摘要替换旧历史并持久化，不发主请求
    private func compactNow() {
        store.compactNow { ok, msg in
            DispatchQueue.main.async {
                self.showToast(msg)
            }
        }
    }

    /// 2026-11-02：撤回自己发的一条消息。
    /// 行为（用户明确要求）：删除该条 + 它之后的所有对话，文字回填输入框；
    /// **绝不自动重新请求模型**——必须等用户下一条指令才回复。
    private func withdraw(_ m: ChatMessage) {
        let text = store.withdrawMessage(id: m.id)
        guard let text else { return }
        // 回填输入框（若输入框已有草稿则拼在后面，不吞掉用户正在写的内容）
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = text
        } else {
            inputText = text + "\n" + inputText
        }
        // 撤回后不再朗读上一轮内容（避免"撤回了还在念"）
        TTSService.shared.stop()
        showToast(L10n.t("i18n_1533"))
    }

    private func shareMessage(_ m: ChatMessage) {
        presentShareSheet(text: m.content)
    }

    private func copySelected() {
        let count = selectedIds.count
        UIPasteboard.general.string = exportText()
        exitSelection()
        showToast(count > 0 ? L10n.t("i18n_1057", count) : L10n.t("i18n_1197"))
    }

    private func shareSelected() {
        presentShareSheet(text: exportText())
    }

    // v4.3.46：文字分享 → 自建分享菜单（拷贝 / 存储到文件），绕开 ShareSheet
    private func presentShareSheet(text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            showToast(L10n.t("i18n_1058"))
            return
        }
        ShareCenter.shared.presentShareMenuText(content)
    }

    /// 把勾选的消息拼成可读文本（按会话内顺序），用于复制 / 分享。
    private func exportText() -> String {
        let msgs = store.currentMessages.filter { selectedIds.contains($0.id) }
        guard !msgs.isEmpty else { return "" }
        var parts: [String] = []
        let title = store.currentTitle
        if !title.isEmpty && title != L10n.t("i18n_1059") {
            parts.append("【\(title)】")
        }
        for m in msgs {
            parts.append(formatted(m))
        }
        return parts.joined(separator: "\n\n")
    }

    private func formatted(_ m: ChatMessage) -> String {
        switch m.role {
        case "user":
            return L10n.t("i18n_1060", m.content)
        case "tool":
            let name = m.toolName.map { "（\($0)）" } ?? ""
            return L10n.t("i18n_1061", name, m.content)
        default:
            return m.content
        }
    }

    private func showToast(_ text: String) {
        toastText = text
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { showToast = false }
        }
    }

    // v6.1.5-14bl：/命令 快捷菜单
    private var commandQuickMenu: some View {
        let items: [(String, String, String)] = [
            ("/clear", "trash", L10n.t("i18n_1062")),
            ("/new", "square.and.pencil", L10n.t("i18n_1063")),
            ("/model", "cpu", L10n.t("i18n_1064")),
            ("/tools", "wrench.and.screwdriver", L10n.t("i18n_1065")),
        ]
        return VStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                Button(action: { runQuickCommand(item.0) }) {
                    HStack(spacing: 10) {
                        Image(systemName: item.1)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 22)
                        Text(item.0)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(item.2)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                if item.0 != items.last!.0 {
                    Divider().padding(.leading, 46)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    // v6.1.5-14bl：@提及 应用快捷菜单（复用 AppCatalog 已装应用列表）
    private var appMentionQuickMenu: some View {
        let apps = AppCatalog.list()
        return VStack(spacing: 0) {
            ForEach(Array(apps.prefix(24).enumerated()), id: \.element.bundleId) { _, app in
                Button(action: { mentionApp(app) }) {
                    HStack(spacing: 10) {
                        if let ic = Self.appIcon(for: app.path) {
                            Image(uiImage: ic)
                                .resizable()
                                .frame(width: 22, height: 22)
                                .cornerRadius(5)
                        } else {
                            Image(systemName: "app.fill")
                                .foregroundColor(.secondary)
                        }
                        Text(app.name)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(app.bundleId)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func runQuickCommand(_ name: String) {
        switch name {
        case "/clear": store.clearCurrent(); showToast(L10n.t("i18n_1066"))
        case "/new": store.newConversation(); showToast(L10n.t("i18n_1067"))
        case "/model": showModelPicker = true
        case "/tools": showToolCenter = true
        default: break
        }
        inputText = ""
    }

    private func mentionApp(_ app: AppCatalog.AppEntry) {
        let icon = Self.appIcon(for: app.path)
        let att = PendingAttachment(kind: .app, displayName: app.name, dataURL: nil, thumbnail: icon, bundleId: app.bundleId, fileURL: nil)
        pendingAttachments.append(att)
        inputText = inputText.replacingOccurrences(of: "@", with: "").trimmingCharacters(in: .whitespaces)
        showToast(L10n.t("i18n_1068", app.name))
    }
    @ViewBuilder
    private func toolsRunGroup(_ msgs: [ChatMessage]) -> some View {
        let gid = "t-" + (msgs.first?.id.uuidString ?? "") + "-" + String(msgs.count)
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if toolsRunExpanded.contains(gid) {
                        toolsRunExpanded.remove(gid)
                    } else {
                        toolsRunExpanded.insert(gid)
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text(String(format: L10n.t("i18n_1260"), msgs.count))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    if let d = ChatListGrouping.Item.tools(msgs).totalDuration {
                        Text(String(format: "%.1fs", d))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: toolsRunExpanded.contains(gid) ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                // v7.2.3-fix39：撑满到与灰色气泡等宽（外层 VStack 加 16 水平 padding，
                // 与 MessageBubble 一致，不贴屏幕两端）；此前 minWidth 200 仍偏短
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray5).opacity(0.6))
                .cornerRadius(14)
            }
            .buttonStyle(.plain)
            if toolsRunExpanded.contains(gid) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(msgs) { msg in
                        // 与主列表共用同一个构造方法：一是避免同样的
                        // "unable to type-check in reasonable time"，
                        // 二是保证两处的回调/样式永远一致（以前是复制粘贴，容易改漏）
                        bubble(for: msg)
                            // 2026-11-05：同主列表，参数没变就跳过重算
                            .equatable()
                            .id(msg.id)
                    }
                }
                .padding(.leading, 6)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color(.systemGray4))
                        .frame(width: 3)
                        .cornerRadius(1.5)
                }
            }
        }
        .padding(.horizontal, 16)   // fix39：与 MessageBubble 外层 16 对齐，胶囊不贴屏幕两端
    }
}

/// 2026-11-03：悬浮滚动按钮——**唯一**订阅 ChatScrollState 的视图。
///
/// 关键点：ChatView.body 本身**不读** scroll 的任何属性，否则滚动每一帧都会让
/// 整个聊天体重新求值（含分组、全部气泡、正文分块），性能修复就白做了。
/// 把订阅面收窄到这一颗 40pt 的圆钮，滚动开销从「整页」降到「两个小圆点」。
/// 2026-11-05：请求进行中的「思考中 / 执行轨迹 / 轮次」面板（独立子视图）。
///
/// 为什么必须独立成 struct（不是因为好看，是因为不独立会冻死 UI）：
///
///   ConversationStore 里 liveTrail / statusText / requestRound / requestRounds
///   四个都是 @Published，AI 干活时每个工具的开始与结束、每轮切换都会写一次。
///   ChatView 上是 `@ObservedObject var store` —— 一旦这些东西被写在 ChatView.body
///   （或它内联的任一闭包里）读取，每次写入都会让 **ChatView 的整个 body 重新求值**。
///
///   body 里有什么：LazyVStack + ForEach 全部消息 + 每条 MessageBubble +
///   每条消息的 ContentBlocks.split / MarkdownBlocks.parse / coloredBody 正则。
///   一个几十条的会话，一次重算就是几十毫秒；AI 干活时这种重算每秒来好几次，
///   主线程被彻底占满 —— 用户看到的就是「发完消息就卡死，屏幕点什么都没反应」。
///
///   抽出来以后，这四个 @Published 只在本 struct 的 body 里被读，
///   刷新范围收缩成这一小块（几十 pt 的卡片），消息列表完全不参与。
struct ThinkingPanel: View {
    @ObservedObject private var store = ConversationStore.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack {
                Spacer()
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(L10n.t("home_thinking"))
                        .font(.footnote.weight(.medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                // v3.1.66：tertiarySystemBackground 浅色模式≈白看不见，改 systemGray5
                .background(Color(.systemGray5).opacity(0.9))
                .cornerRadius(14)
                .padding(.trailing, 16)
            }
            if !store.liveTrail.isEmpty {
                LiveTrailCard(steps: store.liveTrail)
                    .padding(.trailing, 16)
            }
            if let status = store.statusText {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.trailing, 16)
            }
            if store.requestRound > 0 {
                // v4.3.71：无轮次上限 (requestRounds==0) 只显示"第 N 轮"
                if store.requestRounds > 0 {
                    Text(L10n.t("ui_157", store.requestRound, store.requestRounds))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 16)
                } else {
                    Text(L10n.t("i18n_1036", store.requestRound))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 16)
                }
            }
        }
    }
}

/// 2026-11-05：固定在输入框上方的「还在干活」状态条。
///
/// 用户原话：「我都不知道他是停止工作了还是正在工作」。
/// 原来唯一的进度提示是消息列表里的 ThinkingPanel，往上翻历史就看不见了；
/// 而列表里那行「运行了 2 个工具 12.7s」是**已完成工具**的汇总胶囊，
/// 长得像结论，很容易被当成"整轮跑完了"（用户就是这么误判的）。
/// 所以这里做一条不随列表滚动的常驻条：小菊花 + 当前动作 + 秒表，
/// 只要 isLoading 就一直在，扫一眼就知道还在跑。
struct RunStatusStrip: View {
    @ObservedObject private var store = ConversationStore.shared
    /// 本轮起始时间（ChatView 在 isLoading 翻转时写入；nil 时从 0 开始计）
    let startedAt: Date?

    var body: some View {
        if store.isLoading {
            // TimelineView 每秒只刷新这一条，不会牵动消息列表
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(Self.clock(ctx.date.timeIntervalSince(startedAt ?? ctx.date)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6).opacity(0.96))
            }
        }
    }

    /// 优先用 store 的实时状态（"正在请求模型 第 2 轮 · 调用 xxx"），
    /// 没有就退回一句通用文案，别让条子空着——空着又变成"看不出在干嘛"。
    private var title: String {
        if let s = store.statusText, !s.isEmpty { return s }
        return L10n.t("i18n_1623")
    }

    /// 秒表格式 m:ss（1:12 = 1 分 12 秒）
    static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// 2026-11-05：本轮结束标记（用户要求「需要加结束话语」）。
/// 只有 isLoading 真的变回 false 才会出现，所以不会提前骗人说跑完了。
struct TurnEndedNote: View {
    let seconds: Double

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(L10n.t("i18n_1621", RunStatusStrip.clock(seconds)))
                .font(.system(size: 11))
        }
        .foregroundColor(.secondary.opacity(0.85))
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
}

struct FloatingScrollButtons: View {
    /// 2026-11-05 fix-freeze-3：按钮显隐位单独订阅。
    ///
    /// 它以前是 ChatScrollState 上的 @Published，而 ChatView 以 @StateObject 持有那个对象 →
    /// 这两个布尔每翻一次就让 ChatView.body 全量重算。流式输出时它们翻得极频繁
    /// （变高→不在底→贴底→又在底→下一条又变高），几十次全量重算把主线程吃满，
    /// 表现就是「发完消息点哪都没反应」。拆成独立对象后只有这个 40pt 圆钮会重算。
    ///
    /// 注意这里**不再** `@ObservedObject var scroll` —— 按钮的显隐只由 flags 决定，
    /// 多订阅一个 ChatScrollState 等于让每轮滚动的 activity 翻转也重建这个按钮，白费。
    @ObservedObject var flags: ChatScrollFlags
    var onUp: () -> Void
    var onDown: () -> Void
    /// 显式 init：调用处只需要传 scroll，flags 从 scroll 里取，避免漏传。
    init(scroll: ChatScrollState, onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
        self.flags = scroll.flags
        self.onUp = onUp
        self.onDown = onDown
    }

    var body: some View {
        VStack(spacing: 10) {
            if flags.canScrollUp && flags.canScrollDown {
                button("chevron.up", action: onUp)
            }
            if flags.canScrollDown {
                button("chevron.down", action: onDown)
            }
        }
        .padding(.trailing, 12)
        .padding(.bottom, 14)
        // 按钮显隐不要动画：滚动中反复触发会额外增加布局开销
        .animation(nil, value: flags.canScrollUp)
        .animation(nil, value: flags.canScrollDown)
    }

    private func button(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 40, height: 40)
                .background(Color(.systemGray5).opacity(0.92))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct ChatChip: View {
    let label: String
    let action: () -> Void
    // v2.9.36：浅蓝=开启/强调，灰=关闭（老 MCP 风格）
    var accent: Bool = true
    // v2.9.79：前置小图标（推理强度 / 智能搜索）
    var icon: String = ""

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if !icon.isEmpty {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: 36)
            .padding(.horizontal, 10)
            .background(accent ? Color.blue.opacity(0.14) : Color(.systemGray5))
            .foregroundColor(accent ? Color.blue : Color.secondary)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(accent ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v3.0.76：输入框上方快捷标签按钮
struct QuickTabButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(height: 36)
            // v3.4.4：与 ChatChip 统一内边距/圆角，保证滑动模块比例一致
            .padding(.horizontal, 10)
            .background(Color(.secondarySystemBackground))
            .foregroundColor(.secondary)
            .cornerRadius(16)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v2.9.36：聊天框"当前模型"点击弹出的上游模型选择（老 MCP 风格半屏）
// 2026-11-02 按用户要求重构：
//  1) 弹窗默认直接展示「当前选中供应商」的全部模型，点模型即切换
//  2) 「在设置中管理模型」改为「选择模型供应商」——进入供应商列表，
//     点某供应商 → 该供应商模型列表（本弹窗）→ 再点模型 → 回聊天页
struct ChatModelPickerSheet: View {
    @ObservedObject private var modelStore = ModelStore.shared
    let onSelect: (ModelConfig) -> Void
    // v7.1.95：首页切换模型弹窗直接获取上游模型并切换（用户要求）
    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels = false
    @State private var fetchError = ""
    @State private var query = ""
    // 2026-11-02：供应商切换页（true = 显示供应商列表；false = 显示模型列表）
    @State private var showingSupplierList = false
    // 2026-11-02：当前正在浏览其模型列表的配置（nil = 用默认配置）
    @State private var browsingConfigID: UUID?

    /// 当前浏览的供应商配置：优先用户在本弹窗里选的，否则用默认配置
    private var activeConfig: ModelConfig? {
        if let id = browsingConfigID,
           let c = modelStore.configs.first(where: { $0.id == id }) { return c }
        return modelStore.defaultConfig ?? modelStore.configs.first
    }

    /// 该供应商可选的模型名：上游拉取结果优先；未拉取则只显示当前配置里的那一个
    private var modelOptions: [String] {
        var list = fetchedModels
        if let cur = activeConfig?.model, !cur.isEmpty, !list.contains(cur) {
            list.insert(cur, at: 0)
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        CompatNav {
            Group {
                if showingSupplierList {
                    supplierListView
                } else {
                    modelListView
                }
            }
            .navigationTitle(showingSupplierList ? L10n.t("i18n_1070") : L10n.t("i18n_1064"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if showingSupplierList {
                        Button(action: { showingSupplierList = false }) {
                            HStack(spacing: 2) {
                                Image(systemName: "chevron.left")
                                Text(L10n.t("i18n_1501"))
                            }
                            .font(.footnote)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("i18n_1180")) { }
                        .hidden()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 模型列表页（本弹窗主界面）

    private var modelListView: some View {
        List {
            // 当前供应商抬头
            if let cfg = activeConfig {
                Section {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cfg.name)
                                .font(.body.weight(.medium))
                            Text("\(cfg.model) · \(cfg.provider)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if modelStore.defaultConfig?.id == cfg.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                        }
                    }
                } header: {
                    SettingSectionHeader(title: L10n.t("i18n_1069"))
                }
            }

            // 模型列表：点即切换（供应商已定，只换 model）
            Section {
                // 2026-11-02：模型可能几十个，加搜索框快速筛
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

                if modelOptions.isEmpty {
                    Text(isFetchingModels ? L10n.t("i18n_1504") : L10n.t("i18n_1505"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(modelOptions, id: \.self) { m in
                        Button(action: { pickModel(m) }) {
                            HStack(spacing: 10) {
                                Image(systemName: activeConfig?.model == m ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(activeConfig?.model == m ? .blue : Color.secondary.opacity(0.45))
                                Text(m)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if ModelConfig.modelSupportsVision(m) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.blue)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 拉取上游模型
                if let cfg = activeConfig {
                    Button(action: { fetchModels(for: cfg) }) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 18))
                                .foregroundColor(.blue)
                            Text(L10n.t("ui_128"))
                                .foregroundColor(.blue)
                            Spacer()
                            if isFetchingModels { ProgressView() }
                        }
                        .font(.footnote)
                    }
                    .disabled(isFetchingModels)
                    if !fetchError.isEmpty {
                        Text(fetchError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            // 「选择模型供应商」——进入供应商列表（原「在设置中管理模型」）
            Section {
                Button(action: { showingSupplierList = true }) {
                    HStack {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.blue)
                        Text(L10n.t("i18n_1070"))
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 供应商列表页

    private var supplierListView: some View {
        List {
            Section {
                ForEach(modelStore.configs) { cfg in
                    Button(action: {
                        // 选中供应商 → 回到模型列表页，并拉取该供应商模型
                        // 2026-11-02：先清上一家缓存再赋值/拉取——清空必须同步做在原地，
                        // 放 onChange 会与网络回调竞态（可能把刚拉到的列表清掉）
                        fetchedModels = []
                        fetchError = ""
                        query = ""
                        browsingConfigID = cfg.id
                        showingSupplierList = false
                        fetchModels(for: cfg)
                    }) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                // 2026-11-03 修（用户反馈「显示的不是供应商而是模型」）：
                                // 原来主标题直接用 cfg.name —— 用户没改名时它等于模型名，
                                // 整页看到的就是 deepseek-v4.1-flash，一个供应商都没有。
                                // 现在：主标题=供应商友好名（自定义时用用户起的名字），
                                // 副标题=模型名 + 接口地址主机，两者都带标签，不会再混。
                                Text(cfg.supplierTitle)
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.primary)
                                HStack(spacing: 4) {
                                    Text("模型")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                    Text(cfg.model)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if let host = cfg.endpointHost, !host.isEmpty {
                                    Text(host)
                                        .font(.caption2)
                                        .foregroundColor(.secondary.opacity(0.75))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            if cfg.supportsVision {
                                Image(systemName: "photo")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                            Spacer()
                            if modelStore.defaultConfig?.id == cfg.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                SettingSectionHeader(title: L10n.t("i18n_1502", modelStore.configs.count))
            }

            Section {
                // 仍保留直达完整管理页的入口（新增/删除/改 Key 等）
                NavigationLink(destination: ModelsView()) {
                    Label(L10n.t("i18n_1503"), systemImage: "gearshape.fill")
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 动作

    /// 选定模型：写回该供应商配置并设为默认，然后关闭弹窗回聊天页
    private func pickModel(_ m: String) {
        guard var c = activeConfig else { return }
        c.model = m
        c.isDefault = true
        modelStore.update(c)   // 保持默认 + 同步共享文件（HUD 语音同用）
        onSelect(c)            // 外层关 sheet + toast 提示已切换
    }

    private func fetchModels(for cfg: ModelConfig) {
        isFetchingModels = true
        fetchError = ""
        ModelAPIClient.shared.fetchModelList(config: cfg) { result in
            isFetchingModels = false
            switch result {
            case .success(let models):
                fetchedModels = models
                if models.isEmpty {
                    fetchError = L10n.t("i18n_428")
                }
            case .failure(let error):
                fetchError = error
            }
        }
    }
}

struct QuickActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var colors: [Color] = [.blue, .tmCyan]   // v2.9.78：渐变图标底
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(colors[0])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(colors[0].opacity(0.15), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// v4.4.15：气泡点击手势——仅 tool 折叠 / 多选模式注册 onTapGesture；
// 纯文本气泡(非tool非selection)不注册任何点击手势，否则父级 contentShape+onTapGesture
// 的手势识别器会抢占内部 Text 的 textSelection 长按 → AI 回复一大段文字长按选字失效(用户实测)
private struct MessageTapModifier: ViewModifier {
    let isTool: Bool
    let selectionMode: Bool
    let onToggleSelect: (() -> Void)?
    let onToolToggle: () -> Void
    func body(content: Content) -> some View {
        if isTool || selectionMode {
            content
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectionMode { onToggleSelect?() }
                    else { onToolToggle() }
                }
        } else {
            content
        }
    }
}

/// 2026-11-05 **性能关键（fix-freeze-2）**：MessageBubble 改为 Equatable。
///
/// 为什么：`ChatView.body` 重算时，`ForEach` 里的每个 `MessageBubble` 都会被
/// **重新构造并重新求值整个子树**——包括 ContentBlocks.split、MarkdownBlocks.parse、
/// coloredBody 正则、SelectableText(UITextView) 的 updateUIView。
/// 一个几十条的会话，一次 body 重算 = 几十份解析 + 几十次 UITextView 更新。
///
/// 而 AI 干活期间 `ConversationStore` 的 @Published 每秒会变好几次
/// （liveTrail 每步、statusText 每句、requestRound 每轮），
/// 于是这个「几十份解析」每秒跑好几遍 —— 主线程直接饱和，
/// 用户感知就是「发完消息就卡死，点什么都没反应」。
///
/// 实现 Equatable 后，配合调用处的 `.equatable()`，
/// SwiftUI 在参数相等时**跳过整棵子树的重算**。绝大多数历史消息的
/// 参数完全不变（同一个 ChatMessage、同样的 fastScrolling / selectionMode），
/// 于是只有正在流式增长的那一条会重算 —— 成本从 O(全部消息) 降到 O(1)。
///
/// 比对字段的原则：只比**影响渲染结果**的输入。
/// 闭包（onCopy/onShare/onWithdraw/onOpenSubAgent）不比 —— 它们每个 body
/// 都是新实例，比必不相等，会导致永远走不到快速路径。这些闭包捕获的
/// 都是稳定的 msg.id 与 self 上的方法，语义上恒定。
struct MessageBubble: View, Equatable {
    let message: ChatMessage
    // 2026-11-03：正在快速滚动 → 正文降级为轻量 Text（见 ChatScrollState.isScrollingFast 的注释）。
    // 由 ChatView 透传下来而不是让每个气泡各自订阅：气泡数量多，
    // 每个都自带 @ObservedObject 会多出几十个订阅者，反而更重。
    var fastScrolling: Bool = false
    // v4.3.77：安装进度——工具"执行中"气泡渲染实时进度条（引用处位于本 struct）
    @ObservedObject private var installRegistry = InstallationRegistry.shared
    // v7.2.3-fix23.1：参数展开状态每气泡自管（原 ChatView 级 @State 在独立 struct 内
    // 无法访问——编译错误根因；每气泡独立布尔天然隔离）
    @State private var argsExpanded = false
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelect: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onShare: (() -> Void)? = nil
    /// 2026-11-02：撤回（仅用户消息）——删除本条及其后全部消息，文字回填输入框，不触发重新生成
    var onWithdraw: (() -> Void)? = nil
    // fix73j：子代理完成卡点击回调（taskID + 消息内摘要 JSON fallback）
    var onOpenSubAgent: ((String, String?) -> Void)? = nil
    // v3.4.5：当前正在流式生成的 AI 消息 → 打字机逐字显示
    var isStreaming: Bool = false
    // v3.4.9：本轮刚生成完成的消息（工具解说/整段到达的回复）也要逐字打出——
    // 这些消息 isStreaming=false 且内容在出现前已定好，靠 onAppear 强制启动打字机
    var forceType: Bool = false
    // v3.5.31：思考开关——思考关时隐藏思考块（API 仍可能返回 thinking，UI 一律不显示）
    var thinkEnabled: Bool = true
    // v7.2.2：引用角标 [N] 点击 → 来源卡浮层（Perplexity/Kimi 式点击跳原文）
    @State private var sourceCardURL: URL?
    @State private var showSourceCard = false

    // v6.0.28：工具结果默认折叠，用户手动点才展开
    @State private var expanded = false
    @State private var expandedToolIds: Set<String> = []
    // v3.4.5：打字机效果——已显示字符数 + 定时器（显示与网络解耦，逐字稳定刷出）
    // v3.4.7：降速到 25 字/秒(0.04s/字)让打字感清晰可见；且不依赖 isStreaming——
    // 只要内容在增长就持续打字到完整，兼容"整段一次性到达"的中转
    // v3.5.4：用户反馈太慢 → 提速到 ~133 字/秒 (0.015s/tick × 2 字符），快但仍看得出打字感
    @State private var revealedCount = 0
    @State private var typeTimer: Timer?
    // v4.4.18：流式自动朗读——记录已朗读到的字符位置，content 增长时只把新增整句送 TTS
    @State private var autoSpokenUpTo = 0
    // v7.1.109-peers：打字机"已打完"持久化标记（UserDefaults by messageId）——
    // 修切后台/LazyVStack 重建后 forceType 消息 revealedCount 归 0 重新打字、
    // 打完不渲染块（杀后台重进才正常）的问题。打过一次即永久视为已显示完整：
    // 视图重建时直接全文渲染（表格/黑底立即可见），不再重打。
    private static var doneTypingCache: [String: Bool] = [:]
    private static func doneTyping(for id: UUID) -> Bool {
        let key = id.uuidString
        if let v = doneTypingCache[key] { return v }
        let v = (UserDefaults.standard.dictionary(forKey: "ui.doneTyping")?[key] as? Bool) ?? false
        doneTypingCache[key] = v
        return v
    }
    private static func markDoneTyping(_ id: UUID) {
        let key = id.uuidString
        doneTypingCache[key] = true
        var d = UserDefaults.standard.dictionary(forKey: "ui.doneTyping") ?? [:]
        d[key] = true
        UserDefaults.standard.set(d, forKey: "ui.doneTyping")
    }
    private static func clearDoneTyping(_ id: UUID) {
        let key = id.uuidString
        doneTypingCache[key] = false
        var d = UserDefaults.standard.dictionary(forKey: "ui.doneTyping") ?? [:]
        d[key] = false
        UserDefaults.standard.set(d, forKey: "ui.doneTyping")
    }

    // v3.5.4：自适应打字机（业界：平时 ~50 字/秒舒适，积压多自动提速追平网络，标点/换行稍停顿更自然）。
    // 不像固定 133 字/秒那样一快到底；也不像 25 字/秒那样拖沓。
    private func startTypeTimer() {
        guard typeTimer == nil else { return }
        // v7.1.109-peers：非流式(forceType)消息且已打完过 → 直接显示全文，不重打
        if !isStreaming, Self.doneTyping(for: message.id) {
            revealedCount = message.content.count
            return
        }
        // v7.2.5-fix63：长消息（≥4000 字符）不打字机——命令结果/工具长回复直出全文。
        // 打字机 0.02s tick 每帧全量 ContentBlocks.split(正则)，长文本主线程持续高压；
        // 多消息同时打字（长会话）→ 主线程风暴 → 白屏（用户滑一下触发重建才恢复）。
        // 打字机保留给短消息（体验不变），长消息跳过是纯性能修复。
        if message.content.count >= 4000 {
            revealedCount = message.content.count
            Self.markDoneTyping(message.id)
            return
        }
        // v3.5.4：MessageBubble 是 SwiftUI 结构体(值类型)，不能用 [weak self]；定时器 onDisappear 会 invalidate
        typeTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            DispatchQueue.main.async {
                guard self.revealedCount < self.message.content.count else {
                    self.stopTypeTimer()
                    // v7.1.109-peers：打完了——持久化标记（流式消息不标记，流式由内容增长驱动）
                    if !self.isStreaming { Self.markDoneTyping(self.message.id) }
                    return
                }
                let total = self.message.content.count
                let backlog = total - self.revealedCount
                let idx = self.message.content.index(self.message.content.startIndex, offsetBy: self.revealedCount)
                let ch = self.message.content[idx]
                let isPause = ch == "\n" || "，。；：！？、,.。;:!?… ".contains(ch)
                // v7.1.109-peers：大厂式打字速度——基础 3 字符/tick(150字/秒)不拖沓，
                // 积压大幅提速追平网络/整段到达，标点/换行 1 字符停顿更有呼吸感
                let step: Int
                if backlog > 200 { step = 12 }       // 大量积压 → 追平
                else if backlog > 100 { step = 8 }   // 积压多 → 提速
                else if backlog > 40 { step = 5 }    // 稍积压 → 中快
                else if isPause { step = 1 }         // 标点/换行 → 停顿
                else { step = 3 }                    // 常规 ~150 字/秒
                self.revealedCount = min(total, self.revealedCount + step)
            }
        }
    }
    private func stopTypeTimer() {
        typeTimer?.invalidate()
        typeTimer = nil
    }
    // v4.4.20：自动朗读——用 autoSpokenUpTo 增量读"没读过"的部分；流式/非流式 onAppear+onChange 双触发共用，防重复
    // 句子边界：句末标点切分；无标点长段攒够 60 字也强制读（防一直憋着不读）
    // v7.1.38：朗读位置改全局持久化（UserDefaults by messageId）——修 v4.5.7 移除 onAppear 后
    // 非流式/先完成的消息 onChange 不触发导致"顶部自动朗读完全不发声"；持久化+时间窗防历史消息复读。
    private static var spokenPosCache: [String: Int] = [:]
    private static func spokenPos(for id: UUID) -> Int {
        let key = id.uuidString
        if let c = spokenPosCache[key] { return c }
        let v = (UserDefaults.standard.dictionary(forKey: "tts.spokenPositions")?[key] as? Int) ?? 0
        spokenPosCache[key] = v
        return v
    }
    private static func setSpoken(_ n: Int, for id: UUID) {
        let key = id.uuidString
        spokenPosCache[key] = n
        var d = UserDefaults.standard.dictionary(forKey: "tts.spokenPositions") ?? [:]
        d[key] = n
        UserDefaults.standard.set(d, forKey: "tts.spokenPositions")
    }
    private func autoSpeak(_ full: String, for id: UUID) {
        var spoken = Self.spokenPos(for: id)
        let chars = Array(full)
        if spoken >= chars.count { return }
        var boundary = spoken
        while boundary < chars.count {
            let isPunct = "。！？!?\n…".contains(chars[boundary])
            let overLimit = (boundary - spoken) >= 60
            if isPunct || overLimit {
                let sentence = String(chars[spoken...boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { TTSService.shared.speak(sentence) }
                // v7.1.40 fix：切完一句必须前移 spoken，否则循环继续用旧起点切片 →
                // 多句回复入队「句1 / 句1+2 / 句1+2+3…」全部重复第一句（用户实测「循环重复第一句话」根因）
                spoken = boundary + 1
                Self.setSpoken(boundary + 1, for: id)
            }
            boundary += 1
        }
    }
    // v3.5.4：思考黄泡——思考进行中(isStreaming)自动展开让用户看到模型在动；
    // 思考结束自动收起(除非用户手动展开)。业界(掘金/Koder/DeepSeek Harness)一致做法。
    private var thinkingExpanded: Bool {
        isStreaming ? true : expandedToolIds.contains(message.id.uuidString)
    }
    private func toggleThinking() {
        let id = message.id.uuidString
        if expandedToolIds.contains(id) { expandedToolIds.remove(id) }
        else { expandedToolIds.insert(id) }
    }

    /// 2026-11-05：Equatable —— 仅比较**影响渲染结果**的输入。
    ///
    /// 不比闭包：它们每次 body 都是新实例，比必不相等，加了等于白加。
    /// 不比 @State：@State 是视图内部状态，不由外部参数决定，本来就不参与。
    /// ChatMessage 本身是 Hashable（含 id/content/toolCalls/thinking/trail 等），
    /// 内容增长、工具状态变化、轨迹落定都会让它不相等 —— 正是我们想要的粒度。
    ///
    /// `fastScrolling` **必须**留在比较里（2026-11-05 fix-jump 后依然如此）：
    /// 它现在控制的是 UITextView 的 `isSelectable`，翻转时必须让
    /// `updateUIView` 跑一次把选择能力还回去/摘下来。去掉它 → 停手后永远选不了字。
    /// 注意它**不再影响控件类型和行高**（老实现会换 Text，那才是跳动的来源）。
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.fastScrolling == rhs.fastScrolling
            && lhs.selectionMode == rhs.selectionMode
            && lhs.isSelected == rhs.isSelected
            && lhs.isStreaming == rhs.isStreaming
            && lhs.forceType == rhs.forceType
            && lhs.thinkEnabled == rhs.thinkEnabled
    }

    private var isUser: Bool { message.role == "user" }
    private var isTool: Bool { message.isTool }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                if selectionMode { selectionBadge }
                Spacer(minLength: 50)
            }

            if isTool {
                toolBubble
            } else {
                textBubble
            }

            if !isUser {
                // v3.4.0：AI 输出不追加右侧 Spacer —— 气泡随 .frame(maxWidth:.infinity) 填满整个可用宽度
                if selectionMode { selectionBadge }
            }
        }
        // v3.4.4：AI/工具气泡左右各留 16 边距（用户反馈 10 仍太小）；用户气泡右侧留白 12
        .padding(.horizontal, isUser ? 12 : 16)
        // v4.4.15：条件点击手势——tool/多选才注册，纯文本气泡不注册(让 textSelection 长按生效)
        .modifier(MessageTapModifier(
            isTool: isTool,
            selectionMode: selectionMode,
            onToggleSelect: onToggleSelect,
            onToolToggle: { withAnimation { expanded.toggle() } }
        ))
        // v4.4.13：移除 contextMenu——长按文字改为系统选择手柄(.textSelection)，可拖选部分复制。
        // 此前外层 contextMenu(复制全文/分享)抢占长按, 导致内层 Text 的 .textSelection(.enabled) 永远触发不了
        // 文字选择。全量复制/分享走多选工具栏(selectionMode: copySelected/shareMessage)。
        // v3.4.5：打字机效果——内容增长即逐字显示，直到完整
        // v7.1.109-peers：forceType 已完成消息视图重建时直接全文（不重打）；
        // 流式消息实时跟随网络（onChange(content) 同步 revealedCount），不启动限速 timer
        .onAppear {
            if isStreaming { Self.clearDoneTyping(message.id) }
            if !isStreaming, forceType, revealedCount < message.content.count { startTypeTimer() }
        }
        .onDisappear { stopTypeTimer() }
        .onChange(of: isStreaming) { streaming in
            if streaming {
                // v7.1.109-peers：流式开始——实时跟随网络，不启动限速 timer
                revealedCount = message.content.count
            }
            // v7.1.109-peers：流式结束且已显示完整 → 标记已打完（防切后台回来重打）
            else if revealedCount >= message.content.count { Self.markDoneTyping(message.id) }
        }
        .onChange(of: message.content) { _ in
            // v7.1.109-peers：流式中实时同步（网络到哪渲染哪，大厂式流式）；forceType 落后时启动打字机
            if isStreaming {
                revealedCount = message.content.count
                Self.clearDoneTyping(message.id)
            } else if revealedCount < message.content.count { startTypeTimer() }
        }
    }

    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20))
            .foregroundColor(isSelected ? .blue : Color.secondary)
            .padding(.bottom, 10)
    }

    // fix73j：子代理状态卡——[SUBAGENT-RUNNING]/[SUBAGENT-DONE] 回传的 user 消息
    // 渲染为可点开卡片，点击进入 SubAgentDetailView 看完整轨迹
    // （对齐豆包任务卡/Claude Code 结果回传 UI；状态文案：执行中/已完成/失败/已停止/已中断）
    private var subAgentStatusCard: some View {
        let parsed = SubAgentCompleteCard.parse(message.content)
        let isRunning = message.content.hasPrefix("[SUBAGENT-RUNNING]")
        let status = parsed["status"] as? String ?? (isRunning ? "running" : "done")
        let statusZh = SubAgentStatusText.zh(status)
        let ok = status == "done"
        let fail = status == "failed" || status == "interrupted"
        let icon = isRunning ? "hourglass"
            : (ok ? "checkmark.circle.fill" : "xmark.circle.fill")
        let iconColor: Color = isRunning ? .blue : (ok ? .green : .red)
        let agent = parsed["agent_type"] as? String ?? "general"
        let rounds = parsed["rounds"] as? Int ?? 0
        let elapsed = parsed["elapsed_secs"] as? Int ?? 0
        let result = (parsed["result"] as? String)?
            .replacingOccurrences(of: "\n", with: " ")
        let summary: String
        if isRunning {
            // 运行中卡不显示假的"0 轮 · 0s"——派发即上屏，进度请看详情页（实时轮询）
            summary = "\(agent) · 已派发，点击查看实时进度"
        } else {
            summary = "\(agent) · \(rounds) 轮 · \(elapsed)s\(result.map { " · " + String($0.prefix(60)) } ?? "")"
        }
        return Button(action: {
            onOpenSubAgent?(parsed["task_id"] as? String ?? "", message.content)
        }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(iconColor)
                    .opacity(isRunning ? 0.85 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(message.toolTitle ?? "子代理 \(parsed["task_id"] as? String ?? "") · \(statusZh)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, isUser ? 12 : 16)
        }
        .buttonStyle(.plain)
        .textSelection(.disabled)
    }

    // v4.4.11：AI 正文行内代码(反引号)→橙色(与"已深度思考"同色)。手动正则解析，
    // 容错流式打字机未闭合反引号(不配对则视为普通文本)。仅 assistant 生效, user 保持纯文本。
    // v4.4.12：正文 markdown 加粗(**xx**)→粗体(semibold)。代码段优先(橙色)，代码段外再匹配粗体。
    /// v4.4.21：消息文本视图——流式/打字机/用户消息用轻量 Text（避免 UITextView 高频刷新闪跳）；assistant 完成消息用 SelectableText(UITextView) 长按选字/划词/复制
    /// v7.1.109-minis：assistant 完成消息改 Markdown 块渲染（表格/代码块/文本，对齐 OpenMinis
    /// SelectableMarkdownView）——表格 LazyVGrid 栅格、代码块黑底等宽命令行样式、文本沿用正则着色。
    /// 选择能力用 .textSelection(.enabled) 保留（v4.4.13 已验证 Text 拖选可用）。
    @ViewBuilder
    private func messageTextView(_ shown: String) -> some View {
        // v7.1.109-peers：流式/打字机也走块渲染（消除"打完才渲染"跳变矛盾）——
        // shown 是 revealedCount 截断文本：文本块随打字逐字增长（打字机保留）、
        // 代码块黑底从 fence 出现即渲染并随打字增长、表格在分隔行打全后渲染完整行；
        // 未闭合的 fence/表格自动回退纯文本。用户消息保持纯文本。
        if isUser {
            // 2026-11-02：用户消息也换成 UITextView（SelectableText）——长按系统菜单里多一项
            // 「复制全文」，同时保留拖手柄划词。打字机阶段仍用轻量 Text 避免高频刷新闪跳。
            // 2026-11-03：快速滚动期间也降级（fastScrolling）——见下方 assistant 分支注释。
            // 2026-11-05 fix-jump：降级**不再换控件**，只在同一个 UITextView 上关掉选择。
            // 换控件会改行高 → 每轮滚动停手时整屏跳一次，这是用户实测的「每滑一次跳一下」。
            if isStreaming || (forceType && !Self.doneTyping(for: message.id)) {
                Text(AttributedString(shown))
                    .font(.body)
                    .textSelection(.enabled)
            } else {
                SelectableText(
                    attributed: NSAttributedString(
                        string: shown,
                        attributes: [
                            .font: UIFont.systemFont(ofSize: 17),
                            .foregroundColor: UIColor.white
                        ]
                    ),
                    textColor: .white,
                    fontSize: 17,
                    copyAllTitle: L10n.t("i18n_1530"),
                    onCopyAll: { onCopy?() },
                    isSelectable: !fastScrolling
                )
            }
        } else {
            // v7.2.3-fix18：正文 block 化——文本/工具强隔离（对齐 OpenMinis block 模型）。
            // 模型误输出 DSML/antml 文本调用时，剥出工具段渲染为内联胶囊，
            // 工具调用绝不混进 AI 正文（原样文本只按代码块显示的旧行为废除）。
            let blocks = ContentBlocks.split(shown)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    if block.kind == .text {
                        MarkdownBlocksView(
                            text: block.text,
                            coloredBody: { self.coloredBody($0) },
                            // v7.2.2：联网计数——本条 assistant 消息的 toolCalls 里 web_search/web_fetch 次数
                            // v7.2.3-fix：shell_exec 里的 curl 拉取也算联网
                            // 2026-11-02：必须放在 nsBody 之前——结构体成员顺序即参数顺序，否则编译报
                            // "argument 'webSearchCount' must precede argument 'nsBody'"
                            webSearchCount: (message.toolCalls ?? []).filter {
                                $0.name.contains("web_search") || $0.name.contains("web.search")
                                    || $0.name.contains("web_fetch") || $0.name.contains("web.fetch")
                                    || Self.toolCallIsCurlFetch($0)
                            }.count,
                            nsBody: { self.attributedBody($0) },
                            copyAllTitle: L10n.t("i18n_1530"),
                            onCopyAll: { onCopy?() },
                            fastScrolling: fastScrolling
                        )
                            // v7.2.2：引用角标 [N] 可点击 → 来源卡浮层（拦截 minis://source?n= 链接）
                            .environment(\.openURL, OpenURLAction { url in
                                if url.scheme == "minis" && url.host == "source",
                                   let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                                   let nItem = comps.queryItems?.first(where: { $0.name == "n" }),
                                   let n = Int(nItem.value ?? ""),
                                   let src = CitationExtractor.extract(block.text).sources.first(where: { $0.index == n }) {
                                    sourceCardURL = src.url
                                    showSourceCard = true
                                    return .handled
                                }
                                return .systemAction
                            })
                    } else {
                        inlineToolCapsule(block)
                    }
                }
            }
            .overlay(sourceCardOverlay)
        }
    }

    /// v7.2.3-fix18：内联工具胶囊——DSML/antml 文本调用段渲染
    /// （只渲染不执行，明确标注未执行，避免"看起来调用了"的假象）
    @ViewBuilder
    private func inlineToolCapsule(_ block: ContentBlock) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                Text(block.toolTitle ?? block.toolName ?? "tool")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer()
                Text(L10n.t("i18n_1259"))
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            if let args = block.toolArgs, !args.isEmpty {
                Text(args)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(8)
    }

    /// v7.2.3-fix20：连续工具折叠组——默认一行胶囊（运行了 N 个工具 + 总耗时），
    /// 点击展开显示各工具卡（左侧竖线标示为折叠组）

    // v7.2.2：来源卡浮层——底部卡片：host + URL + 打开按钮
    /// v7.2.3-fix11：ANSI 剥离（对齐 Open Minis 终端——"乱码少"的关键）——
    /// shell 工具输出常带 \x1b[...m 颜色码 / OSC 序列（\x1b]...\x07），纯文本
    /// Text 直接渲染会显示成乱码/方块。显示层剥离，不写回 content——
    /// 链接提取（LinkExtractor）仍用原始 content，功能不受影响。
    /// v7.2.3-fix38：对齐 OpenMinis sanitizeForDisplay——完整剥 ANSI（CSI/OSC/两字符/孤立 ESC）
    /// + 控制字符清理（保留 \n\t，删 \r，其余 C0/DEL/C1 替换为 ），这是工具结果乱码的根因。
    private static func sanitizeForDisplay(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = String()
        out.reserveCapacity(text.count)
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        let end = scalars.endIndex
        while i < end {
            let v = scalars[i].value
            if v == 0x1B {
                // ANSI escape：CSI / OSC / 两字符 / 孤立——整段吞掉
                let next = scalars.index(after: i)
                guard next < end else { i = next; continue }
                let n = scalars[next].value
                if n == 0x5B { // CSI: ESC [ ... final byte
                    var j = scalars.index(after: next)
                    while j < end {
                        let c = scalars[j].value
                        j = scalars.index(after: j)
                        if c >= 0x40 && c <= 0x7E { break }
                    }
                    i = j
                } else if n == 0x5D { // OSC: ESC ] ... BEL or ESC \
                    var j = scalars.index(after: next)
                    while j < end {
                        let c = scalars[j].value
                        if c == 0x07 { j = scalars.index(after: j); break }
                        if c == 0x1B {
                            let k = scalars.index(after: j)
                            if k < end && scalars[k].value == 0x5C { j = scalars.index(after: k); break }
                        }
                        j = scalars.index(after: j)
                    }
                    i = j
                } else {
                    // 两字符（ESC M / ESC =）或孤立——都丢弃
                    i = scalars.index(after: next)
                }
                continue
            }
            // 保留 \n(0x0A) \t(0x09)；\r 静默删（CRLF 双换行）；其余 C0 + DEL 替换
            if (v < 0x20 && v != 0x0A && v != 0x09) || v == 0x7F {
                if v != 0x0D { out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!) }
                i = scalars.index(after: i)
                continue
            }
            // C1 控制块（0x80..0x9F）
            if v >= 0x80 && v <= 0x9F {
                out.unicodeScalars.append(Unicode.Scalar(0xFFFD)!)
                i = scalars.index(after: i)
                continue
            }
            out.unicodeScalars.append(scalars[i])
            i = scalars.index(after: i)
        }
        return out
    }

    /// v7.2.3-fix13：终端 tab 展开（Open Minis 像素网格对齐的关键）——
    /// \t → 补空格到 8 列边界（终端标准），中文按 2 列宽估算。
    /// SwiftUI 的 Text 不保证渲染 tab 对齐，shell 表格输出（tabulate 等）
    /// 的列会全乱——必须先展开成空格。
    private static func expandTabs(_ text: String) -> String {
        var out = ""
        var col = 0
        for ch in text {
            if ch == "\t" {
                let pad = 8 - (col % 8)
                out.append(String(repeating: " ", count: pad))
                col += pad
            } else if ch == "\n" {
                out.append(ch)
                col = 0
            } else {
                out.append(ch)
                col += ch.isASCII ? 1 : 2
            }
        }
        return out
    }

    /// v7.2.3-fix12：Open Minis 终端配色（attributedShellLine 对齐）——
    /// 纯文本工具结果：白字 + URL 蓝色下划线高亮（其余无色，终端风）。
    private static func terminalStyled(_ text: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: text)
        let full = NSRange(text.startIndex..., in: text)
        ns.addAttribute(.foregroundColor, value: UIColor.white, range: full)
        Self.blueURLs(in: ns, string: text)
        return AttributedString(ns)
    }

    /// URL → cyan + 下划线（v7.2.3-fix38：对齐 OpenMinis 终端 URL=cyan，此前是蓝色）
    private static func blueURLs(in ns: NSMutableAttributedString, string: String) {
        let pattern = #"https?://[^\s"'\(\)\]\}，。；：,;]+"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            let full = NSRange(string.startIndex..., in: string)
            for m in re.matches(in: string, range: full) {
                ns.addAttribute(.foregroundColor, value: UIColor.cyan, range: m.range)
                ns.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range)
            }
        }
    }

    /// v7.2.3-fix3：工具结果 JSON 格式化——解析成功 → prettyPrinted 缩进；
    /// v7.2.3-fix10：配色收敛——只要顶层"头"键（data/cwd 等）绿色，
    /// 其余全部白色（用户实测三色太花）。解析失败返回 nil → 调用方回退原文纯文本。
    /// 限长 20000 字符，超大 JSON 截断标注，避免渲染卡顿。
    /// v7.2.5-fix63：结果缓存（content 即 key）——LazyVStack 离屏重建不再重跑
    /// JSONSerialization + 正则着色（大 JSON 一次几百 ms 的主线程开销）。上限 128。
    private static var jsonHighlightCache: [String: AttributedString] = [:]
    private static func jsonHighlighted(from text: String) -> AttributedString? {
        if let hit = jsonHighlightCache[text] { return hit }
        guard let result = jsonHighlightedRaw(from: text) else { return nil }
        if jsonHighlightCache.count >= 128 { jsonHighlightCache.removeAll(keepingCapacity: true) }
        jsonHighlightCache[text] = result
        return result
    }
    private static func jsonHighlightedRaw(from text: String) -> AttributedString? {
        // v7.2.3-fix11：先剥 ANSI——shell 输出带颜色码时 JSONSerialization 无法解析
        let cleaned = Self.sanitizeForDisplay(text)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else { return nil }
        let limited = pretty.count > 20000
            ? String(pretty.prefix(20000)) + "\n… (truncated)"
            : pretty
        let ns = NSMutableAttributedString(string: limited)
        let full = NSRange(limited.startIndex..., in: limited)
        let mono = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        ns.addAttribute(.font, value: mono, range: full)
        ns.addAttribute(.foregroundColor, value: UIColor.white, range: full)
        // v7.2.3-fix27：顶层键绿色——此前正则 ^" 匹配行首引号，但 JSONSerialization
        // prettyPrinted 的顶层键前有 2 空格缩进（"  key":），正则从未命中 → 全白。
        // 改为 ^ {2}" 精确匹配顶层缩进（嵌套键 4+ 空格不命中，保持"头键绿"预期）
        // v7.2.3-fix39：所有键（任意缩进，含嵌套）都绿色——此前只顶层 2 空格键绿，
        // 嵌套键（data 内的 _call_count/mode 等）仍白。要求行首缩进+引号+冒号，排除数组元素。
        if let re = try? NSRegularExpression(pattern: #"(?m)^(\s*)"((?:[^"\\]|\\.)*)"\s*:"#) {
            for m in re.matches(in: limited, range: full) {
                ns.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: m.range)
            }
        }
        // v7.2.3-fix12：JSON 内的 URL 值 → 蓝色（Open Minis 终端配色）
        Self.blueURLs(in: ns, string: limited)
        return AttributedString(ns)
    }

    /// v7.2.3-fix：shell_exec 命令里含 curl 拉取 → 计为联网（工具参数 JSON 解析，
    /// 识别 command 字段的 curl 调用；下载 -o/-O 也是联网行为，一并计入用户视角的"用了网络"）
    private static func toolCallIsCurlFetch(_ call: ToolCall) -> Bool {
        guard call.name == "shell_exec",
              let data = call.arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["command"] as? String else { return false }
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = c.lowercased()
        return lower.hasPrefix("curl") || lower.hasPrefix("env") && lower.contains(" curl ")
            || lower.contains(" curl ")
    }

    // v7.2.2：来源卡浮层——底部卡片：host + URL + 打开按钮
    @ViewBuilder
    private var sourceCardOverlay: some View {
        if showSourceCard, let url = sourceCardURL {
            ZStack {
                Color.black.opacity(0.25)
                    .onTapGesture { withAnimation { showSourceCard = false } }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "link")
                            .font(.system(size: 13))
                            .foregroundColor(.blue)
                        Text(url.host ?? url.absoluteString)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            withAnimation { showSourceCard = false }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Button {
                        BrowserManager.shared.open(url.absoluteString)
                        withAnimation { showSourceCard = false }
                    } label: {
                        Label(L10n.t("i18n_1256"), systemImage: "safari")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.blue.opacity(0.12))
                            .cornerRadius(10)
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(14)
                .padding(.horizontal, 40)
            }
            .transition(.opacity)
        }
    }

    private func coloredBody(_ text: String) -> AttributedString {
        var out = AttributedString()
        // v7.1.109-peers：引用角标 [N] 蓝色上标（Perplexity/Kimi 式）——优先于反引号着色
        // 顺序：块公式 > 行内公式 > 反引号 > [N] 角标 > 加粗（在 styledBody 内做 [N]）
        // v7.2.3-fix21：$...$/$$...$$ 数学公式等宽着色（LaTeX 源码保留可读，
        // 与反引号代码区分：公式紫色、代码橙色；真 KaTeX 图像渲染需 TextKit 改造，留后续）
        // v7.2.3-fix21.1：行内公式收紧为无空格/换行——`$100 和 $200` 这类货币
        // 文本不再被误判为公式（含空格即非公式）；块级 $$...$$ 保持宽松
        let pattern = "`([^`]+)`|(\\$\\$[^$]+\\$\\$)|(\\$[^ $\\n]+\\$)|(\\[(\\d+)\\])"
        var pos = text.startIndex
        while let range = text.range(of: pattern, options: .regularExpression, range: pos..<text.endIndex) {
            let seg = text[range]
            if pos < range.lowerBound { out += styledBody(text[pos..<range.lowerBound]) }
            if seg.hasPrefix("$$") {
                // 块级公式 $$...$$ —— 等宽紫色
                var inner = seg
                inner.removeFirst(2)
                inner.removeLast(2)
                var c = AttributedString(inner)
                c.foregroundColor = .purple
                c.font = .system(.body, design: .monospaced)
                out += c
            } else if seg.hasPrefix("`") {
                let inner = text[text.index(after: range.lowerBound)..<text.index(before: range.upperBound)]
                var c = AttributedString(inner)
                c.foregroundColor = .orange
                c.font = .system(.body, design: .monospaced)
                out += c
            } else if seg.hasPrefix("$") {
                // 行内公式 $...$ —— 等宽蓝色斜体
                var inner = seg
                inner.removeFirst()
                inner.removeLast()
                var c = AttributedString(inner)
                c.foregroundColor = .blue
                c.font = .system(.body, design: .monospaced).italic()
                out += c
            } else if seg.hasPrefix("[") {
                // [N] → 蓝色上标
                var c = AttributedString(seg)
                c.foregroundColor = .blue
                c.font = .system(size: 12, weight: .semibold)
                c.baselineOffset = 6
                out += c
            }
            pos = range.upperBound
        }
        if pos < text.endIndex { out += styledBody(text[pos..<text.endIndex]) }
        return out
    }

    // v4.4.12：代码段外的 markdown 加粗(**xx**)→粗体；未闭合的 ** 容错为普通文本
    // v7.1.109-peers：同名 styledBody（替换 styledBold），内部处理 **加粗** + [N] 角标（跨段）
    private func styledBody(_ s: Substring) -> AttributedString {
        var out = AttributedString()
        let boldPat = "\\*\\*([^*]+)\\*\\*"
        var pos = s.startIndex
        while let r = s.range(of: boldPat, options: .regularExpression, range: pos..<s.endIndex) {
            if pos < r.lowerBound { out += styledMarks(s[pos..<r.lowerBound]) }
            let inner = s[s.index(after: r.lowerBound)..<s.index(before: r.upperBound)]
            var b = AttributedString(inner)
            b.font = .system(size: 17, weight: .semibold) // v4.4.14: .system(_:weight:) 需 iOS16+, 改 system(size:weight:) 兼容更低部署目标
            out += b
            pos = r.upperBound
        }
        if pos < s.endIndex { out += styledMarks(s[pos..<s.endIndex]) }
        return out
    }

    // v7.2.1：段内富文本——~~删除线~~ / ==高亮== / *斜体* / $行内公式$ / [N] 角标（跨段）
    // v7.2.3-fix4：段内富文本 + [text](url) 链接 / 裸 URL（蓝色可点）
    private func styledMarks(_ s: Substring) -> AttributedString {
        var out = AttributedString()
        let richPat = #"~~([^~]+)~~|==([^=]+)==|\*([^*]+)\*|\$([^$\n]+)\$|\[(\d+)\]|\[([^\]\n]+)\]\((https?://[^)\s]+)\)|(https?://[^\s)\]），。；：,;]+)"#
        var pos = s.startIndex
        while let r = s.range(of: richPat, options: .regularExpression, range: pos..<s.endIndex) {
            if pos < r.lowerBound { out += AttributedString(s[pos..<r.lowerBound]) }
            let seg = String(s[r])
            let innerStart = s.index(after: r.lowerBound)
            let innerEnd = s.index(before: r.upperBound)
            let inner = String(s[innerStart..<innerEnd])
            if seg.hasPrefix("~~") {
                var a = AttributedString(inner)
                a.strikethroughStyle = .single
                a.foregroundColor = .secondary
                out += a
            } else if seg.hasPrefix("==") {
                var a = AttributedString(inner)
                a.backgroundColor = Color.yellow.opacity(0.22)
                out += a
            } else if seg.hasPrefix("*") {
                var a = AttributedString(inner)
                a.font = .system(size: 17).italic()
                out += a
            } else if seg.hasPrefix("$") {
                // v7.2.2-audit：仅当内部含 LaTeX 特征（\ ^ _ { }）才当公式——
                // 否则"$5 and $10"等货币会被误判成斜体公式、$ 符号丢失
                if inner.contains("\\") || inner.contains("^") || inner.contains("_")
                    || inner.contains("{") || inner.contains("}") {
                    var a = AttributedString(MathText.render(inner))
                    a.font = .system(size: 17).italic()
                    out += a
                } else {
                    out += AttributedString(seg)
                }
            } else if seg.hasPrefix("[") {
                // v7.2.3-fix4：[text](url) Markdown 链接 vs [N] 角标——含 "](" 即链接
                if seg.contains("]("),
                   let te = seg.range(of: "](")?.lowerBound,
                   let us = seg.range(of: "](")?.upperBound,
                   te > seg.startIndex, us < seg.endIndex {
                    let linkText = String(seg[seg.index(after: seg.startIndex)..<te])
                    let linkURL = String(seg[us..<seg.index(before: seg.endIndex)])
                    var c = AttributedString(linkText)
                    c.foregroundColor = .blue
                    c.underlineStyle = .single
                    c.link = URL(string: linkURL)
                    out += c
                } else {
                    out += AttributedString(seg)
                }
            } else if seg.hasPrefix("http") {
                // v7.2.3-fix4：裸 URL 自动链接化（尾随标点已由正则排除；
                // 用 seg 而非 inner——URL 无包裹字符，inner 会剥首尾各一字符）
                var c = AttributedString(seg)
                c.foregroundColor = .blue
                c.underlineStyle = .single
                c.link = URL(string: seg)
                out += c
            } else {
                // [N] → 蓝色上标（可点击：minis://source?n=N 由 openURL 拦截弹出来源卡）
                var c = AttributedString(seg)
                c.foregroundColor = .blue
                c.font = .system(size: 12, weight: .semibold)
                c.baselineOffset = 6
                if let n = Int(inner) {
                    c.link = URL(string: "minis://source?n=\(n)")
                }
                out += c
            }
            pos = r.upperBound
        }
        if pos < s.endIndex { out += AttributedString(s[pos..<s.endIndex]) }
        return out
    }

    // v4.5.0：原生 NSAttributedString 富文本——给 SelectableText(UITextView) 用。
    // 解析 **加粗** 与 `代码`(橙色)；直接写 UIKit font + UIColor（动态 .label 适配暗黑模式），
    // 不走 SwiftUI AttributedString 桥接（会丢橙色/加粗样式，导致暗黑下看不清、字体变小）。
    private func attributedBody(_ text: String) -> NSAttributedString {
        let baseColor = UIColor.label
        let orangeColor = UIColor.systemOrange
        let regular = UIFont.systemFont(ofSize: 17)
        let bold = UIFont.boldSystemFont(ofSize: 17)
        let mono = UIFont.monospacedSystemFont(ofSize: 17, weight: .regular)

        let base: [NSAttributedString.Key: Any] = [.font: regular, .foregroundColor: baseColor]
        let boldAttrs: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: baseColor]
        let orangeAttrs: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: orangeColor]

        let ns = text as NSString
        let pattern = #"\*\*([^*]+)\*\*|`([^`]+)`"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let ms = NSMutableAttributedString()
        var pos = 0
        for m in matches {
            if m.range.location > pos {
                ms.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), attributes: base))
            }
            // 捕获组编号：组1 = **加粗** 内容，组2 = `代码` 内容（共2组，无组3）
            let boldGroup = m.range(at: 1)
            if boldGroup.location != NSNotFound {
                ms.append(NSAttributedString(string: ns.substring(with: boldGroup), attributes: boldAttrs))
            } else {
                ms.append(NSAttributedString(string: ns.substring(with: m.range(at: 2)), attributes: orangeAttrs))
            }
            pos = m.range.location + m.range.length
        }
        if pos < ns.length {
            ms.append(NSAttributedString(string: ns.substring(with: NSRange(location: pos, length: ns.length - pos)), attributes: base))
        }
        return ms
    }

    /// 2026-11-02：气泡下方小图标按钮（统一尺寸/命中域，保证朗读·复制·撤回视觉对齐）
    private func bubbleAction(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var textBubble: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 2) {
            // v2.9.10：消息内图片缩略图（用户选择相册图片后，气泡里直接显示图片）
            if let imgs = message.imageDataURLs, !imgs.isEmpty {
                messageImageStrip(imgs)
            }
            // v2.9.20：思考记录（reasoning）可展开显示
            // v3.5.31：加 thinkEnabled —— 思考关时即使 API 返回 thinking 也一律不显示
            if !isUser, thinkEnabled, let th = message.thinking, !th.isEmpty {
                // v7.1.109-peers：思考耗时秒数传入（DeepSeek 式"已深度思考（用时 X 秒）"）
                thinkingView(th, seconds: message.thinkingSeconds)
            }
            // v3.0.2: 去掉旧的 TrailCard，改用 toolBubble 显示工具调用
            // v3.0.2e：如果 content 是空的，就不显示气泡（避免空白气泡）
            // v3.5.12 修订：解说=单独长气泡(一长)。模型"先解说后执行"的正文就作为普通 assistant 气泡
            // 显示在工具卡上方；工具卡标题=机械短标签(一短,见 toolShortLabel)，两者分开、不重复。
            // 模型本轮没写解说(content空)则无气泡，卡片标题仍显示机械短标签，不落空。
            // fix73j：子代理状态卡——[SUBAGENT-RUNNING] 执行中 / [SUBAGENT-DONE] 完成回传，
            // 均渲染为可点开的卡片（点击进入 SubAgentDetailView 看实时/完整轨迹）
            if message.role == "user", message.content.hasPrefix("[SUBAGENT-") {
                subAgentStatusCard
            } else if !message.content.isEmpty {
                // v7.1.109-peers：打字机——isStreaming 或 forceType 都按 revealedCount 逐字显示；
                // 此前只有 isStreaming 才走前缀，forceType(内容在出现前已定好、isStreaming=false)走了全文分支，
                // 导致"打字机一下有一下没有"(用户实测反馈)。修复后非流式完成的消息也逐字打出来。
                // v7.1.109-peers：已打完标记(doneTyping)的消息——即使 forceType 仍 true、revealedCount
                // 视图重建归 0，也直接渲染全文（切后台回来不重打、表格/黑底立即可见）
                // v7.1.109-peers：流式跟随网络实时渲染（大厂式：delta 到哪渲染哪，代码块/表格/
                // 链接结构到达即出现，不再字符限速）；forceType(整段到达)保留逐字打字机+结构即时化
                let typedDone = !isStreaming && Self.doneTyping(for: message.id)
                // v7.1.109-peers：ViewBuilder 不允许赋值语句（a9ac7ea 引入的
                // let shown + 三路赋值导致 CI 编译失败）→ 改声明式表达式
                let shown = isStreaming ? message.content
                    : (forceType && !typedDone ? String(message.content.prefix(revealedCount)) : message.content)
                // v4.4.11：assistant 行内代码橙色高亮, user 纯文本
                VStack(alignment: .leading, spacing: 3) {
                    // v4.4.21：完成消息用 SelectableText(UITextView) 长按划词/复制；流式打字机+用户消息用 Text(轻量)
                    messageTextView(shown)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        // v3.3.4：AI 回复气泡从左拉伸到右（全宽）；用户气泡保持靠右自适应
                        .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
                        // v2.9.93：用户气泡改巨魔蓝渐变（浅青→蓝，品牌化），助手保持系统色
                        .background(
                            Group {
                                    if isUser {
                                        LinearGradient(colors: [.tmCyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    } else if message.isError {
                                        Color.red.opacity(0.15)
                                    } else {
                                        Color(.secondarySystemBackground)
                                    }
                                }
                        )
                        .foregroundColor(isUser ? .white : .primary)
                        .cornerRadius(18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(isSelected ? (isUser ? Color.white : Color.blue) : Color.clear, lineWidth: 2)
                        )
                    // v4.4.18：朗读喇叭按钮（assistant 消息）——点一下朗读这条全文；长按仍保留选字复制
                    // v7.1.40：正在播这条时再点 = 停止（关闭声音）
                    // v7.1.43：与顶部全局开关解耦——顶部管自动朗读，气泡管手动点读（点读/再点停），互不影响
                    // 2026-11-02：气泡下方常驻操作条（用户要求"气泡下方常驻小图标"）——
                    // assistant：朗读 / 复制；user：复制 / 撤回。长按选字仍走 SelectableText 系统菜单，
                    // 两者互不抢占（本行只在气泡外部下方，不在文字层上）。
                    if !message.isTool {
                        HStack(spacing: 16) {
                            if isUser {
                                bubbleAction(icon: "doc.on.doc", tint: .secondary) {
                                    onCopy?()
                                }
                                bubbleAction(icon: "arrow.uturn.backward", tint: .secondary) {
                                    onWithdraw?()
                                }
                                Spacer(minLength: 0)
                            } else {
                                let isSpeakingThis = TTSService.shared.speakingId == message.id.uuidString
                                bubbleAction(
                                    icon: isSpeakingThis ? "speaker.wave.2.fill" : "speaker.wave.2",
                                    tint: isSpeakingThis ? .tmCyan : .secondary
                                ) {
                                    if isSpeakingThis {
                                        TTSService.shared.stop()
                                    } else {
                                        TTSService.shared.speakForced(id: message.id.uuidString, message.content)
                                    }
                                }
                                bubbleAction(icon: "doc.on.doc", tint: .secondary) {
                                    onCopy?()
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                        .padding(.bottom, 4)
                    }
                }
                .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
                // v7.1.38：自动朗读双触发——onAppear 补读（非流式/挂载前已完成的回复）+ onChange 流式增量；
                // 全局持久化朗读位置 + 5 分钟时间窗，历史消息（重开 App/切会话）不复读。
                .onAppear {
                    if message.role == "assistant", !message.isTool, TTSService.shared.speakerEnabled,
                       Date().timeIntervalSince(message.timestamp) < 300 {
                        autoSpeak(message.content, for: message.id)
                    }
                }
                .onChange(of: message.content) { newContent in
                    guard message.role == "assistant", !message.isTool, TTSService.shared.speakerEnabled else { return }
                    autoSpeak(newContent, for: message.id)
                }
            }
        }
    }

    /// v2.9.20：思考记录（reasoning）折叠视图
    private func thinkingView(_ text: String, seconds: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { toggleThinking() } }) {
                HStack(spacing: 6) {
                    Image(systemName: thinkingExpanded ? "chevron.down.circle" : "chevron.right.circle")
                        .font(.system(size: 14))
                    // v3.5.4：思考中→"思考中…"；思考完→"已深度思考 N 字"(业界一致)
                    // v7.1.109-peers：加耗时秒数（DeepSeek/元宝式"已深度思考（用时 X 秒）"）
                    // v7.2.3-fix15：字数/用时缩小灰色——主文字橙色，数字部分 caption2 灰
                    if isStreaming {
                        Text(L10n.t("i18n_1071"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                    } else if let s = seconds, s > 0 {
                        HStack(spacing: 4) {
                            Text(L10n.t("i18n_1072"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                            Text(L10n.t("i18n_1072_count", text.count))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(L10n.t("i18n_1248", Int(s.rounded())))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text(L10n.t("i18n_1072"))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                            Text(L10n.t("i18n_1072_count", text.count))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if thinkingExpanded {
                        Button(action: { UIPasteboard.general.string = text }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            if thinkingExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    /// v2.9.10：data URL → UIImage
    private func messageImageStrip(_ dataURLs: [String]) -> some View {
        let images = dataURLs.compactMap { Self.uiImage(fromDataURL: $0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 140)
                        .cornerRadius(12)
                        .clipped()
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
    }

    /// v2.9.10：data URL → UIImage（用于消息气泡图片显示）
    static func uiImage(fromDataURL s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }

    /// v3.5.16：卡片标题只显示工具名（去掉"命令符/命令"），像 Minis 步骤标签那样简洁。
    /// 具体命令/参数仍在卡片下方 args 等宽行完整显示，标题不再拼命令，避免命令符状态占据标题。
    private func toolShortLabel() -> String {
        // v7.2.3-fix19：AI 传的 tool_title 优先（5-10 字行为摘要，不带工具名，
        // 对齐 OpenMinis）；旧消息/模型未输出时 fallback 工具名
        message.toolTitle ?? message.toolName ?? L10n.t("i18n_1073")
    }

    /// v7.2.3-fix16：工具族标签（对齐三层架构：封装/原生/Alpine）——
    /// 副行小字显示"封装工具/原生工具/Alpine 工具"。
    /// 规则：shell.exec（默认 Alpine 环境）→ Alpine；原生 bin 清单 → 原生；
    /// 其余 MCP 注册工具（web.*/device.*/app.* 等带点前缀）→ 封装。
    private func toolFamilyLabel(for toolName: String?) -> String {
        guard let name = toolName, !name.isEmpty else { return L10n.t("i18n_244") }
        let nativeSet: Set<String> = ["sqlite3", "plutil", "ta", "jtool2", "py3-native",
                                      "node-native", "git.py", "nscan.py", "ldid", "insert_dylib",
                                      "optool", "ct_bypass", "opainject", "install_name_tool"]
        let packagedPrefixes = ["web.", "device.", "app.", "container.", "injection.", "location.",
                                "macro.", "knowledge.", "automation.", "model.", "reminder", "calendar",
                                "contacts", "phone", "scan.", "skills.", "project.", "build.", "rescue.",
                                "cron.", "file.", "network."]
        if name == "shell.exec" || name == "shell_exec" {
            return L10n.t("i18n_1177")      // Alpine 工具（默认 shell 环境）
        }
        if nativeSet.contains(name) {
            return L10n.t("i18n_245")       // 原生工具
        }
        if packagedPrefixes.contains(where: { name.hasPrefix($0) }) {
            return L10n.t("i18n_244")       // 封装工具
        }
        return L10n.t("i18n_244")
    }

    /// v7.2.3-fix28/fix28b：工具卡图标按工具名映射（OpenMinis 风格，覆盖全部真实工具族）
    /// 对齐 OpenMinis sfSymbol(forTool:) 表并扩展：photo/brain/bubble/lightbulb/pencil/code 等
    /// 不再落默认灰图标。AI 只传 tool_name，图标与颜色全在客户端映射（与 OpenMinis 一致）。
    /// v7.1.282-fix：统一平面图标（fill）+ 默认蓝——封装工具不再灰色扳手线条（用户指定）
    private func toolCardSymbol(_ toolName: String?) -> String {
        guard let name = toolName, !name.isEmpty else { return "wrench.and.screwdriver.fill" }
        if name == "shell.exec" || name == "shell_exec" || name == "bash" { return "terminal.fill" }
        if name.hasPrefix("web.") || name == "web_search" { return "globe" } // fix38：联网搜索用 globe（magnifyingglass 用户嫌丑）
        if name.hasPrefix("browser.") { return "safari" }
        if name.hasPrefix("knowledge.") || name.hasPrefix("skills.") || name.hasPrefix("learn.") { return "book.closed.fill" }
        if name.hasPrefix("device.") { return "iphone" }
        if name.hasPrefix("app.") { return "app.badge.fill" }
        if name.hasPrefix("inject") { return "wand.and.stars" }
        if name.hasPrefix("control.") { return "hand.tap.fill" }
        if name.hasPrefix("container.") || name.hasPrefix("package.") || name.hasPrefix("build.") { return "shippingbox.fill" }
        if name.hasPrefix("artifact.read") { return "doc.text" }
        if name.hasPrefix("artifact.write") { return "doc.text.fill" }
        if name.hasPrefix("artifact.") || name.hasPrefix("project.") { return "folder.fill" }
        if name.hasPrefix("vision.") || name == "read_image" || name == "image" { return "photo" }
        // OpenMinis delegate=person.2（子agent是人形）；thinking 才是 brain——不撞
        if name.hasPrefix("memory") { return "brain.head.profile" }
        if name.hasPrefix("subagent.") || name == "agent" || name.hasPrefix("delegate") { return "person.2.fill" }
        if name == "text" || name == "plaintext" || name.hasPrefix("model.") { return "bubble.left.fill" }
        if name == "think" || name == "thinking" { return "lightbulb.max.fill" }
        if name.hasPrefix("code") || name.hasPrefix("py3-native") || name.hasPrefix("node-native") { return "chevron.left.forwardslash.chevron.right" }
        if name.hasPrefix("network.") { return "network" }
        if name.hasPrefix("system.") || name.hasPrefix("tools.") { return "gearshape.fill" }
        if name.hasPrefix("cron.") || name.hasPrefix("reminder") || name.hasPrefix("calendar") { return "clock.fill" }
        if name.hasPrefix("location.") { return "location.fill" }
        if name.hasPrefix("rescue.") { return "cross.case.fill" }
        if name.hasPrefix("automation.") { return "play.circle.fill" }
        // v7.1.282-fix：tool_ 前缀封装工具（tool_describe 等）落蓝色平面扳手，不再是灰色线条
        if name.hasPrefix("tool_") { return "wrench.and.screwdriver.fill" }
        return "wrench.and.screwdriver.fill"
    }

    /// v7.2.3-fix28/fix28b：图标配色（同工具名映射）
    /// v7.1.282-fix：灰色兜底统一改蓝色（封装工具不再灰色；多彩语义保留给已知工具族）
    private func toolCardColor(_ toolName: String?) -> Color {
        guard let name = toolName, !name.isEmpty else { return .blue }
        if name == "shell.exec" || name == "shell_exec" || name == "bash" { return .blue }
        if name.hasPrefix("web.") || name == "web_search" { return .blue }
        if name.hasPrefix("browser.") { return .orange }
        if name.hasPrefix("knowledge.") || name.hasPrefix("skills.") || name.hasPrefix("learn.") { return .green }
        if name.hasPrefix("device.") || name.hasPrefix("network.") || name.hasPrefix("location.") { return .teal }
        if name.hasPrefix("app.") || name.hasPrefix("inject") || name.hasPrefix("control.") { return .purple }
        if name.hasPrefix("subagent.") || name == "agent" || name.hasPrefix("delegate") { return Self.agentAccent }
        if name.hasPrefix("container.") || name.hasPrefix("package.") || name.hasPrefix("build.") { return .orange }
        if name.hasPrefix("vision.") || name == "read_image" || name == "image" { return .blue }
        if name.hasPrefix("memory") { return .purple }
        if name == "text" || name == "plaintext" || name.hasPrefix("model.") { return .blue }
        if name == "think" || name == "thinking" { return .orange }
        if name.hasPrefix("code") || name.hasPrefix("py3-native") || name.hasPrefix("node-native") || name == "db" || name == "sqlite3" { return .blue }
        if name.hasPrefix("cron.") || name.hasPrefix("reminder") || name.hasPrefix("calendar") { return .pink }
        if name.hasPrefix("rescue.") { return .red }
        if name.hasPrefix("automation.") || name.hasPrefix("macro.") { return .green }
        return .blue
    }

    /// v7.2.3-fix39：副行族标签/工具名着色——shell + 所有封装工具（含 bind_app 等下划线名）
    /// 都蓝色；只有原生工具（nativeSet）灰色。
    private func toolFamilyTint(_ toolName: String?) -> Color {
        guard let name = toolName, !name.isEmpty else { return .secondary }
        let nativeSet: Set<String> = ["sqlite3", "plutil", "ta", "jtool2", "py3-native",
                                      "node-native", "git.py", "nscan.py", "ldid", "insert_dylib",
                                      "optool", "ct_bypass", "opainject", "install_name_tool"]
        return nativeSet.contains(name) ? .secondary : .blue
    }

    /// v7.2.3-fix30：子 agent/delegate 电紫 accent——OpenMinis HelperAccent 原色
    /// （亮 #734DED / 暗 #A385FF，"AI/tech"语义色，不撞红=错误、绿=成功）
    private static let agentAccent = Color(UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.64, green: 0.52, blue: 1.00, alpha: 1)
            : UIColor(red: 0.45, green: 0.30, blue: 0.93, alpha: 1)
    })

    private var toolBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 📝 1. 思考过程（独立橙色气泡）
            // v3.5.31：加 thinkEnabled —— 思考关时不显示思考气泡
            if thinkEnabled, let thinking = message.thinking, !thinking.isEmpty {
                thinkingMiniBubble(thinking)
            }

            // 🔧✅ 2. 工具调用 + 工具结果（同一个灰色大气泡）
            VStack(alignment: .leading, spacing: 6) {
                        // 工具调用胶囊（工具名 + 执行命令，边做边说可见；结果在下方展开）
                VStack(alignment: .leading, spacing: 3) {
                    // v7.2.3-fix16：主行=图标+大标题；状态徽章/耗时移到副行小字
                    HStack(spacing: 6) {
                        // v7.2.3-fix28：工具卡图标按工具族映射（对齐 OpenMinis 多彩）——
                        // 此前全部写死 terminal.fill+蓝，不同工具无法一眼区分
                        Image(systemName: toolCardSymbol(message.toolName))
                            .font(.system(size: 13))
                            .foregroundColor(toolCardColor(message.toolName))
                        // v3.5.13：卡片标题=机械短标签(一短,像Minis)——从工具名+关键参数提炼(如
                        // "shell.exec: ls -la" / "browser: dnf.qq.com")，简短稳定、次次一致，客观陈述跑了哪个
                        // 工具干了什么，不代表模型说话；真正的解说由单独的 assistant 气泡(一长)承载。
                        Text(toolShortLabel())
                            .font(.subheadline)
                            .fontWeight(.medium)
                            // v7.2.3-fix17：主标题日间黑/夜间白（自适应），不再固定蓝
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .layoutPriority(1)
                        Spacer()
                    }
                    // v7.2.3-fix23：点击标题区展开/收起参数（渲染传参默认隐藏后的入口）
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if argsExpanded {
                                argsExpanded = false
                            } else {
                                argsExpanded = true
                            }
                        }
                    }
                    // v7.2.3-fix16：副行小字（括号信息）——工具族·工具名·状态·耗时
                    HStack(spacing: 5) {
                        // v7.2.3-fix28：副行字号 10→12；Alpine 工具族标签+工具名蓝色（用户要求）
                        Text(toolFamilyLabel(for: message.toolName))
                            .foregroundColor(toolFamilyTint(message.toolName))
                        if let tn = message.toolName, !tn.isEmpty {
                            Text(tn)
                                .foregroundColor(toolFamilyTint(message.toolName))
                                .textSelection(.enabled)
                        }
                        // v3.5.7：工具状态徽章（机制级：由真实执行结果渲染）——移到副行缩小
                        if message.isRunning {
                            ProgressView().scaleEffect(0.55)
                            Text(L10n.t("ui_64")).foregroundColor(.blue)
                        } else {
                            Text(message.isError ? L10n.t("i18n_1074") : L10n.t("i18n_1075"))
                                .foregroundColor(message.isError ? .red : .green)
                        }
                        // v3.3.4：工具执行耗时
                        if let dur = message.toolDuration {
                            Text(String(format: "%.1fs", dur))
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    // v3.5.13：标题已是"工具名: 关键参数"机械短标签，无需再补一行副标题工具名。
                    // v7.2.3-fix23：渲染传参提示词默认完全隐藏（对齐用户诉求——标题已说明
                    // 意图、显示的命令 AI 不一定真执行，界面渲染多余）。点击卡片标题区
                    // 切换展开/收起完整命令/参数。
                    if let args = message.toolArgs, !args.isEmpty {
                        if argsExpanded {
                            HStack(alignment: .top, spacing: 4) {
                                Text(args)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(nil)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.up")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 2)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    argsExpanded = false
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

                // 工具结果（可折叠）
                toolResultMiniBubble
            }
            .padding(10)
            // v3.1.66：修复"工具气泡浅色模式不显示"——tertiarySystemBackground 在浅色模式≈纯白，
            // 与聊天背景融为一体；改用 secondarySystemBackground（与 AI 回复气泡同色，浅色=浅灰白/深色=深灰）
            .background(Color(.secondarySystemBackground))
            .cornerRadius(10)
        }
    }

    // 📝 思考过程迷你气泡
    private func thinkingMiniBubble(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { toggleThinking() } }) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    // v7.2.3-fix15：字数缩小灰色（与思考气泡一致）
                    HStack(spacing: 4) {
                        Text(isStreaming ? L10n.t("i18n_1071") : L10n.t("i18n_1072"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                        if !isStreaming {
                            Text(L10n.t("i18n_1072_count", text.count))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if thinkingExpanded {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
            }
        }
    }

    // ✅ 工具结果迷你气泡
    private var toolResultMiniBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { withAnimation { if !message.isRunning { expanded.toggle() } } }) {
                HStack(spacing: 6) {
                    if message.isRunning {
                        // v4.3.75：有活动安装任务 → 迷你气泡显示实时进度（阶段+包数+最近行）
                        if let prog = installRegistry.active, prog.ok == nil {
                            VStack(alignment: .leading, spacing: 2) {
                                ProgressView(value: prog.fraction)
                                    .progressViewStyle(.linear)
                                    .frame(width: 130)
                                Text(prog.progressText)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                                if !prog.lastLine.isEmpty {
                                    Text(prog.lastLine)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 160, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.8)
                                Text(L10n.t("i18n_1076"))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        // v7.2.3-fix38：成功态回蓝色（用户要求；fix30 改绿被否），错误态仍红
                        Image(systemName: message.isError ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.system(size: 14))
                            .foregroundColor(message.isError ? .red : .blue)
                        Text(expanded ? L10n.t("i18n_1077") : L10n.t("i18n_1078"))
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(message.isError ? .red : .blue)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            // v3.5.10：执行中不展示结果区（content 为空）
            if !message.isRunning && expanded {
                // v7.2.3-fix3：JSON 结果 → 缩进+头键着色；否则等宽纯文本
                // v7.2.3-fix11：纯文本先剥 ANSI（乱码根因）
                // v7.2.3-fix13：tab 展开到 8 列（空格对齐根因）
                Group {
                    if let json = Self.jsonHighlighted(from: message.content) {
                        Text(json)
                    } else {
                        Text(Self.terminalStyled(Self.expandTabs(Self.sanitizeForDisplay(message.content))))
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )

                // v3.1.6: 工具结果里的文件 → 可点击卡片
                let files = FilePathExtractor.extractFiles(from: message.content)
                if !files.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(files, id: \.self) { url in
                            FileCardRow(url: url)
                        }
                    }
                }
                // v7.1.109-minis：工具结果里的链接 → 链接卡（URL / minis://open?url= 标记）
                // 对齐 Minis：shell stdout 带 OSC minis-open 标记时 UI 渲染打开入口
                let links = LinkExtractor.extractLinks(from: message.content)
                if !links.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(links, id: \.self) { LinkCardView(url: $0) }
                    }
                }
            }
        }
    }
}

// v3.1.6: 聊天里的文件卡片 —— 点了直接 QuickLook 预览
struct FileCardRow: View {
    let url: URL
    @State private var showPreview = false

    private var fileName: String { url.lastPathComponent }
    private var ext: String { (fileName as NSString).pathExtension.lowercased() }
    private var isImage: Bool { ["png","jpg","jpeg","gif","webp","heic"].contains(ext) }

    private var iconName: String {
        if isImage { return "photo" }
        switch ext {
        case "ipa","tipa": return "shippingbox"
        case "deb","zip","tar","gz": return "archivebox"
        case "dylib","framework": return "hammer"
        case "plist","json": return "doc.text"
        case "pdf": return "doc.richtext"
        case "swift","h","m","c","cpp": return "chevron.left.slash.chevron.right"
        default: return "doc"
        }
    }

    private var sizeText: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "" }
        if size > 1024*1024 { return String(format: "%.1f MB", Double(size)/1024/1024) }
        if size > 1024 { return String(format: "%.0f KB", Double(size)/1024) }
        return "\(size) B"
    }

    @ViewBuilder
    var body: some View {
        // v7.1.109-minis：图片文件直显缩略图（对齐 Minis ZoomableImageView——工具结果/正文里的
        // 图片路径不再只显示图标行，直接渲染图；点击 QuickLook 放大）
        if isImage, let img = UIImage(contentsOfFile: url.path) {
            Button(action: { showPreview = true }) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 200)
                        .cornerRadius(8)
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundColor(.tmCyan)
                        Text(fileName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(sizeText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.systemGray5))
                .cornerRadius(10)
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                SharePresenter.menuShare(url: url)
            }
            .sheet(isPresented: $showPreview) {
                QLFilePreview(urls: [url])
            }
        } else {
        Button(action: { showPreview = true }) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.tmCyan.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: iconName)
                        .font(.system(size: 16))
                        .foregroundColor(.tmCyan)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(fileName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // v7.1.109-peers：文件解析状态卡（元宝式）——已解析绿勾徽标
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                    Text(sizeText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundColor(.tmCyan)
            }
            .padding(10)
            // v3.1.66：同 toolBubble——tertiarySystemBackground 浅色模式≈白色看不见，改 systemGray5
            .background(Color(.systemGray5))
            .cornerRadius(10)
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            SharePresenter.menuShare(url: url)
            // v4.3.46：用 TrollStore 安装 → 打开方式（UIDocumentInteractionController）。
            // TrollStore 注册了 .tipa/.ipa 的打开方式，不经过 ShareSheet（系统分享面板
            // 在本设备侧载环境 MobileIcons/CoreImage SIGSEGV，任何路径都崩）。
            // v4.3.51：URL scheme 直调 TrollStore 安装（不渲染 App 图标列表，安全）
            if ext == "tipa" || ext == "ipa" {
                Button(action: { ShareCenter.shared.openInTrollStore(url) }) {
                    Label(L10n.t("i18n_1079"), systemImage: "shippingbox")
                }
            }
        }
        .sheet(isPresented: $showPreview) {
            QLFilePreview(urls: [url])
        }
        }
    }
}

struct TypingIndicator: View {
    @State private var offset: CGFloat = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundColor(.secondary)
                    .offset(y: offset)
                    .animation(Animation.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.15), value: offset)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(18)
        .onAppear { offset = -4 }
    }
}

// MARK: - v2.9.127 执行轨迹组件（豆包工作任务/Codex 式过程流）

/// 实时轨迹卡片：请求进行中，在"正在思考"下方竖排显示步骤流
struct LiveTrailCard: View {
    let steps: [TrailStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // v7.1.109-peers：Manus 式任务计数——N/M（完成/总步骤），三态一眼可见
            let done = steps.filter { $0.status == .success }.count
            HStack(spacing: 6) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
                Text(L10n.t("i18n_1249", done, steps.count))
                    .font(.caption.weight(.medium))
                    .foregroundColor(.blue)
                Spacer()
            }
            ForEach(steps) { step in
                TrailRow(step: step)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // v3.1.66：同 toolBubble——tertiarySystemBackground 浅色模式≈白色看不见，改 systemGray5
        .background(Color(.systemGray5).opacity(0.85))
        .cornerRadius(12)
    }
}

/// 历史轨迹卡片：assistant 消息气泡内，可折叠展开执行全过程
struct TrailCard: View {
    let steps: [TrailStep]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { withAnimation { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down.circle" : "chevron.right.circle")
                        .font(.system(size: 13))
                    Text(L10n.t("ui_158", steps.count))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.blue)
                    Spacer()
                    Text(summaryText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(steps) { step in
                        TrailRow(step: step)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.06))
        .cornerRadius(12)
    }

    private var summaryText: String {
        let ok = steps.filter { $0.status == .success }.count
        let fail = steps.filter { $0.status == .failed }.count
        if fail > 0 { return "✅\(ok) ❌\(fail)" }
        return L10n.t("i18n_1080", ok)
    }
}

/// 单步行：图标 + 名称 + 状态色 + 可展开 detail
struct TrailRow: View {
    let step: TrailStep
    @State private var detailExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconFor)
                .font(.system(size: 12))
                .foregroundColor(colorFor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                    .font(.caption)
                    .fontWeight(step.status == .running ? .medium : .regular)
                    .foregroundColor(step.status == .running ? .primary : (step.status == .failed ? .red : .primary))
                    .lineLimit(1)
                if step.status == .running {
                    Text(L10n.t("ui_64"))
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else if !step.detail.isEmpty {
                    if detailExpanded {
                        Text(step.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(6)
                            .onTapGesture { detailExpanded = false }
                    } else {
                        Text(step.detail)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .onTapGesture { detailExpanded = true }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var iconFor: String {
        switch step.kind {
        case .think: return "brain"
        case .tool: return "wrench.and.screwdriver.fill"   // v7.1.282-fix：平面图标
        case .result: return step.status == .failed ? "xmark.circle.fill" : "checkmark.circle.fill"
        case .note: return "flag"
        }
    }

    private var colorFor: Color {
        switch step.status {
        case .running: return .blue
        case .success: return .blue
        case .failed: return .red
        }
    }
}

// MARK: - v2.9.234 输入框：UITextView 包装(检测 markedText，修复"没打完自动回车")
// SwiftUI TextField 读不到输入法 markedText(拼音未上屏)，iOS16+第三方输入法组合下
// 按回车会直接 submit → 发出去一串拼音。UITextView delegate 可读 markedTextRange：
// 组词中按回车=上屏候选词(return true)，无组词按回车=发送(return false)。

struct ChatInputTextView: UIViewRepresentable {
    @Binding var text: String
    var onSend: () -> Void
    @Binding var height: CGFloat

    func makeUIView(context: Context) -> RSKGrowingTextView {
        let tv = RSKGrowingTextView()
        tv.backgroundColor = .clear
        tv.font = .systemFont(ofSize: 16)
        tv.textColor = UIColor.label
        tv.placeholder = L10n.t("input_placeholder") as NSString
        tv.placeholderColor = .gray
        tv.minimumNumberOfLines = 1
        tv.maximumNumberOfLines = 4
        tv.delegate = context.coordinator
        return tv
    }

    func updateUIView(_ uiView: RSKGrowingTextView, context: Context) {
        uiView.text = text
        height = uiView.intrinsicContentSize.height
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, RSKGrowingTextViewDelegate {
        var parent: ChatInputTextView
        init(_ p: ChatInputTextView) { parent = p }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.height = textView.intrinsicContentSize.height
        }
    }
}

// MARK: - v3.1.67：UIKit 文档选择器 delegate（真机稳定，替代 .fileImporter）

final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    static var assocKey = "DocumentPickerCoordinatorKey"
    let onPick: ([URL]) -> Void

    init(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // 用户取消，无操作
    }
}
