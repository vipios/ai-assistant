import SwiftUI

/// 路由器控制面板（2026-11-02 新增，入口在输入框右侧「+」的附件栏）。
///
/// 三个动作，代价差三个数量级，所以按危险度从上到下排：
///   · 重启中转站 —— 1 秒恢复，只影响 AI 后台，家里其它人无感
///   · 重启路由器 —— 全家断网约 40 秒，最后手段
/// 每个动作都要二次确认，且必须填后台密钥（就是打开网页后台时输的那串）。
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
        /// 重启路由器更危险，用红色
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
                        headerCard
                        if !keyLoaded {
                            keyCard
                        }
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
            .onAppear(perform: loadKey)
            // 二次确认：两条路径都走同一个 dialog，标题/描述/按钮颜色由当前动作决定。
            // 用 presenting 把动作一起带进闭包，避免在点击时再读可能已被清空的 @State。
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

    // MARK: - 卡片

    private var headerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: foundHost == nil ? "wifi.router" : "wifi.router.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(.blue)
                .frame(width: 46, height: 46)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(foundHost ?? L10n.t("i18n_1536"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(L10n.t("i18n_1538"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("i18n_1539"))
                .font(.caption)
                .foregroundColor(.secondary)
            SecureField(L10n.t("i18n_1515"), text: $accessKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)
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
                        .foregroundColor(.primary)
                    Text(action.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // 等待设备恢复期间显示转圈并锁住按钮——避免用户连点导致重复重启
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

    /// 优先复用中转站后台已保存的那把密钥（用户此前输过一次就够）
    private func loadKey() {
        if let saved = RelayAdminCredential.shared.loadAccessKey(), !saved.isEmpty {
            accessKey = saved
            keyLoaded = true
        }
        Task {
            // 预热：顺手探一下路由器在不在，让页面一打开就能看出「在家/不在家」
            let host = await findHost()
            await MainActor.run {
                foundHost = host
            }
        }
    }

    private func findHost() async -> String? {
        await RouterControl.discover(candidates: RouterControl.lanCandidates())
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

        // 找路由器：内网优先（并发探测，最坏 1.2 秒）。
        // 这里不做"公网域名兜底"——本项目没有可靠的公网域名来源，
        // 与其留一段永远为 nil 的假兜底，不如让失败信息明确指向 ZeroTier / 家里 WiFi。
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
                // 实测：重启后约 9 秒才稳定应答，前 6 秒连不上。等 10 秒再判。
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await MainActor.run {
                    waitingBack = false
                    busy = false
                    statusLine = L10n.t("i18n_1557")
                }
            case .reboot:
                try await RouterControl.reboot(host: target, key: key)
                await MainActor.run {
                    statusLine = L10n.t("i18n_1558")
                    waitingBack = true
                }
                // 指令已受理，路由器 2 秒后真重启，约 40 秒恢复。不干等，直接告诉用户。
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                await MainActor.run {
                    waitingBack = false
                    busy = false
                    statusLine = L10n.t("i18n_1559")
                }
            }
        } catch let e as RouterError {
            await MainActor.run {
                busy = false
                waitingBack = false
                statusIsError = true
                statusLine = e.errorDescription ?? L10n.t("i18n_1560")
                if case .noKey = e { keyLoaded = false }
                if case .badKey = e { keyLoaded = false }
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
