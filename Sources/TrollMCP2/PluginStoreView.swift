// PluginStoreView.swift — v1.0.32 插件市场界面
//
// 三个屏：发现（分类筛选 + 搜索）、已安装（开关启停）、详情（装前看清它加什么）。
// 刻意做成原生 SwiftUI 而不是套 WebView——插件市场的价值在「装完真能用」，
// 界面稳不稳定反而更重要。

import SwiftUI

struct PluginStoreView: View {
    @ObservedObject private var store = PluginStore.shared
    // v1.0.35：授权确认门总开关
    @ObservedObject private var gate = ConfirmGate.shared

    @State private var tab = 1                 // 0 = 已安装, 1 = 发现, 2 = 外部目录
    @State private var query = ""
    @State private var category: PluginCategory? = nil
    @State private var detail: PluginManifest? = nil
    @State private var alertItem: PluginAlert? = nil
    /// 2026-11-05：外部参考目录（竞品 12 类 / 4687 条）——
    /// 这些是 Node 插件，本机装不了，只能「照着做一个」。所以单独一屏，别和可安装的混在一起。
    @State private var refsVersion = 0
    @State private var refDetail: RefPlugin? = nil

    /// 同一个视图只能挂一个 .alert——安装确认与卸载确认合并成同一入口
    enum PluginAlert: Identifiable {
        case install(PluginManifest)
        case uninstall(PluginManifest)

        var id: String {
            switch self {
            case .install(let m): return "install-" + m.id
            case .uninstall(let m): return "uninstall-" + m.id
            }
        }

        var manifest: PluginManifest {
            switch self {
            case .install(let m), .uninstall(let m): return m
            }
        }
    }

