// TimeInterval / URLError 来自 Foundation；SwiftUI 会间接带入，
// 但显式引入更稳（本文件用了 URLError.timedOut 判超时）
import Foundation
import SwiftUI
// UIPasteboard（复制公网地址）在 UIKit 里；SwiftUI 会间接带入，
// 但显式引入更稳（换 Swift 版本时传递关系可能变，项目里有过先例）
import UIKit
// NWPathMonitor：网络变化（WiFi↔蜂窝）要**立刻**重探地址，不能等 20 秒的定时器
import Network

/// 路由器控制面板（2026-11-02 新增，2026-11-03 大改）。
///
/// 改版原因（用户截图反馈「这个界面你没有把我需要的添加进来」）：
/// 原来整页只有「一个地址 + 一个密码框 + 两个重启按钮」，
/// 用户真正想看的**设备状态**和**公网地址**一个都没有。
///
/// 现在页面从上到下是：
///   ① 设备状态卡 —— 在线/离线、运行时长、内存、负载（来自 /admin/api/device）
///   ② 公网地址卡 —— 从 Gist 自动取最新地址，点一下就刷新（用户明确要求的）
///   ③ 后台密钥 —— 小眼睛 + 确定/取消 + 验证成功失败样式
///   ④ 两个动作 —— 中转站重启（蓝）/ 路由器重启（红）
///
/// 按钮颜色按用户最终确认：「一个蓝色一个红色」——中转站蓝、路由器红。
struct RouterControlView: View {
    @Environment(\.dismiss) private var dismiss

    /// 后台密钥——复用中转站后台已保存的那把，用户不必再输一遍
    @State private var accessKey: String = ""
    @State private var keyLoaded = false

    @State private var busy = false
    @State private var statusLine: String = ""
    @State private var statusIsError = false
    @State private var confirmAction: RouterAction?

    /// 2026-11-04：当前线路。替掉原来的 foundHost —— 那个变量只有一个裸 IP，
    /// 同时喂给 airboot(80) 和后台接口(8080)，必然有一个连不上。
    @State private var route: RouterControl.Route?
    /// 正在重新判定线路（界面上显示「正在检测…」）
    @State private var detecting = false
    /// 网络变化监听
    @State private var pathMonitor: NWPathMonitor?
    /// 上一次的网络指纹，用来判断「是不是真的换网了」
    @State private var lastNetSig: String = ""

    /// 重启中转站后等它起来的倒计时提示
    @State private var waitingBack = false

    // MARK: 新增状态（2026-11-03）
    @State private var revealKey = false
    /// 密钥校验结果：nil 未校验 / true 通过 / false 失败
    @State private var keyCheckOK: Bool? = nil
    @State private var keyChecking = false
    /// 设备状态
    @State private var device: RelayDeviceStatus? = nil
    @State private var deviceLoading = false
    @State private var deviceError: String = ""
    /// 公网地址（来自 Gist）
    @State private var publicAddr: RelayPublicAddress? = nil
    @State private var publicLoading = false
    @State private var publicError: String = ""
    /// 设备状态自动刷新
    @State private var refreshTimer: Timer? = nil

    private enum RouterAction: String, Identifiable {
        case relay, reboot
        var id: String { rawValue }

        var title: String {
            switch self {
            case .relay:  return L10n.t("i18n_1540")
            case .reboot: return L10n.t("i18n_1541")
            }
        }
        var icon: String {
            switch self {
            case .relay:  return "arrow.clockwise.circle"
            case .reboot: return "power"
            }
        }
        var detail: String {
            switch self {
            case .relay:  return L10n.t("i18n_1542")
            case .reboot: return L10n.t("i18n_1543")
            }
        }
        /// 用户最终确认：「路由器重启」用红色警示可以，「这个」改成蓝色 → 一蓝一红
        var tint: Color {
            switch self {
            case .relay:  return .blue
            case .reboot: return .red
            }
        }
    }

