import SwiftUI
// UIPasteboard（复制公网地址）在 UIKit 里；SwiftUI 会间接带入，
// 但显式引入更稳（换 Swift 版本时传递关系可能变，项目里有过先例）
import UIKit

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
    @State private var foundHost: String?

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
                // 进页面就把设备状态和公网地址拉一遍，不等用户点
                refreshDevice()
                refreshPublicAddress()
                startAutoRefresh()
            }
            .onDisappear {
                refreshTimer?.invalidate()
                refreshTimer = nil
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

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: foundHost == nil ? "wifi.router" : "wifi.router.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(foundHost == nil ? .secondary : .blue)
                    .frame(width: 40, height: 40)
                    .background((foundHost == nil ? Color.secondary : Color.blue).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    // 标题：优先显示设备实际地址
                    Text(foundHost ?? L10n.t("i18n_1536"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 在线状态：绿点 = 在线，灰点 = 未连上
                    HStack(spacing: 5) {
                        Circle()
                            .fill(device != nil ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(device != nil ? "在线" : (deviceError.isEmpty ? "检测中…" : "未连上"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    refreshDevice()
                } label: {
                    if deviceLoading {
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
                .disabled(deviceLoading)
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
        Task {
            let host = await findHost()
            await MainActor.run {
                foundHost = host
                refreshDevice()
            }
        }
    }

    private func findHost() async -> String? {
        await RouterControl.discover(candidates: RouterControl.lanCandidates())
    }

    /// 每 20 秒自动刷设备状态——用户要的是「打开就能看到真实状态」，
    /// 不是「打开一片空白，等你自己点刷新」。
    private func startAutoRefresh() {
        refreshTimer?.invalidate()
        let t = Timer(timeInterval: 20, repeats: true) { _ in
            refreshDevice(silent: true)
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func refreshDevice(silent: Bool = false) {
        guard !deviceLoading else { return }
        deviceLoading = true
        if !silent { deviceError = "" }

        // 优先用已探测到的地址；没有就用后台里存的地址
        let base = foundHost ?? RelayAdminCredential.shared.baseURL
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
        let base = foundHost ?? RelayAdminCredential.shared.baseURL

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

        let host = await RouterControl.discover(candidates: RouterControl.lanCandidates())

        guard let target = host else {
            await MainActor.run {
                busy = false
                statusIsError = true
                statusLine = L10n.t("i18n_1555")
            }
            return
        }

        await MainActor.run { foundHost = target }

        do {
            switch action {
            case .relay:
                try await RouterControl.restartRelay(host: target, key: key)
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
                try await RouterControl.reboot(host: target, key: key)
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
                statusLine = e.errorDescription ?? L10n.t("i18n_1560")
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
                statusLine = L10n.t("i18n_1561", error.localizedDescription)
            }
        }
    }
}