    private let tints: [Color] = [.blue, .green, .purple, .orange, .cyan, .pink]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                subtitleRow
                segmented
                searchField
                if tab != 0 { chips }
                switch tab {
                case 0: installedList
                case 2: referenceList
                default: discoverList
                }
                aiControlRow
                // v1.0.35：授权确认门开关——紧跟在 AI 自主权限下面，
                // 两个开关是同一类东西：都是「AI 能自己干到什么程度」的闸。
                policyRow
            }
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(L10n.t("i18n_1570"))
        .navigationBarTitleDisplayMode(.large)
        .sheet(item: $detail) { m in
            PluginDetailSheet(
                manifest: m,
                onInstall: { alertItem = .install(m); detail = nil },
                onUninstall: { alertItem = .uninstall(m); detail = nil },
                onToggle: { on in store.setEnabled(m, on) }
            )
        }
        // 2026-11-05：外部目录详情——只展示，不提供「安装」，提供「让 AI 照做一个」
        .sheet(item: $refDetail) { r in
            RefPluginSheet(ref: r, categoryName: RefCategory.name(r.category))
        }
        .onAppear {
            // 懒加载：只在真正打开市场时才解析那份 1.5MB 的 JSON
            PluginCatalogRef.loadIfNeeded { refsVersion += 1 }
        }
        .alert(item: $alertItem) { item in
            switch item {
            case .install(let m):
                return Alert(
                    title: Text(m.name),
                    message: Text(L10n.t("i18n_1589", m.tools.count,
                                         m.deps.isEmpty ? L10n.t("i18n_1605") : m.deps.joined(separator: " · "))),
                    primaryButton: .default(Text(L10n.t("i18n_1574"))) { store.install(m) },
                    secondaryButton: .cancel(Text(L10n.t("i18n_1591"))))
            case .uninstall(let m):
                return Alert(
                    title: Text(L10n.t("i18n_1577") + " " + m.name),
                    message: Text(L10n.t("i18n_1592", m.tools.count, m.skills.count)),
                    primaryButton: .destructive(Text(L10n.t("i18n_1577"))) { store.uninstall(m) },
                    secondaryButton: .cancel(Text(L10n.t("i18n_1591"))))
            }
        }
    }

    // MARK: 顶部

    /// v1.0.34：AI 自主管理总开关。
    /// 默认开着（用户要求全放开），但保留一个能一键掐断的入口——
    /// 万一哪天它自己装了个不该装的东西，关掉这里它就不会再动插件了。
    private var aiControlRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.purple)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.purple.opacity(0.13)))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("i18n_1606"))
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.t("i18n_1607"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { store.aiControlEnabled },
                set: { store.aiControlEnabled = $0 }
            ))
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    /// v1.0.35：AI 请求授权的总开关。
    /// 关掉后 AI 调 policy.confirm 会直接报错——不是自动放行，是取消这条通道。
    private var policyRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.teal)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.teal.opacity(0.13)))
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("i18n_1618"))
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.t("i18n_1619"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { gate.enabled },
                set: { gate.enabled = $0 }
            ))
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var subtitleRow: some View {
        HStack {
            if tab == 0 {
                Text(L10n.t("i18n_1593", store.installedManifests.count,
                            store.installedToolCount, store.installedSkillCount))
            } else if tab == 2 {
                // 外部目录页单独一句：这一页 4687 条一条都装不上，副标题必须说清楚，
                // 否则跟「发现」页一样写"共 N 个插件"，用户点进去找不到安装按钮会以为坏了。
                Text(L10n.t("i18n_1634", PluginCategory.allCases.count, PluginCatalogRef.totalCount))
            } else {
                Text(L10n.t("i18n_1594", PluginCategory.allCases.count, store.catalog.count))
            }
            Spacer()
            if let e = store.lastError {
                Text(e).foregroundColor(.red).lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .foregroundColor(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private var segmented: some View {
        HStack(spacing: 0) {
            segmentButton(0, L10n.t("i18n_1571"))
            segmentButton(1, L10n.t("i18n_1572"))
            // 2026-11-05：第三页是外部参考目录（竞品那 12 类），只能查不能直接装
            segmentButton(2, L10n.t("i18n_1624"))
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(.secondarySystemFill)))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private func segmentButton(_ i: Int, _ title: String) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = i }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: tab == i ? .semibold : .regular))
                .foregroundColor(tab == i ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tab == i ? Color(.systemBackground) : Color.clear)
                        .shadow(color: tab == i ? Color.black.opacity(0.10) : .clear, radius: 3, y: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            TextField(L10n.t("i18n_1573"), text: $query)
                .font(.system(size: 14))
                .autocapitalization(.none)
                .disableAutocorrection(true)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(Color(.tertiaryLabel))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 35)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemFill)))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                // 2026-11-05：两个页签的分类计数口径不同——
                // 发现页算「能装的」，外部目录页算「能参考的」，混用会让数字对不上。
                let total = tab == 2 ? PluginCatalogRef.totalCount : store.catalog.count
                chipItem(nil, L10n.t("i18n_1585"), total)
                ForEach(PluginCategory.allCases) { c in
                    chipItem(c, c.shortName, count(in: c))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        // refsVersion 变了说明外部目录解析完了 → 强制刷新一次计数
        .id(refsVersion)
    }

    private func chipItem(_ c: PluginCategory?, _ title: String, _ n: Int) -> some View {
        let on = (category == c)
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { category = c }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text("\(n)").font(.system(size: 10.5)).opacity(on ? 0.75 : 0.5)
            }
            .font(.system(size: 12.5, weight: on ? .semibold : .medium))
            .foregroundColor(on ? .white : .primary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule()
                    .fill(on ? Color.primary : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                Capsule().strokeBorder(Color.black.opacity(on ? 0 : 0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func count(in c: PluginCategory) -> Int {
        // 外部目录页用另一套计数（那边 4687 条，不分流会让「工具」显示成 8 个，明显不对）
        if tab == 2 { return PluginCatalogRef.count(in: c) }
        return store.catalog.filter { $0.category == c }.count
    }

    // MARK: 列表

    private var filtered: [PluginManifest] {
        var list = store.catalog
        if let c = category { list = list.filter { $0.category == c } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.pkg.lowercased().contains(q) ||
                $0.summary.lowercased().contains(q) ||
                $0.category.displayName.contains(q)
            }
        }
        // 已安装的沉到后面，让「还能装的」先被看到（和真实应用商店一致）
        return list.sorted { a, b in
            let ia = store.isInstalled(a.id), ib = store.isInstalled(b.id)
            if ia != ib { return !ia }
            return a.stars > b.stars
        }
    }

    private var discoverList: some View {
        LazyVStack(spacing: 8) {
            if filtered.isEmpty {
                emptyState
            } else {
                ForEach(filtered) { m in
                    PluginRow(manifest: m, tint: tints[m.tint % tints.count],
                              installed: store.isInstalled(m.id),
                              installing: store.isInstalling(m.id))
                        .onTapGesture { detail = m }
                        .contextMenu {
                            Button {
                                if store.isInstalled(m.id) { alertItem = .uninstall(m) }
                                else { alertItem = .install(m) }
                            } label: {
                                Text(store.isInstalled(m.id) ? L10n.t("i18n_1577") : L10n.t("i18n_1574"))
                            }
                        }
                        .overlay(alignment: .trailing) {
                            // 行尾按钮独立出来，避免和整卡点击冲突。
                            // 拆成独立 struct 而不是内联三段三元——内联写法会让
                            // SwiftUI 的 ViewBuilder 类型检查变得极慢甚至超时报错。
                            PluginActionButton(installed: store.isInstalled(m.id),
                                               installing: store.isInstalling(m.id)) {
                                if store.isInstalled(m.id) { detail = m } else { alertItem = .install(m) }
                            }
                            .padding(.trailing, 13)
                        }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: - 外部参考目录（2026-11-05）
    //
    // 这一屏是「别处做过什么」，不是「本机能装什么」。
    // 用户要的是「桌面上那个 ipa 里的插件」——那些是 Node 插件，本机跑不了，
    // 所以这里点开只能看到原项目信息 + 一句「让 AI 照着做一个（shell 版）」。
    // 混进「发现」页会让用户点安装然后失败，比没有更糟，因此单独一屏。

    private var referenceList: some View {
        let hits = PluginCatalogRef.search(query, category: category)
        return LazyVStack(spacing: 8) {
            if !PluginCatalogRef.isLoaded {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.t("i18n_1625"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if hits.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundColor(Color(.tertiaryLabel))
                    Text(L10n.t("i18n_1588"))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                // 只渲染前 200 条：4687 条全铺进 LazyVStack 也会让首屏卡
                ForEach(hits) { r in
                    RefPluginRow(ref: r, categoryName: RefCategory.name(r.category))
                        .onTapGesture { refDetail = r }
                }
                if hits.count >= 200 {
                    Text(L10n.t("i18n_1626"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private var installedList: some View {
        LazyVStack(spacing: 8) {
            if store.installedManifests.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 34, weight: .light))
                        .foregroundColor(Color(.tertiaryLabel))
                    Text(L10n.t("i18n_1595"))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Button {
                        withAnimation { tab = 1 }
                    } label: {
                        Text(L10n.t("i18n_1596"))
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 70)
            } else {
                ForEach(store.installedManifests) { m in
                    InstalledRow(manifest: m, tint: tints[m.tint % tints.count],
                                 enabled: store.isEnabled(m.id),
                                 onToggle: { store.setEnabled(m, $0) })
                        .onTapGesture { detail = m }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(Color(.tertiaryLabel))
            Text(L10n.t("i18n_1588"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - 列表行

private struct PluginRow: View {
    let manifest: PluginManifest
    let tint: Color
    let installed: Bool
    let installing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            PluginIcon(emoji: manifest.icon, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(manifest.pkg)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(manifest.summary)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("★ \(num(manifest.stars))")
                    Text("·").opacity(0.4)
                    Text("↓ \(num(manifest.downloads))")
                    Text("·").opacity(0.4)
                    Text(manifest.category.shortName)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                    if manifest.requiresHook {
                        Text(L10n.t("i18n_1583"))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.orange.opacity(0.16)))
                            .foregroundColor(.orange)
                    }
                    Text("v" + manifest.version)
                }
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 62)   // 给行尾按钮留位
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(.secondarySystemGroupedBackground)))
        .contentShape(Rectangle())
    }

    private func num(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

/// 列表行尾的「安装 / 安装中 / 已安装」胶囊按钮
private struct PluginActionButton: View {
    let installed: Bool
    let installing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: installed ? .regular : .semibold))
                .foregroundColor(installed ? Color.secondary : Color.accentColor)
                .padding(.horizontal, 13)
                .frame(height: 28)
                .background(Capsule().fill(background))
                .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(installing)
    }

    private var title: String {
        if installing { return L10n.t("i18n_1575") }
        return installed ? L10n.t("i18n_1576") : L10n.t("i18n_1574")
    }

    private var background: Color {
        installed ? Color(.tertiarySystemFill) : Color.accentColor.opacity(0.10)
    }

    private var border: Color {
        installed ? Color.clear : Color.accentColor.opacity(0.32)
    }
}

private struct InstalledRow: View {
    let manifest: PluginManifest
    let tint: Color
    let enabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            PluginIcon(emoji: manifest.icon, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(manifest.pkg)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Text(toolSummary)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if !manifest.tools.isEmpty {
                    Text(manifest.tools.map { $0.name.replacingOccurrences(of: "user.", with: "") }
                            .joined(separator: " · "))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Color.accentColor.opacity(0.85))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { enabled }, set: { onToggle($0) }))
                .labelsHidden()
                .scaleEffect(0.85)
                .padding(.top, 4)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(.secondarySystemGroupedBackground)))
        .opacity(enabled ? 1 : 0.55)
        .contentShape(Rectangle())
    }

    private var toolSummary: String {
        var parts: [String] = []
        if !manifest.tools.isEmpty { parts.append(L10n.t("i18n_1597", manifest.tools.count)) }
        if !manifest.skills.isEmpty { parts.append(L10n.t("i18n_1598", manifest.skills.count)) }
        parts.append(manifest.category.shortName)
        parts.append("v" + manifest.version)
        return parts.joined(separator: " · ")
    }
}

private struct PluginIcon: View {
    let emoji: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26)
            .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.10)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Text(emoji).font(.system(size: size * 0.46)))
    }
}

// MARK: - 详情页

// MARK: - 外部参考目录的行 / 详情（2026-11-05）

/// 分类 id → 中文短名。外部目录里存的是英文 rawValue（tools / session ...），
/// 界面上要显示和内置目录一致的「工具 / 会话 / 记忆」。
enum RefCategory {
    static func name(_ raw: String) -> String {
        PluginCategory(rawValue: raw)?.shortName ?? raw
    }
    static func emoji(_ raw: String) -> String {
        switch raw {
        case "tools":    return "🧰"
        case "session":  return "💬"
        case "model":    return "🔌"
        case "memory":   return "🧠"
        case "skill":    return "🧩"
        case "vision":   return "👁"
        case "docs":     return "📄"
        case "usage":    return "📈"
        case "remote":   return "📡"
        case "security": return "🛡"
        case "browser":  return "🌐"
        case "git":      return "🔀"
        default:         return "🧩"
        }
    }
}

/// 外部目录的一行。刻意长得和 PluginRow 相似，但有两点必须不同：
///   第一，不显示「安装」按钮——装了也跑不了，那是骗人；
///   第二，明确标一句「参考 · 需改写」。
private struct RefPluginRow: View {
    let ref: RefPlugin
    let categoryName: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            PluginIcon(emoji: RefCategory.emoji(ref.category),
                       tint: .gray, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(ref.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(ref.summary)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("★ \(num(ref.stars))")
                    Text("·").opacity(0.4)
                    Text(categoryName)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                    Text("·").opacity(0.4)
                    Text(L10n.t("i18n_1627"))     // 「参考 · 需改写」
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.gray.opacity(0.16)))
                }
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(.secondarySystemGroupedBackground)))
        .contentShape(Rectangle())
    }

    private func num(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

/// 外部目录详情：说明「这是什么、为什么装不了、能拿它干什么」。
/// 唯一可执行的动作是「让 AI 照着做一个 shell 版」——把需求写进剪贴板，
/// 用户回聊天框粘贴即可（这里不直接跳转，避免抢走当前会话上下文）。
private struct RefPluginSheet: View {
    let ref: RefPlugin
    let categoryName: String

    @Environment(\.presentationMode) private var presentationMode
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    PluginIcon(emoji: RefCategory.emoji(ref.category), tint: .gray, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ref.name)
                            .font(.system(size: 16, weight: .semibold))
                        Text("★ \(ref.stars) · \(categoryName)")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                Text(ref.summary)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                // 这段是这一页的核心：说清为什么没有「安装」按钮
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.t("i18n_1628"), systemImage: "info.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(L10n.t("i18n_1629"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color(.tertiarySystemFill)))

                if !ref.pkg.isEmpty {
                    HStack(spacing: 6) {
                        Text("npm").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                        Text(ref.pkg)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                    }
                }
                if !ref.owner.isEmpty && !ref.repo.isEmpty {
                    HStack(spacing: 6) {
                        Text("repo").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                        Text("\(ref.owner)/\(ref.repo)")
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                    }
                }

                Button {
                    UIPasteboard.general.string = promptText
                    copied = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark.circle.fill" : "square.on.square")
                        Text(L10n.t(copied ? "i18n_1631" : "i18n_1630"))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.13)))
                }
                .buttonStyle(.plain)

                Text(L10n.t("i18n_1632"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 10)
            }
            .padding(18)
        }
        .navigationTitle(L10n.t("i18n_1633"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 复制给用户的指令：带着名字与原始描述，AI 一看就知道要做什么
    private var promptText: String {
        """
        我看到一个外部插件「\(ref.name)」（\(categoryName)），它做的事是：\(ref.summary)
        \(ref.owner.isEmpty ? "" : "原项目：https://github.com/\(ref.owner)/\(ref.repo)\n")
        它跑在 Node 环境，我们这边装不了。请你按这个思路，用本机 shell 给我做一个等效的插件：
        先用 plugin.define 建一个 id 为 \(ref.id) 的插件，工具命令只用 busybox 自带的（ls/find/grep/awk/sed/sort/du/md5sum/base64），
        不要依赖 npm / node / python。做完告诉我它加了哪些工具、怎么用。
        """
    }
}

struct PluginDetailSheet: View {
    let manifest: PluginManifest
    let onInstall: () -> Void
    let onUninstall: () -> Void
    let onToggle: (Bool) -> Void

    @ObservedObject private var store = PluginStore.shared
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    actionButton
                    if !manifest.tools.isEmpty { toolsSection }
                    if !manifest.skills.isEmpty { skillsSection }
                    infoSection
                    if manifest.requiresHook { hookWarning }
                    if !manifest.changelog.isEmpty { changelogSection }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(L10n.t("i18n_1578"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.t("i18n_1599")) { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            PluginIcon(emoji: manifest.icon, tint: .blue, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(manifest.name).font(.system(size: 17, weight: .semibold))
                Text(manifest.pkg)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("\(manifest.author) · v\(manifest.version) · \(manifest.sizeKB) KB")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var actionButton: some View {
        if store.isInstalled(manifest.id) {
            HStack(spacing: 10) {
                Toggle(L10n.t("i18n_1600"), isOn: Binding(
                    get: { store.isEnabled(manifest.id) },
                    set: { onToggle($0) }))
                    .font(.system(size: 13))
                Spacer()
                Button(role: .destructive) { onUninstall() } label: {
                    Text(L10n.t("i18n_1577")).font(.system(size: 13, weight: .medium))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
        } else {
            Button {
                onInstall()
            } label: {
                Group {
                    if store.isInstalling(manifest.id) {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.8)
                            Text(L10n.t("i18n_1575"))
                        }
                    } else {
                        Text(L10n.t("i18n_1574"))
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(store.isInstalling(manifest.id))
        }
    }

    private var toolsSection: some View {
        sectionCard(title: L10n.t("i18n_1579")) {
            ForEach(manifest.tools.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.tools[i].name.replacingOccurrences(of: "user.", with: ""))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.accentColor)
                    Text(manifest.tools[i].summary)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                }
            }
        }
    }

    private var skillsSection: some View {
        sectionCard(title: L10n.t("i18n_1601")) {
            ForEach(manifest.skills.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.skills[i].name).font(.system(size: 12.5, weight: .medium))
                    Text(manifest.skills[i].summary)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                }
            }
        }
    }

    private var infoSection: some View {
        sectionCard(title: L10n.t("i18n_1580")) {
            infoRow(L10n.t("i18n_1587"), manifest.category.displayName)
            if !manifest.deps.isEmpty {
                infoRow(L10n.t("i18n_1581"), manifest.deps.joined(separator: " · "))
            }
            infoRow(L10n.t("i18n_1582"), "\(manifest.tools.count)")
            if !manifest.skills.isEmpty { infoRow(L10n.t("i18n_1601"), "\(manifest.skills.count)") }
            infoRow(L10n.t("i18n_1602"), L10n.t("i18n_1603"))
        }
    }

    private var hookWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .padding(.top, 1)
            Text(L10n.t("i18n_1604"))
                .font(.system(size: 11.5))
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.22), lineWidth: 1))
    }

    private var changelogSection: some View {
        sectionCard(title: L10n.t("i18n_1584")) {
            ForEach(manifest.changelog.indices, id: \.self) { i in
                Text(manifest.changelog[i])
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color(.separator)).frame(height: 0.5)
                    }
            }
        }
    }

    private func infoRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundColor(.secondary)
            Spacer()
            Text(v).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private func sectionCard<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 5)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemGroupedBackground)))
    }
}