    var body: some View {
        CompatNav {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        deviceCard
                        publicAddressCard
                        keyCard
                        actionCard(.relay)
                        actionCard(.reboot)
                        if !statusLine.isEmpty {
                            statusCard
                        }
                        footnote
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
            }
            .navigationTitle(L10n.t("i18n_1535"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("i18n_1512")) { dismiss() }
                }
            }
            .onAppear {
                loadKey()
                // 进页面就把线路、设备状态、公网地址都拉一遍，不等用户点
                Task { await detectRoute(force: true) }
                refreshPublicAddress()
                startAutoRefresh()
                startNetworkMonitor()
            }
            .onDisappear {
                refreshTimer?.invalidate()
                refreshTimer = nil
                stopNetworkMonitor()
            }
            // 二次确认：两条路径都走同一个 dialog，标题/描述/按钮颜色由当前动作决定。
            .confirmationDialog(
                confirmAction?.title ?? L10n.t("i18n_1535"),
                isPresented: Binding(
                    get: { confirmAction != nil },
                    set: { if !$0 { confirmAction = nil } }
                ),
                titleVisibility: .visible,
                presenting: confirmAction
            ) { action in
                Button(action.title, role: action == .reboot ? .destructive : nil) {
                    let a = action
                    confirmAction = nil
                    Task { await run(a) }
                }
                Button(L10n.t("i18n_1537"), role: .cancel) { confirmAction = nil }
            } message: { action in
                Text(action.detail)
            }
        }
    }

    // MARK: - 设备状态卡

    private var routeIcon: String {
        guard let r = route else { return "wifi.router" }
        switch r.kind {
        case .lan: return "wifi.router.fill"
        case .wan: return "globe.asia.australia.fill"
        }
    }

    private var routeTint: Color {
        guard let r = route else { return .secondary }
        switch r.kind {
        case .lan: return .blue
        case .wan: return .orange
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: routeIcon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(routeTint)
                    .frame(width: 40, height: 40)
                    .background(routeTint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    // 标题：当前线路的实际地址（内网 IP / 域名）
                    Text(route?.detail ?? L10n.t("i18n_1536"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 在线状态 + 现在走哪条线
                    HStack(spacing: 5) {
                        Circle()
                            .fill(device != nil ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(detecting ? "检测中…"
                             : (device != nil ? (route?.label ?? "在线")
                                : (deviceError.isEmpty ? "检测中…" : "未连上")))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // 线路类型后面跟一句走法（WiFi 直连 / 走域名）
                        if let r = route, device != nil, !r.channelText.isEmpty {
                            Text("· \(r.channelText)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button {
                    // 手动刷新 = 重新判定线路 + 重拉状态（关掉 WiFi 后点它也能立刻切到域名）
                    Task { await detectRoute(force: true) }
                } label: {
                    if deviceLoading || detecting {
                        ProgressView().scaleEffect(0.7)
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(deviceLoading || detecting)
            }

            if let d = device {
                Divider().opacity(0.5)
                // 两列小格子：运行时长 / 内存 / 负载 / 中转站占用
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    metricTile("已运行", d.uptimeText, icon: "clock")
                    metricTile("可用内存", d.memAvailText, icon: "memorychip",
                               warn: d.memLow)
                    metricTile("负载", d.loadText, icon: "gauge",
                               warn: d.loadHigh)
                    metricTile("中转站进程", d.relayRssText, icon: "server.rack")
                }
                if d.swapHigh {
                    InlineResultBanner(kind: .failure,
                                       text: "交换内存已用到 \(Int(d.swapUsedPct))%，设备很吃力。建议点下面的「中转站重启」释放一下。")
                }
            } else if !deviceError.isEmpty {
                InlineResultBanner(kind: .failure, text: deviceError)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private func metricTile(_ title: String, _ value: String,
                            icon: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(warn ? .orange : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - 公网地址卡

    private var publicAddressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue)
                Text("公网地址")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button {
                    refreshPublicAddress(force: true)
                } label: {
                    if publicLoading {
                        ProgressView().scaleEffect(0.6)
                            .frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(publicLoading)
            }

            if let p = publicAddr {
                VStack(alignment: .leading, spacing: 6) {
                    // 有域名就显示域名，没有就显示 IPv6 直连地址
                    Text(p.bestAddress)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text("更新于 \(p.updatedText)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if !p.ipv6.isEmpty {
                            Text("· 含 IPv6")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = p.bestAddress
                            statusIsError = false
                            statusLine = "公网地址已复制"
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9))
                                Text("复制")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if !publicError.isEmpty {
                InlineResultBanner(kind: .failure, text: publicError)
            } else {
                Text("正在从 Gist 获取最新公网地址…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("设备每 3 分钟自动把当前位置写到 Gist，这里打开就会取最新值，不用手动点测试。")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    // MARK: - 密钥卡（小眼睛 + 确定取消 + 结果样式）

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.t("i18n_1539"))
                    .font(.caption)
            }
            .foregroundColor(.secondary)

            SecretInputField(
                text: $accessKey,
                revealed: $revealKey,
                placeholder: L10n.t("i18n_1515"))

            // 用户要求：输完要有确定和取消，点确定要看到成功/失败
            ConfirmCancelRow(
                confirmTitle: "确定",
                cancelTitle: "取消",
                canConfirm: !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                busy: keyChecking,
                onConfirm: verifyKey,
                onCancel: {
                    // 取消 = 回到已保存的那把密钥，不动用户的既有配置
                    accessKey = RelayAdminCredential.shared.loadAccessKey() ?? ""
                    revealKey = false
                    keyCheckOK = nil
                })

            if keyChecking {
                InlineResultBanner(kind: .info, text: "正在验证密钥…")
            } else if let ok = keyCheckOK {
                if ok {
                    InlineResultBanner(kind: .success, text: "密钥有效，可以执行下面的操作")
                } else {
                    InlineResultBanner(kind: .failure, text: "密钥无效，后台拒绝了这次请求。请核对后重填。")
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private func actionCard(_ action: RouterAction) -> some View {
        Button {
            guard !busy, !waitingBack else { return }
            guard !accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusLine = L10n.t("i18n_1551")
                statusIsError = true
                keyLoaded = false
                return
            }
            confirmAction = action
        } label: {
            HStack(spacing: 12) {
                Image(systemName: action.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(action.tint)
                    .frame(width: 40, height: 40)
                    .background(action.tint.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                        // 用户要求「和原版一样」：标题用动作自身的颜色（蓝/红），
                        // 不写死 primary——原来两行都是黑字，看不出危险度差异。
                        .foregroundColor(action.tint)
                    Text(action.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if busy || waitingBack {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
        .disabled(busy || waitingBack)
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(statusIsError ? .orange : .blue)
                .padding(.top, 1)
            Text(statusLine)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var footnote: some View {
        Text(L10n.t("i18n_1552"))
            .font(.caption2)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 4)
    }

    // MARK: - 逻辑

    private func loadKey() {
        if let saved = RelayAdminCredential.shared.loadAccessKey(), !saved.isEmpty {
            accessKey = saved
            keyLoaded = true
        }
    }

    /// 判定线路 → 再拉设备状态。
    ///
    /// **页面里唯一「找地址」的入口**：进页面、手动点刷新、网络变化、20 秒兜底检查都调它。
    /// 老代码只有进页面时探一次（`loadKey` 里），之后再也不探 ——
    /// 所以「停留期间关掉 WiFi」永远是旧 IP，必然连不上。
    @MainActor
    private func detectRoute(force: Bool = false) async {
        if detecting { return }
        detecting = true
        // 把当前线路传进去做「粘性」：它还能用就别换地址，
        // 否则 .88 / .250 会每次刷新随机跳（1.0.21 用户实测）。
        // 但网络指纹变了（关了 WiFi / 连到别人家的网）就**不做粘性**——
        // 上一条线路必然不通，还去 ping 它一下纯属白等 0.9 秒。
        let sameNet = (RouterControl.netSignature() == lastNetSig)
        let r = await RouterControl.resolveRoute(preferring: sameNet ? route : nil)
        detecting = false
        lastNetSig = RouterControl.netSignature()
        let changed = (route?.adminBase != r.adminBase) || (route?.bootBase != r.bootBase)
        route = r
        if changed {
            // 换了线路，上一台的数字就不能继续摆在界面上。
            // 老代码保留旧 device，于是「已经切到域名/ZT 了，卡片还是绿的、还是 55 分钟」，
            // 看着像在线，其实是上个网络的残留。
            device = nil
            deviceError = ""
        }
        // 地址变了、或者用户手动点刷新 → 重拉一次状态
        if changed || force {
            refreshDevice()
        }
    }

    /// 监听网络变化（WiFi ↔ 蜂窝）。用户明确要求：
    /// 「在界面停留期间关闭 wifi 他要自动检测到」。
    private func startNetworkMonitor() {
        stopNetworkMonitor()
        let m = NWPathMonitor()
        m.pathUpdateHandler = { _ in
            // 系统回调时链路刚变，DHCP 拿到新 IP 还要几百毫秒；
            // 延迟 0.8 秒再读网卡列表，避免读到「已断开、还没连上」的中间态。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let sig = RouterControl.netSignature()
                guard sig != lastNetSig else { return }
                Task { await detectRoute(force: true) }
            }
        }
        m.start(queue: DispatchQueue(label: "router.path.monitor"))
        pathMonitor = m
    }

    private func stopNetworkMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// 每 20 秒自动刷设备状态——用户要的是「打开就能看到真实状态」，
    /// 不是「打开一片空白，等你自己点刷新」。
    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 20, repeats: true) { _ in
            // 兜底：NWPathMonitor 在个别机型/越狱环境下会漏回调，
            // 这里每 20 秒顺手比一次网络指纹，变了就重探地址。
            let sig = RouterControl.netSignature()
            if sig != lastNetSig {
                Task { await detectRoute(force: true) }
            } else {
                refreshDevice(silent: true)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func refreshDevice(silent: Bool = false) {
        guard !deviceLoading else { return }
        deviceLoading = true
        if !silent { deviceError = "" }

        // 2026-11-04 关键修正：设备状态必须走 **8080/域名** 那条线。
        //   老代码用 foundHost（裸 IP，不带端口）→ http://192.168.1.88/admin/api/device
        //   → 打到 uhttpd 的 80 → 404 → 状态卡永远「未连上」。
        let base = route?.adminBase ?? RelayAdminCredential.shared.baseURL
        let key = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)

        RelayBackend.fetchDeviceStatus(base: base, key: key) { result in
            deviceLoading = false
            switch result {
            case .success(let d):
                device = d
                deviceError = ""
            case .failure(let err):
                // 静默刷新失败时不覆盖上一次的好数据，避免状态卡闪来闪去
                if !silent || device == nil { deviceError = err.message }
            }
        }
    }

    private func refreshPublicAddress(force: Bool = false) {
        if publicLoading { return }
        publicLoading = true
        if force { publicError = "" }
        RelayBackend.fetchPublicAddress { result in
            publicLoading = false
            switch result {
            case .success(let p):
                publicAddr = p
                publicError = ""
            case .failure(let err):
                if publicAddr == nil { publicError = err.message }
            }
        }
    }

    /// 真打一次后台接口验证密钥——不能只看格式对不对
    private func verifyKey() {
        let key = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyChecking = true
        keyCheckOK = nil
        let base = route?.adminBase ?? RelayAdminCredential.shared.baseURL

        RelayBackend.fetchDeviceStatus(base: base, key: key) { result in
            keyChecking = false
            switch result {
            case .success:
                keyCheckOK = true
                // 验证通过就记住，省得下次再输
                RelayAdminCredential.shared.save(accessKey: key)
                keyLoaded = true
            case .failure:
                keyCheckOK = false
            }
        }
    }

    private func run(_ action: RouterAction) async {
        let key = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            await MainActor.run {
                statusLine = L10n.t("i18n_1551")
                statusIsError = true
                keyLoaded = false
            }
            return
        }
        await MainActor.run {
            busy = true
            statusIsError = false
            statusLine = L10n.t("i18n_1553")
        }

        // 动手前先确认线路是新的（可能刚关了 WiFi / 刚到家）
        var r = route
        if r == nil {
            let fresh = await RouterControl.resolveRoute()
            await MainActor.run {
                route = fresh
                lastNetSig = RouterControl.netSignature()
            }
            r = fresh
        }
        guard let target = r else {
            await MainActor.run {
                busy = false
                statusIsError = true
                statusLine = L10n.t("i18n_1555")
            }
            return
        }

        // 超时给多少：实测（2026-11-04）在家几十毫秒，
        // 外网走隧道到路由器 80 端口单次往返 5～6 秒，校密钥那次 10.8 秒。
        // 原来固定 8 秒，外网会把「已经发出去的指令」误报成失败。
        let tmo: TimeInterval = target.isLan ? 8 : 25

        do {
            switch action {
            case .relay:
                // 重启中转站服务走 airboot（80 端口）。
                // 隧道已经把 /cgi-bin/airboot 单独转发到路由器 80 端口，
                // 所以在家、在外都是直发路由器，不用中转站活着。
                try await RouterControl.restartRelay(host: target.bootBase, key: key, timeout: tmo)
                await MainActor.run {
                    statusLine = L10n.t("i18n_1556")
                    waitingBack = true
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await MainActor.run {
                    waitingBack = false
                    busy = false
                    statusLine = L10n.t("i18n_1557")
                    // 重启完立刻重拉一次状态，让用户看到内存释放的效果
                    refreshDevice(silent: true)
                }

            case .reboot:
                // 内网、外网都直发路由器 80 端口的 airboot：
                //   在家 → http://<路由器 IP>/cgi-bin/airboot
                //   在外 → https://<域名>/cgi-bin/airboot（隧道里单独转了这条到 80）
                // 两条都不经过中转站，所以中转站卡死/没起来也照样能重启路由器。
                try await RouterControl.reboot(host: target.bootBase, key: key, timeout: tmo)
                await MainActor.run {
                    statusLine = L10n.t("i18n_1558")
                    waitingBack = true
                }
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                await MainActor.run {
                    waitingBack = false
                    busy = false
                    statusLine = L10n.t("i18n_1559")
                    refreshDevice(silent: true)
                }
            }
        } catch let e as RouterError {
            await MainActor.run {
                busy = false
                waitingBack = false
                statusIsError = true
                var msg = e.errorDescription ?? L10n.t("i18n_1560")
                // 外网走域名时 404：说明隧道里 /cgi-bin/airboot 那条转发没生效，
                // 请求落到了 relay.py 上（它不认识这个路径）。这句比「HTTP 404」有用。
                if target.kind == .wan, case .http(404) = e {
                    msg = "外网通道返回 404：隧道里 /cgi-bin/airboot → 路由器 80 端口的转发规则没生效，"
                        + "去 Cloudflare 检查那条 Public Hostname。"
                }
                statusLine = msg
                if case .noKey = e { keyLoaded = false }
                if case .badKey = e {
                    keyLoaded = false
                    keyCheckOK = false
                }
            }
        } catch {
            await MainActor.run {
                busy = false
                waitingBack = false
                statusIsError = true
                // 外网超时 ≠ 没执行：指令可能已经到了路由器，只是回话慢
                // （隧道往返实测 5～6 秒）。这时说「失败」会让人重复点。
                if target.kind == .wan, (error as? URLError)?.code == .timedOut {
                    statusLine = "外网通道没等到回话（隧道较慢）。指令可能已经发到路由器了，"
                        + "等 40 秒左右点刷新看状态。"
                } else {
                    statusLine = L10n.t("i18n_1561", error.localizedDescription)
                }
            }
        }
    }
}
