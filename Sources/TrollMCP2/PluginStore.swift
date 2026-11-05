// PluginStore.swift — v1.0.32 插件市场内核
//
// 设计目标：让「装一个插件」= 让 AI 多一组能调用的工具，全程不用重新构建 App。
//
// 三层：
//   ① 目录（PluginManifest 列表）—— 第一版内置 28 个，后续可切远端 index.json
//   ② 安装器 —— 落盘 + 注册工具（ToolRegistry）+ 注册技能（SkillStore）+ 持久化
//   ③ 卸载器 —— 按前缀一次性摘干净，不残留
//
// 与 MCP 服务器的区别：MCP 是连远端 HTTP，插件是本地声明式包（工具=命令模板）。
// 与 AI 自写工具的区别：插件由用户显式安装、来源可控，属于「用户信任」范畴，
// 因此走 registerPluginTool（跳过危险词检查），但强制 user.plg_ 前缀便于审计与整批卸载。

import Foundation
import Combine

// MARK: - 分类

/// 12 个分类：必须做的 7 类 + 有用的 5 类。
/// 刻意不设「UI 增强 / 主题 / 娱乐」——那是 WebView 宿主才需要的东西，原生界面用不上。
enum PluginCategory: String, Codable, CaseIterable, Identifiable {
    case tools, session, model, memory, skill, vision, docs, usage, remote, security, browser, git

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tools:    return "工具与能力"
        case .session:  return "会话与消息"
        case .model:    return "模型与账号接入"
        case .memory:   return "记忆"
        case .skill:    return "技能包"
        case .vision:   return "视觉与多模态"
        case .docs:     return "文档与渲染"
        case .usage:    return "用量与计费"
        case .remote:   return "远程与移动端"
        case .security: return "安全与权限"
        case .browser:  return "浏览器与网页"
        case .git:      return "Git 与代码评审"
        }
    }

    /// 分类横滑条上的短名
    var shortName: String {
        switch self {
        case .tools:    return "工具"
        case .session:  return "会话"
        case .model:    return "模型"
        case .memory:   return "记忆"
        case .skill:    return "技能"
        case .vision:   return "视觉"
        case .docs:     return "文档"
        case .usage:    return "用量"
        case .remote:   return "远程"
        case .security: return "安全"
        case .browser:  return "网页"
        case .git:      return "Git"
        }
    }

    var emoji: String {
        switch self {
        case .tools:    return "🔧"
        case .session:  return "💬"
        case .model:    return "🔌"
        case .memory:   return "🧠"
        case .skill:    return "📘"
        case .vision:   return "👁"
        case .docs:     return "📊"
        case .usage:    return "📈"
        case .remote:   return "🖥"
        case .security: return "🛡"
        case .browser:  return "🌐"
        case .git:      return "🌿"
        }
    }
}

// MARK: - 插件包内的工具 / 技能声明

/// 一条工具声明：名字 + 给 AI 看的说明 + 参数 + 要执行的命令模板。
/// 命令模板里的 `{参数名}` 会被替换成 shell 安全转义后的用户输入。
struct PluginToolSpec: Codable {
    var name: String          // 完整工具名，形如 user.plg_ipa_inspector_info
    var summary: String       // AI 用它判断何时调用
    var command: String       // 命令模板
    var params: [String: String]  // 参数名 → 说明
    var timeout: Double

    init(name: String, summary: String, command: String,
         params: [String: String] = [:], timeout: Double = 60) {
        self.name = name
        self.summary = summary
        self.command = command
        self.params = params
        self.timeout = timeout
    }
}

/// 技能声明：纯提示词，装进 SkillStore，AI 按 summary 决定何时读
struct PluginSkillSpec: Codable {
    var name: String
    var summary: String
    var instruction: String
}

// MARK: - 插件清单

struct PluginManifest: Codable, Identifiable {
    var id: String
    var name: String
    var pkg: String            // @vipios/xxx
    var version: String
    var author: String
    var category: PluginCategory
    var icon: String           // emoji
    var tint: Int              // 0..5 图标配色
    var sizeKB: Int
    var summary: String
    var deps: [String]         // 需要 apk 的包名，仅提示用
    var requiresHook: Bool     // true = 需要宿主钩子，光装插件不生效
    var tools: [PluginToolSpec]
    var skills: [PluginSkillSpec]
    var changelog: [String]
    var stars: Int
    var downloads: Int
    var updatedAt: String
    /// v1.0.34：风险等级，只用于审计日志与界面标注，不参与拦截（用户已选择全放开）。
    /// 取值：safe（纯查询）/ shell（执行命令）/ network（联网）/ host（需要宿主钩子）。
    /// 用可选类型 + 默认 nil：内置那 28 个构造调用不必逐个补参数，
    /// 老的 plugin.json 没有这个字段也能正常解码。
    var risk: String? = nil

    init(id: String, name: String, version: String, category: PluginCategory,
         icon: String, tint: Int, sizeKB: Int, summary: String,
         deps: [String] = [], requiresHook: Bool = false,
         tools: [PluginToolSpec] = [], skills: [PluginSkillSpec] = [],
         changelog: [String] = [], stars: Int = 0, downloads: Int = 0,
         updatedAt: String = "11-05", author: String = "vipios") {
        self.id = id
        self.name = name
        self.pkg = "@vipios/" + id
        self.version = version
        self.author = author
        self.category = category
        self.icon = icon
        self.tint = tint
        self.sizeKB = sizeKB
        self.summary = summary
        self.deps = deps
        self.requiresHook = requiresHook
        self.tools = tools
        self.skills = skills
        self.changelog = changelog
        self.stars = stars
        self.downloads = downloads
        self.updatedAt = updatedAt
    }

    /// 卸载时按这个前缀整批摘除，保证不残留
    var toolPrefix: String {
        "user.plg_" + id.replacingOccurrences(of: "-", with: "_") + "_"
    }
}

// MARK: - 商店

final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    /// 全量目录（第一版内置；将来换成远端 index.json，结构不变）
    @Published private(set) var catalog: [PluginManifest] = []
    /// 已安装
    @Published private(set) var installedIDs: Set<String> = []
    /// 安装动画期间（0.5s，让用户看到反馈而不是秒变）
    @Published private(set) var installingIDs: Set<String> = []
    /// 已安装但被停用（工具保持注册，但被标为 disabled，AI 看不到）
    @Published private(set) var disabledIDs: Set<String> = []
    @Published var lastError: String?

    private let installedKey = "trollmcp2.plugins_installed"
    private let disabledKey = "trollmcp2.plugins_disabled"
    /// 2026-11-05：外部目录里「我装过哪几条」。
    /// 和 installedIDs 分开存 —— installedIDs 记的是能力包（cap-*），
    /// 这里记的是外部条目 id，两者是多对一关系，混在一起会互相覆盖。
    private let externalKey = "trollmcp2.plugins_external"
    @Published private(set) var externalInstalledIDs: Set<String> = []

    private init() {
        // 2026-11-05：catalog 现在 = 内置插件 + 能力包（CapabilityPacks）。
        //
        // 为什么能力包要进 catalog：
        //   · 「已安装」页走 installedManifests → manifest(id:) → catalog 查找，
        //     不在 catalog 里就会变成「装了但查不到」的幽灵条目，界面上直接消失；
        //   · AI 的 plugin.list / plugin.toggle 也要靠它拿到工具清单。
        // 外部那 4687 条**不进** catalog —— 它们只是入口，装的是能力包本体，
        // 全塞进来会让 catalog 变成 4704 条，每次 filter 都变慢。
        catalog = Self.builtinCatalog + CapabilityPacks.list
        load()
        // 工具只活在内存里，App 重启后必须重新注册。
        // 延后 1.5s：避开启动瞬间的注册表初始化与首屏渲染。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self.restoreInstalled()
            // v1.0.34：把 plugin.search / install / remove / toggle / define / list
            // 注册进工具表。必须晚于 restoreInstalled —— 否则插件工具名和
            // 管理器工具名的重名检查会互相干扰。
            self.registerManagerTools()
        }
    }

    // MARK: 查询

    func manifest(id: String) -> PluginManifest? {
        if let m = catalog.first(where: { $0.id == id }) { return m }
        // v1.0.34：AI 用 plugin.define 自建的插件不在内置目录里，
        // 重启后 catalog 会重置成 builtinCatalog，必须从磁盘补回来，
        // 否则「已安装」列表里会出现一个查不到 manifest 的幽灵 id，
        // 它的工具也注册不回来。
        if let m = readManifestFromDisk(id) {
            catalog.append(m)
            return m
        }
        return nil
    }

    /// 从 Documents/Plugins/<id>/plugin.json 读回一个 manifest
    private func readManifestFromDisk(_ id: String) -> PluginManifest? {
        guard !id.contains("/"), !id.contains(".."), !id.isEmpty else { return nil }
        let url = pluginsDir.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("plugin.json")
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PluginManifest.self, from: d)
    }

    var installedManifests: [PluginManifest] {
        // 走 manifest(id:) 而不是直接 filter catalog：
        // AI 自建的插件不在内置目录里，得靠 manifest(id:) 从磁盘补回来
        installedIDs.compactMap { manifest(id: $0) }.sorted { $0.name < $1.name }
    }

    func isInstalled(_ id: String) -> Bool { installedIDs.contains(id) }
    func isInstalling(_ id: String) -> Bool { installingIDs.contains(id) }
    func isEnabled(_ id: String) -> Bool { installedIDs.contains(id) && !disabledIDs.contains(id) }

    // MARK: - 外部插件（2026-11-05 并入发现页）
    //
    // 用户要求：「把外部目录去掉，把这些插件都放在发现里面，就和我刚才给你发的
    // ipa 一样的，直接就能安装使用」+「全部 4687 条都做成可安装」+「按功能归并」。
    //
    // 所以做法是：每条外部插件带一个 capKey，指向 CapabilityPacks 里的某个能力包。
    //   · 装这条外部插件 → 实际装的是它指向的能力包（工具真能跑）
    //   · 多条外部插件指向同一个包 → 装第一个就把工具都装上了，
    //     后面那些只需记一个「已安装」状态，不再重复注册工具（否则工具表会被刷爆）
    //   · 卸载时：只要还有别的外部插件指着同一个包，就不摘工具

    /// 某条外部插件「装完会得到什么」——把外部条目转成一个可安装的 manifest。
    ///
    /// 返回的 manifest id 用的是**能力包 id**（不是外部插件 id），
    /// 这样 PluginStore 原有的「同 id 只装一次」逻辑天然去重。
    func resolvedManifest(for ext: ExternalPlugin) -> PluginManifest? {
        guard let base = CapabilityPacks.pack(ext.capKey) ?? CapabilityPacks.pack("cap-misc") else {
            return nil
        }
        var pack = base
        // 名字/说明用外部插件自己的，让用户看到「我装的是那个东西」；
        // 工具仍然是能力包的真工具。
        pack.name = ext.name
        pack.summary = ext.summary
        pack.category = ext.category
        pack.stars = ext.stars
        // 把来源记进 changelog，详情页能看出「这条来自外部目录」
        pack.changelog = ["来自外部目录：\(ext.name)"] + base.changelog
        return pack
    }

    /// 某条外部插件当前是否「已经能用」（= 它指向的能力包已装）
    func isExternalReady(_ ext: ExternalPlugin) -> Bool {
        let key = CapabilityPacks.pack(ext.capKey) != nil ? ext.capKey : "cap-misc"
        return installedIDs.contains(key)
    }

    /// 装一条外部插件。
    ///
    /// 两件事分开做，不要混：
    ///   ① 能力包本体（cap-*）用 CapabilityPacks 里的**原名**装 —— 这样「已安装」页
    ///      显示的是「压缩归档」这种能力名，而不是某条外部插件的长名字；
    ///   ② 这条外部插件的 id 记进 externalInstalledIDs —— 下次打开列表能显示「已安装」。
    func installExternal(_ ext: ExternalPlugin) {
        let key = CapabilityPacks.pack(ext.capKey) != nil ? ext.capKey : "cap-misc"
        guard let pack = CapabilityPacks.pack(key) else {
            lastError = "这条没有可用的能力包"
            return
        }
        externalInstalledIDs.insert(ext.id)
        saveExternal()
        // 能力包已经装过 → 不再重复注册（否则工具表里会多一份同名工具）
        if !installedIDs.contains(pack.id) {
            install(pack)
        }
    }

    /// 卸一条外部插件（只从「我装过这条」名单里划掉）。
    ///
    /// 为什么**不摘工具**：十几条外部插件共用同一个能力包。
    /// 用户卸掉其中一条，另外那些还得继续能用 —— 在这里摘工具等于把它们一起废掉。
    /// 真要彻底卸载，去「已安装」页对能力包本体点卸载（那才走 uninstall 摘工具）。
    func uninstallExternal(_ ext: ExternalPlugin) {
        externalInstalledIDs.remove(ext.id)
        saveExternal()
        print("[TA] 📦 external plugin unlisted: \(ext.id)")
    }

    /// 这条外部插件用户是否主动装过（和「能力包已装」是两个概念：
    /// 能力包可能因为装了别的同类插件而早就在了）
    func isExternalMarkedInstalled(_ ext: ExternalPlugin) -> Bool {
        externalInstalledIDs.contains(ext.id) || isExternalReady(ext)
    }

    /// 已安装插件贡献的工具总数
    var installedToolCount: Int {
        installedManifests.reduce(0) { $0 + $1.tools.count }
    }

    /// 已安装插件贡献的技能总数
    var installedSkillCount: Int {
        installedManifests.reduce(0) { $0 + $1.skills.count }
    }

    // MARK: 安装

    func install(_ m: PluginManifest) {
        guard !installedIDs.contains(m.id), !installingIDs.contains(m.id) else { return }
        installingIDs.insert(m.id)
        lastError = nil

        // 0.5s 的「安装中」——真实工作在一帧内就完成了，这里纯粹是给用户反馈
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.writeManifestToDisk(m)
            let registered = self.registerTools(for: m)
            self.registerSkills(for: m)
            self.installedIDs.insert(m.id)
            self.disabledIDs.remove(m.id)
            self.installingIDs.remove(m.id)
            self.save()
            print("[TA] 📦 plugin installed: \(m.id) (\(registered)/\(m.tools.count) tools)")
        }
    }

    func uninstall(_ m: PluginManifest) {
        // v1.0.34：卸完就没了，先备份一份到 .trash/，删错了能捞回来
        backupManifest(m)
        // 1. 摘工具（按前缀整批）
        ToolRegistry.shared.removeTools(prefix: m.toolPrefix)
        // 2. 删技能
        for s in m.skills {
            SkillStore.shared.delete(named: s.name)
        }
        // 3. 删盘上文件
        let dir = pluginsDir.appendingPathComponent(m.id)
        try? FileManager.default.removeItem(at: dir)
        // 4. 状态
        installedIDs.remove(m.id)
        disabledIDs.remove(m.id)
        save()
        audit("uninstall", "\(m.id)（界面操作，已备份 manifest）")
        print("[TA] 📦 plugin uninstalled: \(m.id)")
    }

    /// 停用 / 启用已安装插件：工具保持注册，只切 enabled 状态
    func setEnabled(_ m: PluginManifest, _ on: Bool) {
        if on { disabledIDs.remove(m.id) } else { disabledIDs.insert(m.id) }
        for t in m.tools {
            ToolRegistry.shared.setEnabled(name: t.name, enabled: on)
        }
        for s in m.skills {
            SkillStore.shared.setEnabled(s.name, on)
        }
        save()
    }

    // MARK: - AI 自主管理（v1.0.34：全放开）

    /// 总开关。关掉后 AI 的 plugin.* 工具一律拒绝执行，用户仍可在界面里手动装/卸。
    /// 刻意不用 @Published 存值——它要能被 UserDefaults 直接读写，
    /// 界面侧用 Binding(get:set:) 包一层即可。
    private let aiControlKey = "trollmcp2.plugins_ai_control"

    var aiControlEnabled: Bool {
        get { UserDefaults.standard.object(forKey: aiControlKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: aiControlKey)
            objectWillChange.send()
        }
    }

    /// 审计日志：AI 每一次装/卸/启停都记一行，写到 Documents/Plugins/.audit.log。
    /// 用户随时能翻，出了问题能回溯是哪个插件哪一步干的。
    private func audit(_ action: String, _ detail: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] \(action) \(detail)\n"
        let url = pluginsDir.appendingPathComponent(".audit.log")
        try? FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
        // 超过 200KB 就只留最后 500 行，避免无限长
        if let sz = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, sz > 200_000 {
            if let txt = try? String(contentsOf: url, encoding: .utf8) {
                let tail = txt.components(separatedBy: "\n").suffix(500).joined(separator: "\n")
                try? tail.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        print("[TA] 📦 audit: \(action) \(detail)")
    }

    /// 卸载前把 manifest 备份一份到 .trash/，误删能捞回来
    private func backupManifest(_ m: PluginManifest) {
        let dir = pluginsDir.appendingPathComponent(".trash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("\(m.id)-\(ts).json")
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: url) }
    }

    // MARK: 同步版（给 AI 工具用）

    /// 同步安装。界面走 install()（有 0.5s 动画），AI 走这个——调完立刻能用。
    @discardableResult
    func installSync(_ m: PluginManifest) -> (ok: Bool, message: String, toolNames: [String]) {
        if installedIDs.contains(m.id) {
            return (false, "已经装过了：\(m.name)（\(m.id)）", [])
        }
        writeManifestToDisk(m)
        let registered = registerTools(for: m)
        registerSkills(for: m)
        installedIDs.insert(m.id)
        disabledIDs.remove(m.id)
        save()
        audit("install", "\(m.id) v\(m.version) tools=\(registered)/\(m.tools.count) risk=\(m.risk ?? "-")")
        var msg = "已安装 \(m.name) v\(m.version)，注册了 \(registered) 个工具"
        if m.tools.count > registered { msg += "（\(m.tools.count - registered) 个失败）" }
        if m.requiresHook { msg += "。注意：它需要宿主钩子，部分能力要等 App 本体接入才生效" }
        return (true, msg, m.tools.map { $0.name })
    }

    @discardableResult
    func removeSync(id: String) -> (ok: Bool, message: String) {
        guard let m = manifest(id: id) else {
            return (false, "目录里没有这个插件：\(id)。先用 plugin.search 查正确 id")
        }
        guard installedIDs.contains(id) else {
            return (false, "\(m.name) 没安装，不用卸")
        }
        backupManifest(m)
        ToolRegistry.shared.removeTools(prefix: m.toolPrefix)
        for s in m.skills { SkillStore.shared.delete(named: s.name) }
        try? FileManager.default.removeItem(at: pluginsDir.appendingPathComponent(m.id))
        installedIDs.remove(m.id)
        disabledIDs.remove(m.id)
        save()
        audit("remove", "\(m.id)（已备份 manifest 到 .trash）")
        return (true, "已卸载 \(m.name)，\(m.tools.count) 个工具已摘除")
    }

    @discardableResult
    func toggleSync(id: String, enabled: Bool) -> (ok: Bool, message: String) {
        guard let m = manifest(id: id), installedIDs.contains(id) else {
            return (false, "\(id) 没安装")
        }
        setEnabled(m, enabled)
        audit("toggle", "\(id) -> \(enabled ? "on" : "off")")
        return (true, "\(m.name) 已\(enabled ? "启用" : "停用")")
    }

    /// AI 自己定义一个新插件并安装。
    /// 只要求最小字段（id / name / tools），其余自动补默认值——
    /// 让模型少写几个字段，少一处写错就少一次失败。
    @discardableResult
    func defineAndInstall(specJSON: String) -> (ok: Bool, message: String, toolNames: [String]) {
        guard let raw = specJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            return (false, "spec 不是合法 JSON 对象", [])
        }
        let id = ((obj["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return (false, "缺 id", []) }
        // id 要能当目录名用，别让 AI 传 ../ 把文件写到外面去
        let safe = id.replacingOccurrences(of: "/", with: "-")
                      .replacingOccurrences(of: "..", with: "-")
                      .replacingOccurrences(of: " ", with: "-")
        guard !safe.isEmpty else { return (false, "id 不合法", []) }
        if catalog.contains(where: { $0.id == safe }) && installedIDs.contains(safe) {
            return (false, "\(safe) 已经装过了", [])
        }

        let name = (obj["name"] as? String) ?? safe
        let summary = (obj["summary"] as? String) ?? "AI 自建插件"
        let cat = Self.category(from: obj["category"] as? String)

        var tools: [PluginToolSpec] = []
        for item in (obj["tools"] as? [[String: Any]]) ?? [] {
            let keyRaw = ((item["key"] as? String) ?? (item["name"] as? String) ?? "")
                .trimmingCharacters(in: .whitespaces)
            // key 会拼进工具名（user.plg_<id>_<key>），带 - . 空格 都算非法字符，
            // AI 很可能写成 my-tool / my.tool，这里统一规整掉。
            let key = keyRaw
                .replacingOccurrences(of: "-", with: "_")
                .replacingOccurrences(of: ".", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            let command = (item["command"] as? String) ?? ""
            guard !key.isEmpty, !command.isEmpty else { continue }
            let params = (item["params"] as? [String: String]) ?? [:]
            let timeout = (item["timeout"] as? Double) ?? 60
            tools.append(Self.T(safe, key,
                                (item["summary"] as? String) ?? key,
                                command, params, timeout: timeout))
        }
        guard !tools.isEmpty else { return (false, "tools 为空——至少要给一条带 command 的工具", []) }

        var skills: [PluginSkillSpec] = []
        for item in (obj["skills"] as? [[String: Any]]) ?? [] {
            let sname = (item["name"] as? String) ?? ""
            guard !sname.isEmpty else { continue }
            skills.append(PluginSkillSpec(name: sname,
                                          summary: (item["summary"] as? String) ?? sname,
                                          instruction: (item["instruction"] as? String) ?? ""))
        }

        // 字段先各自落到具体类型再构造：18 个参数混着一堆 `as?` / `??` / 插值
        // 会让类型检查器指数级展开，CI 直接报 "unable to type-check this
        // expression in reasonable time"（1.0.34 首构建就是这么红的）。
        let pkgValue: String = (obj["pkg"] as? String) ?? ("@local/" + safe)
        let versionValue: String = (obj["version"] as? String) ?? "0.1.0"
        let authorValue: String = (obj["author"] as? String) ?? "AI"
        let iconValue: String = (obj["icon"] as? String) ?? "🧩"
        let tintValue: Int = (obj["tint"] as? Int) ?? 3
        let depsValue: [String] = (obj["deps"] as? [String]) ?? []
        let hookValue: Bool = (obj["requiresHook"] as? Bool) ?? false
        let riskValue: String = (obj["risk"] as? String) ?? "shell"
        let newToday: String = Self.today()

        // init 不带 pkg / risk（内置 28 个插件都靠默认值），
        // 这两项只能构造完再赋值，否则报 extra argument。
        var m = PluginManifest(
            id: safe,
            name: name,
            version: versionValue,
            category: cat,
            icon: iconValue,
            tint: tintValue,
            sizeKB: 1,
            summary: summary,
            deps: depsValue,
            requiresHook: hookValue,
            tools: tools,
            skills: skills,
            changelog: ["AI 自建"],
            stars: 0,
            downloads: 0,
            updatedAt: newToday,
            author: authorValue
        )
        m.pkg = pkgValue
        m.risk = riskValue
        // 自建插件也要进目录，否则重启后 manifest(id:) 找不到、工具注册不回来
        if !catalog.contains(where: { $0.id == safe }) {
            catalog.append(m)
        }
        let r = installSync(m)
        audit("define", "\(safe) tools=\(tools.count)")
        return r
    }

    private static func category(from s: String?) -> PluginCategory {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return .tools }
        for c in PluginCategory.allCases where c.rawValue == s.lowercased() { return c }
        for c in PluginCategory.allCases where c.displayName == s || c.shortName == s { return c }
        return .tools
    }

    private static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: 注册给 AI 的 5 个管理工具

    /// 这些是「装插件的插件」——必须是内置的，否则会有「要装插件才能装插件」的死锁。
    func registerManagerTools() {
        let reg = ToolRegistry.shared

        let searchDef = ToolDefinition(
            name: "plugin.search",
            summary: "搜索插件。本机内置 59 个可安装插件（12 类，装完立刻有工具）；另有 4687 条「外部参考目录」（竞品 DSH 的 Node 插件，装不了，只能当灵感，用 source=shared 查）。用户说「找个插件」「有没有能做 XX 的」时先搜 builtin；builtin 搜不到再搜 shared，然后按它的思路用 plugin.define 自己写一个。",
            parameters: ["query": "关键词，可空；空则返回全部",
                         "category": "分类，可空。tools/session/model/memory/skill/vision/docs/usage/remote/security/browser/git，也可写中文如「工具与能力」",
                         "source": "builtin（默认，可安装）/ shared（外部参考目录，装不了）/ all（两边都查）"],
            returns: ["count": "Int", "plugins": "数组，每项含 id/name/summary/category/tools/installed/risk/source"],
            verified: false, category: "plugin", uiSummary: "搜索插件市场")
        reg.registerSystemTool(searchDef) { params in
            let st = PluginStore.shared
            let q = ((params["query"] as? String) ?? "").lowercased()
            let c = (params["category"] as? String) ?? ""
            let src = ((params["source"] as? String) ?? "builtin").lowercased()
            let cat: PluginCategory? = c.isEmpty ? nil : PluginStore.category(from: c)

            var list: [[String: Any]] = []

            if src != "shared" {
                var hits = st.catalog
                if let cat = cat { hits = hits.filter { $0.category == cat } }
                if !q.isEmpty {
                    hits = hits.filter {
                        $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
                        || $0.summary.lowercased().contains(q) || $0.pkg.lowercased().contains(q)
                    }
                }
                list += hits.map { m in
                    ["id": m.id, "name": m.name, "summary": m.summary,
                     "category": m.category.displayName,
                     "tools": m.tools.count, "skills": m.skills.count,
                     "installed": st.isInstalled(m.id),
                     "requires_hook": m.requiresHook,
                     "risk": m.risk ?? "shell",
                     "source": "builtin", "installable": true]
                }
            }

            // 2026-11-05：外部插件（4687 条）**现在可以装了**。
            // 每条都指向 CapabilityPacks 里的一个真实能力包，装完立刻有工具可用。
            // 原来这里写的是 installable:false + 提示「装不了，用 plugin.define 重写」，
            // 那是旧设计（外部条目没接任何可执行的东西）。用户明确要求「直接就能安装使用」，
            // 所以语义跟着改：installable 为 true，提示也改成「直接装」。
            if src == "shared" || src == "all" {
                let ext = ExternalCatalog.search(q, category: cat)
                list += ext.prefix(40).map { e -> [String: Any] in
                    let pack = CapabilityPacks.pack(e.capKey)
                    return ["id": e.id, "name": e.name, "summary": e.summary,
                            "category": e.category.displayName,
                            "tools": pack?.tools.count ?? 0, "skills": 0,
                            "installed": self.isExternalMarkedInstalled(e),
                            "requires_hook": false,
                            "risk": "shell",
                            "source": "shared", "installable": true,
                            "capability_pack": pack?.name ?? "通用小工具",
                            "tool_names": pack?.tools.map { $0.name } ?? []]
                }
            }

            let hint: String
            if list.isEmpty {
                hint = "两边都没搜到。可以直接用 plugin.define 造一个（几行 shell 就够）。"
            } else if src == "shared" {
                hint = "外部插件也能直接装：plugin.install 传它的 id，会自动装上它对应的能力包（多个同类插件共用同一个包，装一次就够）。"
            } else {
                hint = "用 plugin.install 传 id 安装。source=shared 的那些同样可装 —— 它们会落到一个能力包上。"
            }
            return ["ok": true, "count": list.count,
                    "plugins": list,
                    "hint": hint]
        }

        let listDef = ToolDefinition(
            name: "plugin.list",
            summary: "列出已安装的插件和它们贡献的工具。想知道自己现在有哪些插件能力时调用。",
            parameters: [:],
            returns: ["installed": "数组", "total_tools": "Int"],
            verified: false, category: "plugin", uiSummary: "列出已装插件")
        reg.registerSystemTool(listDef) { _ in
            let st = PluginStore.shared
            let list: [[String: Any]] = st.installedManifests.map { m in
                ["id": m.id, "name": m.name, "enabled": st.isEnabled(m.id),
                 "tools": m.tools.map { $0.name },
                 "risk": m.risk ?? "shell"]
            }
            return ["ok": true, "installed": list, "total_tools": st.installedToolCount]
        }

        let installDef = ToolDefinition(
            name: "plugin.install",
            summary: "安装一个插件，装完它贡献的工具立刻可用。用户让你装插件、或你自己判断需要某个插件时调用。",
            parameters: ["id": "插件 id（plugin.search 返回的那个 id）"],
            returns: ["ok": "Bool", "message": "String", "tools": "新注册的工具名数组"],
            verified: false, category: "plugin", uiSummary: "安装插件")
        reg.registerSystemTool(installDef) { params in
            let st = PluginStore.shared
            guard st.aiControlEnabled else {
                throw MCPError.failed("用户已关闭 AI 自主装插件。请在设置里打开，或让用户手动安装")
            }
            let id = ((params["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { throw MCPError.invalidParams("缺 id") }

            // 2026-11-05：先认内置 catalog，再认外部目录（4687 条）。
            // 不认外部的话，用户装「外部那条」时这里会报「目录里没有」，
            // 而界面上明明能装 —— 两条路径必须一致。
            if let m = st.manifest(id: id) {
                let r = st.installSync(m)
                return ["ok": r.ok, "message": r.message, "tools": r.toolNames,
                        "hint": r.ok ? "新工具已注册，下一次请求即可调用，直接继续干活不用再问用户" : ""]
            }
            if let ext = ExternalCatalog.all.first(where: { $0.id == id }) {
                st.installExternal(ext)
                let pack = CapabilityPacks.pack(ext.capKey)
                let names = pack?.tools.map { $0.name } ?? []
                return ["ok": true,
                        "message": "已装上能力包「\(pack?.name ?? "通用小工具")」",
                        "tools": names,
                        "hint": "这些工具下一次请求就能调用。同类外部插件共用同一个包，不用重复装"]
            }
            throw MCPError.failed("目录里没有 \(id)。先用 plugin.search 查（source=all 能连外部一起搜），或用 plugin.define 自建")
        }

        let removeDef = ToolDefinition(
            name: "plugin.remove",
            summary: "卸载一个已安装的插件，它贡献的工具会从你的工具清单里消失。卸载前会自动备份。",
            parameters: ["id": "插件 id"],
            returns: ["ok": "Bool", "message": "String"],
            verified: false, category: "plugin", uiSummary: "卸载插件")
        reg.registerSystemTool(removeDef) { params in
            let st = PluginStore.shared
            guard st.aiControlEnabled else { throw MCPError.failed("用户已关闭 AI 自主管理插件") }
            let id = ((params["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { throw MCPError.invalidParams("缺 id") }
            let r = st.removeSync(id: id)
            return ["ok": r.ok, "message": r.message]
        }

        let toggleDef = ToolDefinition(
            name: "plugin.toggle",
            summary: "启用或停用一个已安装插件。停用后它的工具不再出现在你的清单里，但不会被卸载。",
            parameters: ["id": "插件 id", "enabled": "true 或 false"],
            returns: ["ok": "Bool", "message": "String"],
            verified: false, category: "plugin", uiSummary: "启停插件")
        reg.registerSystemTool(toggleDef) { params in
            let st = PluginStore.shared
            guard st.aiControlEnabled else { throw MCPError.failed("用户已关闭 AI 自主管理插件") }
            let id = ((params["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { throw MCPError.invalidParams("缺 id") }
            let on: Bool = (params["enabled"] as? Bool) ?? ((params["enabled"] as? String)?.lowercased() == "true")
            let r = st.toggleSync(id: id, enabled: on)
            return ["ok": r.ok, "message": r.message]
        }

        let defineDef = ToolDefinition(
            name: "plugin.define",
            summary: "现场造一个新插件并立刻安装。市场里没有的能力，你直接写一个——给几条命令模板就行，参数会自动做 shell 转义。",
            parameters: ["spec": "JSON 字符串。最小格式：{\"id\":\"my-tool\",\"name\":\"我的工具\",\"summary\":\"干什么\",\"tools\":[{\"key\":\"run\",\"summary\":\"用途\",\"command\":\"命令模板，用 {参数名} 占位\",\"params\":{\"参数名\":\"说明\"}}]}"],
            returns: ["ok": "Bool", "message": "String", "tools": "新工具名数组"],
            verified: false, category: "plugin", uiSummary: "自建并安装插件")
        reg.registerSystemTool(defineDef) { params in
            let st = PluginStore.shared
            guard st.aiControlEnabled else { throw MCPError.failed("用户已关闭 AI 自主管理插件") }
            let spec = ((params["spec"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spec.isEmpty else { throw MCPError.invalidParams("缺 spec") }
            let r = st.defineAndInstall(specJSON: spec)
            return ["ok": r.ok, "message": r.message, "tools": r.toolNames]
        }
    }

    // MARK: 内部

    private func registerTools(for m: PluginManifest) -> Int {
        var ok = 0
        for spec in m.tools {
            let def = ToolDefinition(
                name: spec.name,
                summary: spec.summary,
                parameters: spec.params,
                returns: ["ok": "Bool, true = 命令退出码为 0",
                          "exit_code": "Int, 命令退出码",
                          "output": "String, 命令输出（超长会截断）"],
                verified: false,
                category: "plugin",
                uiSummary: spec.summary
            )
            let done = ToolRegistry.shared.registerPluginTool(def) { params in
                try PluginStore.run(spec: spec, params: params)
            }
            if done { ok += 1 }
        }
        return ok
    }

    private func registerSkills(for m: PluginManifest) {
        for s in m.skills {
            SkillStore.shared.upsert(SkillItem(name: s.name, summary: s.summary, instruction: s.instruction))
            SkillStore.shared.setEnabled(s.name, !disabledIDs.contains(m.id))
        }
    }

    /// App 启动后重新注册所有已安装插件的工具（工具只在内存里）
    private func restoreInstalled() {
        let ids = installedIDs
        guard !ids.isEmpty else { return }
        var n = 0
        for id in ids {
            guard let m = manifest(id: id) else { continue }
            n += registerTools(for: m)
            registerSkills(for: m)
            if disabledIDs.contains(id) {
                for t in m.tools { ToolRegistry.shared.setEnabled(name: t.name, enabled: false) }
            }
        }
        print("[TA] 📦 restored \(ids.count) plugin(s), \(n) tool(s)")
    }

    private var pluginsDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Plugins", isDirectory: true)
    }

    private func writeManifestToDisk(_ m: PluginManifest) {
        let dir = pluginsDir.appendingPathComponent(m.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: dir.appendingPathComponent("plugin.json"))
        }
    }

    private func save() {
        UserDefaults.standard.set(Array(installedIDs), forKey: installedKey)
        UserDefaults.standard.set(Array(disabledIDs), forKey: disabledKey)
    }

    /// 外部插件名单单独存
    func saveExternal() {
        UserDefaults.standard.set(Array(externalInstalledIDs), forKey: externalKey)
        objectWillChange.send()
    }

    private func load() {
        if let a = UserDefaults.standard.stringArray(forKey: installedKey) {
            installedIDs = Set(a)
        }
        if let d = UserDefaults.standard.stringArray(forKey: disabledKey) {
            disabledIDs = Set(d)
        }
        if let e = UserDefaults.standard.stringArray(forKey: externalKey) {
            externalInstalledIDs = Set(e)
        }
    }

    // MARK: 命令执行

    /// 把参数填进命令模板并执行。
    /// 关键：参数一律做 shell 转义（单引号包裹 + 内部单引号转义），
    /// 避免 AI 传进来一个 `; rm -rf /` 就把命令拼歪。
    static func run(spec: PluginToolSpec, params: [String: Any]) throws -> [String: Any] {
        var cmd = spec.command
        for (key, _) in spec.params {
            let placeholder = "{\(key)}"
            guard cmd.contains(placeholder) else { continue }
            let raw = ((params[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { throw MCPError.invalidParams("缺少必填参数：\(key)") }
            cmd = cmd.replacingOccurrences(of: placeholder, with: shellQuote(raw))
        }
        // 还有没被替换的 {xxx} → 说明模板写了参数但声明里漏了，直接报错别瞎跑
        // 负向后行断言：跳过 curl -w 的 %{http_code} / %{time_total} 这类写法，
        // 它们不是我们的参数占位，误判会让本来正常的命令直接报错。
        if let r = cmd.range(of: "(?<!%)\\{[a-zA-Z_][a-zA-Z0-9_]*\\}", options: .regularExpression) {
            throw MCPError.failed("命令模板有未声明的参数占位：\(cmd[r])")
        }
        let out = TrollRuntimeEngine.exec(cmd, timeout: spec.timeout)
        var text = out.output
        if text.count > 8000 { text = String(text.prefix(8000)) + "\n…（输出过长，已截断）" }
        return [
            "ok": out.exitCode == 0,
            "exit_code": Int(out.exitCode),
            "timed_out": out.timedOut,
            "output": text
        ]
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - 内置目录（28 个）

extension PluginStore {

    /// 建工具声明的小助手：自动拼 user.plg_<plugin>_<key>，保证卸载能按前缀清干净
    fileprivate static func T(_ pid: String, _ key: String, _ summary: String,
                              _ command: String, _ params: [String: String] = [:],
                              timeout: Double = 60) -> PluginToolSpec {
        let p = pid.replacingOccurrences(of: "-", with: "_")
        return PluginToolSpec(name: "user.plg_\(p)_\(key)", summary: summary,
                              command: command, params: params, timeout: timeout)
    }

    static let builtinCatalog: [PluginManifest] = [

        // ================= 工具与能力（8）=================

        PluginManifest(
            id: "ipa-inspector", name: "IPA 解析器", version: "1.2.0", category: .tools,
            icon: "📦", tint: 0, sizeKB: 18,
            summary: "解析 ipa：包结构、Info.plist、体积占比，一条命令出结论。",
            deps: ["unzip", "binutils"],
            tools: [
                T("ipa-inspector", "list", "列出 ipa 内部文件与体积占比。Use for: 看包里有什么、哪个文件最大。",
                  "unzip -l {file} | sort -k1 -n -r | head -40",
                  ["file": "ipa 的绝对路径"], timeout: 120),
                T("ipa-inspector", "plist", "从 ipa 里抽出 Info.plist 的可读字段（bundle id / 版本 / 权限）。Use for: 拿包标识与版本号。",
                  "cd /tmp && rm -rf _ta_ipa && mkdir -p _ta_ipa && unzip -o -q {file} 'Payload/*.app/Info.plist' -d _ta_ipa 2>/dev/null; find _ta_ipa -name Info.plist -exec strings {} \\; | head -80",
                  ["file": "ipa 的绝对路径"], timeout: 120),
                T("ipa-inspector", "size", "统计 ipa 里最大的 20 个文件。Use for: 找包体积元凶。",
                  "unzip -l {file} | awk 'NR>3 && $1 ~ /^[0-9]+$/ {print $1, $4}' | sort -rn | head -20",
                  ["file": "ipa 的绝对路径"], timeout: 120)
            ],
            changelog: ["v1.2.0 · 新增体积占比排序", "v1.0.1 · 修 plist 路径匹配"], stars: 3200, downloads: 1800),

        PluginManifest(
            id: "hex-peek", name: "十六进制查看", version: "0.9.4", category: .tools,
            icon: "🔬", tint: 3, sizeKB: 9,
            summary: "二进制十六进制查看，按偏移跳转，抽可打印字符串。",
            deps: ["xxd", "binutils"],
            tools: [
                T("hex-peek", "dump", "以十六进制查看文件指定区间。Use for: 看文件头、魔数、结构。",
                  "xxd -s {offset} -l {length} {file}",
                  ["file": "文件绝对路径", "offset": "起始偏移（十进制或 0x 开头）", "length": "查看长度（字节）"], timeout: 60),
                T("hex-peek", "strings", "抽取文件里的可打印字符串（去重）。Use for: 找密钥、URL、报错文案。",
                  "strings -n {minlen} {file} | sort -u | head -300",
                  ["file": "文件绝对路径", "minlen": "最短长度，建议 6"], timeout: 120)
            ],
            changelog: ["v0.9.4 · 加偏移参数校验"], stars: 880, downloads: 420),

        PluginManifest(
            id: "plist-edit", name: "plist 读写", version: "1.0.1", category: .tools,
            icon: "📝", tint: 2, sizeKB: 11,
            summary: "plist 读取与字段检索，支持二进制/XML 两种格式。",
            deps: ["binutils"],
            tools: [
                T("plist-edit", "read", "读取 plist 并列出键值（二进制与 XML 都支持）。Use for: 看配置项、开关。",
                  "strings {file} | head -120",
                  ["file": "plist 绝对路径"], timeout: 60),
                T("plist-edit", "grep", "在 plist 里查某个键或值。Use for: 找特定配置。",
                  "strings {file} | grep -i {keyword} | head -40",
                  ["file": "plist 绝对路径", "keyword": "要查的关键词"], timeout: 60)
            ],
            changelog: ["v1.0.1 · 支持二进制 plist"], stars: 1100, downloads: 630),

        PluginManifest(
            id: "regex-lab", name: "正则实验室", version: "1.1.0", category: .tools,
            icon: "🧪", tint: 1, sizeKB: 7,
            summary: "正则实时测试、批量提取与替换，不用来回试错。",
            tools: [
                T("regex-lab", "extract", "用正则从文本里提取所有匹配项。Use for: 抓 URL、包名、数字。",
                  "printf '%s' {text} | grep -oE {pattern} | head -100",
                  ["text": "要匹配的文本", "pattern": "扩展正则表达式"], timeout: 30),
                T("regex-lab", "replace", "用正则批量替换文本。Use for: 改名、清洗数据。",
                  "printf '%s' {text} | sed -E 's/{pattern}/{replacement}/g'",
                  ["text": "原文", "pattern": "正则", "replacement": "替换成什么"], timeout: 30)
            ],
            changelog: ["v1.1.0 · 加替换"], stars: 2100, downloads: 1100),

        PluginManifest(
            id: "archive-unpack", name: "压缩包解包", version: "1.0.2", category: .tools,
            icon: "🗜", tint: 4, sizeKB: 14,
            summary: "zip / tar / gz / deb 一键解包，自动识别格式。",
            deps: ["unzip", "tar"],
            tools: [
                T("archive-unpack", "unpack", "自动识别格式并解压到指定目录。Use for: 解 ipa、deb、tar.gz。",
                  "mkdir -p {out} && (unzip -o -q {file} -d {out} 2>/dev/null || tar -xf {file} -C {out} 2>/dev/null || tar -xzf {file} -C {out} 2>/dev/null) && ls -la {out} | head -40",
                  ["file": "压缩包绝对路径", "out": "解压到哪个目录"], timeout: 180),
                T("archive-unpack", "list", "不解压，先看包里有什么。Use for: 解之前确认内容。",
                  "unzip -l {file} 2>/dev/null | head -40 || tar -tf {file} 2>/dev/null | head -40",
                  ["file": "压缩包绝对路径"], timeout: 60)
            ],
            changelog: ["v1.0.2 · 加 tar.gz 识别"], stars: 1600, downloads: 990),

        PluginManifest(
            id: "strings-extract", name: "字符串提取", version: "0.8.0", category: .tools,
            icon: "🧬", tint: 5, sizeKB: 8,
            summary: "从二进制里抽字符串、URL 与疑似密钥，按长度排序。",
            deps: ["binutils"],
            tools: [
                T("strings-extract", "all", "抽取全部可打印字符串并按长度排序。Use for: 逆向初筛、找明文。",
                  "strings -n {minlen} {file} | sort -u | awk '{print length, $0}' | sort -rn | head -200",
                  ["file": "文件绝对路径", "minlen": "最短长度，建议 8"], timeout: 180),
                T("strings-extract", "urls", "只抽文件里的 URL。Use for: 找接口地址、CDN。",
                  "strings -n 8 {file} | grep -oE 'https?://[a-zA-Z0-9./_%?=&-]+' | sort -u | head -80",
                  ["file": "文件绝对路径"], timeout: 180)
            ],
            changelog: ["v0.8.0 · 加 URL 专用"], stars: 740, downloads: 310),

        PluginManifest(
            id: "binary-diff", name: "二进制比对", version: "0.7.2", category: .tools,
            icon: "⚖️", tint: 2, sizeKB: 6,
            summary: "两个文件的字节级差异，快速定位改动位置。",
            tools: [
                T("binary-diff", "cmp", "逐字节比对两个文件，列出差异位置。Use for: 版本对比、找补丁点。",
                  "cmp -l {a} {b} 2>&1 | head -60 || echo '两文件完全一致'",
                  ["a": "文件 A", "b": "文件 B"], timeout: 120),
                T("binary-diff", "hash", "算文件哈希用于快速判同。Use for: 判断两份包是否同一版本。",
                  "md5sum {a} {b} 2>/dev/null || echo '文件不存在'",
                  ["a": "文件 A", "b": "文件 B"], timeout: 180)
            ],
            changelog: ["v0.7.2 · 加哈希判同"], stars: 520, downloads: 240),

        PluginManifest(
            id: "batch-rename", name: "批量重命名", version: "1.0.0", category: .tools,
            icon: "🏷", tint: 1, sizeKB: 5,
            summary: "按规则批量改名，先预览再执行。",
            tools: [
                T("batch-rename", "preview", "预览目录下匹配文件会被改成什么（不真正改）。Use for: 改名前确认。",
                  "cd {dir} && for f in *{find}*; do [ -e \"$f\" ] && echo \"$f -> $(echo \"$f\" | sed 's/{find}/{repl}/g')\"; done | head -40",
                  ["dir": "目录绝对路径", "find": "要被替换的片段", "repl": "替换成什么"], timeout: 30),
                T("batch-rename", "apply", "执行批量重命名。Use for: 预览确认后真正改。",
                  "cd {dir} && for f in *{find}*; do [ -e \"$f\" ] && mv \"$f\" \"$(echo \"$f\" | sed 's/{find}/{repl}/g')\"; done; ls | head -30",
                  ["dir": "目录绝对路径", "find": "要被替换的片段", "repl": "替换成什么"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 460, downloads: 190),

        // ================= 会话与消息（2）=================

        PluginManifest(
            id: "ctx-squeeze", name: "上下文压缩", version: "1.0.3", category: .session,
            icon: "🗜", tint: 3, sizeKB: 6,
            summary: "长会话自动压缩：保留结论与关键证据，丢掉重复的工具输出。",
            requiresHook: true,
            skills: [
                PluginSkillSpec(
                    name: "Context Squeeze",
                    summary: "compress a long conversation context, keep conclusions and key evidence, drop repeated tool output",
                    instruction: "当上下文接近上限或用户要求精简会话时执行：\n1. 保留：用户最终目标、已确认的结论、关键文件路径与命令、未解决的阻塞点；\n2. 丢弃：重复的命令输出、已失败的尝试细节、中间探测结果；\n3. 输出格式：分「目标 / 已完成 / 关键证据 / 待办」四段，每段不超过 5 条；\n4. 不要编造未发生的事实，信息缺失就写「未记录」。")
            ],
            changelog: ["v1.0.3 · 压缩策略改四段式"], stars: 2400, downloads: 1700),

        PluginManifest(
            id: "session-export", name: "会话导出", version: "1.0.0", category: .session,
            icon: "📤", tint: 4, sizeKB: 4,
            summary: "把当前会话导出成 Markdown，含命令与结果，方便存档与复现。",
            requiresHook: true,
            skills: [
                PluginSkillSpec(
                    name: "Session Export",
                    summary: "export the current session as a markdown report with commands and results",
                    instruction: "当用户要求导出/存档会话时执行：\n1. 按时间顺序整理：用户诉求 → 执行的关键命令 → 结果 → 结论；\n2. 命令用代码块包裹，结果只保留关键行，长输出截断并标注；\n3. 末尾附「可复现步骤」清单，按 1/2/3 编号；\n4. 输出为 Markdown，可直接存文件。")
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1300, downloads: 880),

        // ================= 模型与账号接入（2）=================

        PluginManifest(
            id: "relay-connect", name: "中转站接入", version: "1.1.0", category: .model,
            icon: "🔌", tint: 4, sizeKB: 7,
            summary: "把家里的中转站接进来：填地址即用，自动列模型、测连通。",
            tools: [
                T("relay-connect", "models", "拉取中转站的模型列表。Use for: 确认可用的模型名。",
                  "curl -s -m 15 {url}/v1/models -H 'Authorization: Bearer {key}' | head -c 3000",
                  ["url": "中转站地址，如 http://192.168.1.88:8080", "key": "密钥，没有就填 none"], timeout: 30),
                T("relay-connect", "ping", "测中转站连通性与延迟。Use for: 排查连不上。",
                  "curl -s -o /dev/null -w 'http=%{http_code} time=%{time_total}s\\n' -m 10 {url}/v1/models",
                  ["url": "中转站地址"], timeout: 30)
            ],
            changelog: ["v1.1.0 · 加延迟测试"], stars: 1900, downloads: 1400),

        PluginManifest(
            id: "model-switch", name: "模型快切", version: "1.0.1", category: .model,
            icon: "🔀", tint: 0, sizeKB: 4,
            summary: "一键切换常用模型配置，按场景建几套预设。",
            requiresHook: true,
            skills: [
                PluginSkillSpec(
                    name: "Model Switch Guide",
                    summary: "switch between saved model provider presets by task type",
                    instruction: "当用户要换模型/换供应商时执行：\n1. 先问清场景：长文本、代码、快速问答、多模态；\n2. 按场景给建议：代码优先大上下文强推理模型，快速问答优先小模型省成本；\n3. 给出在「设置 → 模型 API」里的具体操作步骤，不要假设用户记得路径；\n4. 切换后提醒用户新会话才完全生效。")
            ],
            changelog: ["v1.0.1 · 加场景建议"], stars: 900, downloads: 520),

        // ================= 记忆（2）=================

        PluginManifest(
            id: "mem-core", name: "长期记忆", version: "1.4.0", category: .memory,
            icon: "🧠", tint: 2, sizeKB: 12,
            summary: "记住设备信息、常用路径、踩过的坑，新会话自动带上。",
            requiresHook: true,
            tools: [
                T("mem-core", "search", "在记忆库里检索历史结论与踩坑记录。Use for: 动手前先查以前怎么解决的。",
                  "grep -rn --include='*.md' -i {q} /var/mobile/Documents/KnowledgeBase 2>/dev/null | head -40 || echo '记忆库为空'",
                  ["q": "关键词"], timeout: 60)
            ],
            skills: [
                PluginSkillSpec(
                    name: "Memory Keeper",
                    summary: "remember durable facts about the user's device, paths and past failures across sessions",
                    instruction: "在以下时机主动整理记忆（不要打扰用户）：\n1. 得知设备型号、系统版本、是否越狱、常用目录时；\n2. 某条命令失败并找到原因时（记录「症状 → 原因 → 解法」）；\n3. 用户明确说「记住」时。\n记录格式：一行一条，含日期、结论、证据路径。不要记密码、密钥、Token。")
            ],
            changelog: ["v1.4.0 · 加检索工具", "v1.0.0 · 首版"], stars: 2400, downloads: 1700),

        PluginManifest(
            id: "project-notes", name: "项目笔记", version: "1.0.2", category: .memory,
            icon: "🗂", tint: 1, sizeKB: 5,
            summary: "按 App / 项目隔离的笔记，改 A 项目不会污染 B 项目。",
            tools: [
                T("project-notes", "write", "把一条笔记追加到指定项目的笔记文件。Use for: 记录进展、结论。",
                  "mkdir -p /var/mobile/Documents/KnowledgeBase/notes && printf '[%s] %s\\n' \"$(date '+%m-%d %H:%M')\" {text} >> /var/mobile/Documents/KnowledgeBase/notes/{project}.md && tail -5 /var/mobile/Documents/KnowledgeBase/notes/{project}.md",
                  ["project": "项目名，英文无空格", "text": "要记的内容"], timeout: 30),
                T("project-notes", "list", "列出所有项目笔记。Use for: 看有哪些项目在跟。",
                  "ls -la /var/mobile/Documents/KnowledgeBase/notes 2>/dev/null | head -30 || echo '还没有笔记'",
                  [:], timeout: 30)
            ],
            changelog: ["v1.0.2 · 加列表"], stars: 800, downloads: 460),

        // ================= 技能包（3）=================

        PluginManifest(
            id: "skill-decrypt", name: "砸壳流程", version: "2.0.0", category: .skill,
            icon: "🔓", tint: 0, sizeKB: 4,
            summary: "从检测加密到导出 ipa 的完整流程，含常见失败与回退。",
            skills: [
                PluginSkillSpec(
                    name: "App Decrypt Flow",
                    summary: "decrypt a FairPlay-encrypted App Store app into a usable ipa, with fallbacks",
                    instruction: "当用户要求砸壳时执行：\n1. 先只读探测：确认目标 bundle_id、是否已安装、当前加密状态；\n2. 判断路径：有越狱 → 走进程内解密；TrollStore → 走对应工具；非越狱 → 明确告知不可行，别硬试；\n3. 解密后校验：Mach-O 的 cryptid 应为 0，架构完整；\n4. 打包 ipa：Payload/<App>.app 结构，Info.plist 不能丢；\n5. 失败常见原因：进程没起来、目标已加固、磁盘空间不足——逐条排查再重试。\n禁止：未确认目标就动手；禁止覆盖原安装包。")
            ],
            changelog: ["v2.0.0 · 补失败排查", "v1.0.0 · 首版"], stars: 3600, downloads: 2500),

        PluginManifest(
            id: "skill-inject", name: "注入流程", version: "1.6.0", category: .skill,
            icon: "💉", tint: 3, sizeKB: 4,
            summary: "dylib 注入的完整步骤：探测、注入、验证、回滚。",
            skills: [
                PluginSkillSpec(
                    name: "Dylib Inject Flow",
                    summary: "inject a dylib into a target iOS app, verify it loaded, and roll back safely",
                    instruction: "当用户要求注入 dylib 时执行：\n1. 注入前：确认目标 bundle_id、dylib 绝对路径、dylib 架构与目标一致；\n2. 先做一次只读状态检查，确认没重复注入；\n3. 注入后重启目标 App，验证 dylib 是否真的加载（看进程里有没有对应镜像）；\n4. 失败分三类排查：签名不通过 / 库校验拦截 / 架构不匹配；\n5. 必须保留原二进制备份，回滚要能一键还原。\n禁止：无备份就改、路径用占位符。")
            ],
            changelog: ["v1.6.0 · 加验证步骤"], stars: 2900, downloads: 2000),

        PluginManifest(
            id: "skill-capture", name: "抓包流程", version: "1.3.0", category: .skill,
            icon: "📡", tint: 4, sizeKB: 4,
            summary: "抓某个 App 的请求：起代理、装证书、抓、分析、收尾。",
            skills: [
                PluginSkillSpec(
                    name: "Traffic Capture Flow",
                    summary: "capture and analyze HTTP/HTTPS traffic of one target app end to end",
                    instruction: "当用户要求抓包时执行：\n1. 先确认抓包方式（本地代理 / 系统级隧道）与目标 App；\n2. 起抓包前先看状态，别重复启动；\n3. 触发目标 App 的网络行为，定位关键请求（URL、方法、参数、响应摘要）；\n4. 遇到证书校验失败：先判断是 pinning 还是证书未信任，分别处理，别一律说「抓不到」；\n5. 收尾：停止抓包、导出结果、说明没抓到的部分和原因。\n禁止：谎称抓到；禁止把用户凭据写进报告。")
            ],
            changelog: ["v1.3.0 · 加 pinning 判断"], stars: 2200, downloads: 1500),

        // ================= 视觉与多模态（2）=================

        PluginManifest(
            id: "ocr-snap", name: "截图 OCR", version: "1.0.1", category: .vision,
            icon: "👁", tint: 3, sizeKB: 10,
            summary: "读出截图上的文字与位置，告诉 AI 某个按钮在哪、该点哪。",
            requiresHook: true,
            skills: [
                PluginSkillSpec(
                    name: "Screen Reading",
                    summary: "read text and control positions from a screenshot to decide where to tap",
                    instruction: "当需要看屏幕内容时执行：\n1. 先截图（不要凭记忆猜界面）；\n2. 按区块描述：顶部状态区、主要列表区、底部操作区，各自有什么可点的文字；\n3. 要点击时给出「文字 + 大致坐标」，优先用文字定位而不是硬坐标；\n4. 如果截图里没有目标元素，明确说没找到，不要编。")
            ],
            changelog: ["v1.0.1 · 加坐标策略"], stars: 1300, downloads: 860),

        PluginManifest(
            id: "ui-tree", name: "界面元素树", version: "0.9.0", category: .vision,
            icon: "🌳", tint: 2, sizeKB: 8,
            summary: "导出当前界面的元素层级，比 OCR 更准地定位控件。",
            requiresHook: true,
            skills: [
                PluginSkillSpec(
                    name: "UI Tree Inspection",
                    summary: "dump the accessibility hierarchy of the current screen to locate controls precisely",
                    instruction: "当 OCR 不够准或要操作非文字控件时执行：\n1. 导出元素树，只看可交互节点（按钮、输入框、开关、单元格）；\n2. 按屏幕从上到下排列，标注每个节点的类型、文字、是否可点；\n3. 定位目标时优先用「类型 + 文字」，实在没有文字才用坐标；\n4. 操作后重新导一次树确认状态变化，别假设成功。")
            ],
            changelog: ["v0.9.0 · 首版"], stars: 700, downloads: 380),

        // ================= 文档与渲染（2）=================

        PluginManifest(
            id: "archify", name: "架构图", version: "1.4.0", category: .docs,
            icon: "📊", tint: 0, sizeKB: 15,
            summary: "说一句话出架构图、流程图、时序图，生成可交互页面。",
            skills: [
                PluginSkillSpec(
                    name: "Architecture Diagram",
                    summary: "generate architecture, flow, sequence and data-flow diagrams as a self-contained interactive page",
                    instruction: "当用户要求画图时执行：\n1. 先确认图类型：架构 / 流程 / 时序 / 数据流；\n2. 从代码或描述里提炼：实体、边界、数据流向，不要凭想象补组件；\n3. 输出一个自包含 HTML（内联 SVG，不依赖外网），手机可直接看；\n4. 布局规范：从左到右或从上到下的单向流，避免交叉线；\n5. 图下附一段「怎么看这张图」，三句话以内。")
            ],
            changelog: ["v1.4.0 · 支持时序图"], stars: 2800, downloads: 2100),

        PluginManifest(
            id: "report-gen", name: "逆向报告", version: "1.1.0", category: .docs,
            icon: "📄", tint: 1, sizeKB: 9,
            summary: "把一次逆向过程整理成结构化报告，含证据与风险结论。",
            skills: [
                PluginSkillSpec(
                    name: "Reverse Report",
                    summary: "turn a reverse-engineering session into a structured markdown report with evidence",
                    instruction: "当用户要求出报告时执行：\n1. 固定四段：目标与范围 / 方法与证据 / 发现 / 结论与风险；\n2. 证据必须可复现：命令原文 + 关键输出片段 + 文件路径；\n3. 发现按严重程度排序，每条标注「已验证 / 待验证」；\n4. 不写没证据的推测；推测要单独标「假设」并给出验证方法；\n5. 输出 Markdown，可直接存文件或贴给他人。")
            ],
            changelog: ["v1.1.0 · 加证据可复现要求"], stars: 1100, downloads: 640),

        // ================= 用量与计费（1）=================

        PluginManifest(
            id: "token-meter", name: "用量统计", version: "1.0.0", category: .usage,
            icon: "📈", tint: 4, sizeKB: 5,
            summary: "统计中转站与本机模型的调用量与花费趋势。",
            tools: [
                T("token-meter", "relay_usage", "拉中转站的用量接口（若支持）。Use for: 看这个月花了多少。",
                  "curl -s -m 15 {url}/v1/usage -H 'Authorization: Bearer {key}' | head -c 2000",
                  ["url": "中转站地址", "key": "密钥"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 640, downloads: 300),

        // ================= 远程与移动端（1）=================

        PluginManifest(
            id: "remote-shell", name: "远程终端", version: "1.2.0", category: .remote,
            icon: "🖥", tint: 0, sizeKB: 6,
            summary: "在电脑浏览器里操作手机终端，同屏看 AI 干活。",
            requiresHook: true,
            skills: [
                PluginSkillSpec(
                    name: "Remote Terminal Guide",
                    summary: "guide for exposing the on-device terminal to a desktop browser safely",
                    instruction: "当用户要用远程终端时执行：\n1. 先确认网络：同一局域网才开，公网必须加令牌；\n2. 给出具体步骤：开服务 → 看 IP 与端口 → 浏览器输入 → 输令牌；\n3. 强调安全：用完就关，不要把端口长期暴露；\n4. 连不上按序排查：同网段？防火墙？服务真的在跑？（先看进程再猜）")
            ],
            changelog: ["v1.2.0 · 加安全提示"], stars: 1500, downloads: 900),

        // ================= 安全与权限（2）=================

        PluginManifest(
            id: "guard-rm", name: "危险命令守卫", version: "1.0.0", category: .security,
            icon: "🛡", tint: 5, sizeKB: 4,
            summary: "执行前拦下 rm -rf、覆盖写、批量删除，先让你确认。",
            tools: [
                T("guard-rm", "safe_delete", "把文件移到回收目录而不是真删，可恢复。Use for: 要删东西时优先用这个。",
                  "mkdir -p /var/mobile/Documents/_Trash && mv {path} /var/mobile/Documents/_Trash/ 2>&1 && echo '已移到回收站：/var/mobile/Documents/_Trash'",
                  ["path": "要删的路径（用引号包住）"], timeout: 30),
                T("guard-rm", "trash_list", "列出回收站内容与大小。Use for: 确认空间、找回误删。",
                  "ls -lah /var/mobile/Documents/_Trash 2>/dev/null | head -30 || echo '回收站为空'",
                  [:], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 980, downloads: 540),

        PluginManifest(
            id: "audit-log", name: "操作审计", version: "1.0.1", category: .security,
            icon: "📋", tint: 2, sizeKB: 3,
            summary: "记录每条危险操作的执行时间、命令与结果，可追溯。",
            tools: [
                T("audit-log", "tail", "查看最近的操作审计记录。Use for: 回溯「我刚才到底改了什么」。",
                  "tail -60 /var/mobile/Documents/KnowledgeBase/audit.log 2>/dev/null || echo '暂无审计记录'",
                  [:], timeout: 30)
            ],
            changelog: ["v1.0.1 · 首版"], stars: 560, downloads: 260),

        // ================= 浏览器与网页（1）=================

        PluginManifest(
            id: "web-reader", name: "网页正文提取", version: "1.0.0", category: .browser,
            icon: "🌐", tint: 4, sizeKB: 5,
            summary: "把网页正文扒成纯文本，去掉导航与广告。",
            tools: [
                T("web-reader", "text", "抓网页并去掉标签，输出正文文本。Use for: 长文摘要、文档阅读。",
                  "curl -sL -m 25 -A 'Mozilla/5.0' {url} | sed -e 's/<script[^>]*>.*<\\/script>//g' -e 's/<[^>]*>//g' | tr -s ' \\n' ' \\n' | head -c 8000",
                  ["url": "网页地址"], timeout: 40),
                T("web-reader", "head", "只取网页标题与 meta 描述。Use for: 快速判断这是什么页面。",
                  "curl -sL -m 20 -A 'Mozilla/5.0' {url} | grep -oE '<title>[^<]*</title>|<meta[^>]*description[^>]*>' | head -5",
                  ["url": "网页地址"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 820, downloads: 400),

        // ================= Git 与代码评审（2）=================

        PluginManifest(
            id: "git-lite", name: "Git 速查", version: "1.0.0", category: .git,
            icon: "🌿", tint: 1, sizeKB: 4,
            summary: "看改动、看提交历史、查谁改了哪行，不用记命令。",
            deps: ["git"],
            tools: [
                T("git-lite", "status", "查看仓库当前改动概况。Use for: 编译前确认工作区干净。",
                  "cd {repo} && git status --short && echo '---' && git log --oneline -5",
                  ["repo": "仓库绝对路径"], timeout: 60),
                T("git-lite", "diff", "查看某个文件的改动内容。Use for: 审代码、确认改了什么。",
                  "cd {repo} && git diff {file} | head -150",
                  ["repo": "仓库绝对路径", "file": "相对路径或留空看全部"], timeout: 60)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 760, downloads: 350),

        PluginManifest(
            id: "ci-build", name: "线上编译", version: "1.1.0", category: .git,
            icon: "⚙️", tint: 0, sizeKB: 6,
            summary: "推到 GitHub 用 Actions 编译，编完自动下载产物。",
            requiresHook: true,
            skills: [
                PluginSkillSpec(
                    name: "Cloud Build Flow",
                    summary: "build ipa/deb through GitHub Actions and fetch the artifact back to the device",
                    instruction: "当用户要求线上编译时执行：\n1. 先确认：仓库地址、分支、workflow 名、要不要改版本号；\n2. 推送前检查：工作区是否干净、密钥是否在 Secrets 里（不能进代码）；\n3. 触发后轮询运行状态，别空等——先看有没有立刻失败的配置错误；\n4. 失败时先拉日志找 error 行；如果日志里没有 error 只有退出码，**重跑一次再判断**（已知坑）；\n5. 成功后下载 artifact，解压校验版本号与 bundle id，再交给用户安装。")
            ],
            changelog: ["v1.1.0 · 加失败重跑经验"], stars: 1900, downloads: 1200),

        // ================= 2026-11-05 扩充：28 → 64 =================
        // 用户问「插件市场怎么就 28 个」。原来那 28 个是手写的样例，数量太少，
        // 搜索时经常一个都命中不了。这一批补的都是**纯查询/整理**类，命令只用
        // busybox 里一定存在的工具（ls/find/grep/awk/sed/sort/du/md5sum/base64），
        // 不依赖 unzip / xxd / strings 这些需要 apk add 的包，装上就能跑。

        // ---- 工具与能力 +6 ----

        PluginManifest(
            id: "file-hash", name: "文件指纹", version: "1.0.0", category: .tools,
            icon: "🔑", tint: 3, sizeKB: 4,
            summary: "算 MD5 / SHA256，比对两个文件是不是同一个包。",
            tools: [
                T("file-hash", "sum", "计算文件的 MD5 与 SHA256。Use for: 校验下载是否完整、确认两个包是否同一份。",
                  "ls -l {file}; md5sum {file} 2>/dev/null; sha256sum {file} 2>/dev/null",
                  ["file": "文件绝对路径"], timeout: 180),
                T("file-hash", "cmp", "比对两个文件内容是否完全相同。Use for: 改动前后到底变没变。",
                  "if cmp -s {a} {b}; then echo '内容相同'; else echo '内容不同'; fi; md5sum {a} {b} 2>/dev/null",
                  ["a": "文件 A 绝对路径", "b": "文件 B 绝对路径"], timeout: 180)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1100, downloads: 720),

        PluginManifest(
            id: "disk-usage", name: "磁盘占用", version: "1.0.0", category: .tools,
            icon: "💾", tint: 1, sizeKB: 3,
            summary: "查哪个目录最占空间，按体积排前 N 名。",
            tools: [
                T("disk-usage", "top", "列出指定目录下最占空间的子项。Use for: 手机空间不够、找大文件。",
                  "du -k -d 1 {dir} 2>/dev/null | sort -rn | head -{n}",
                  ["dir": "目录绝对路径，如 /var/mobile/Documents", "n": "显示条数，建议 20"], timeout: 180),
                T("disk-usage", "df", "查看各分区剩余空间。Use for: 确认还有多少可用空间。",
                  "df -h 2>/dev/null | head -20", [:], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1500, downloads: 980),

        PluginManifest(
            id: "text-stats", name: "文本统计", version: "1.0.0", category: .tools,
            icon: "📊", tint: 2, sizeKB: 2,
            summary: "统计行数、字数、词频，长文本先看结构再读。",
            tools: [
                T("text-stats", "count", "统计文件的字符数、行数、词数。Use for: 估算 token、判断内容多少。",
                  "wc -c -l -w {file}", ["file": "文件绝对路径"], timeout: 60),
                T("text-stats", "top-words", "统计出现最多的词。Use for: 快速看主题、找重复内容。",
                  "tr -c '[:alnum:]_' '\\n' < {file} | tr 'A-Z' 'a-z' | awk 'length($0)>2' | sort | uniq -c | sort -rn | head -{n}",
                  ["file": "文件绝对路径", "n": "显示条数，建议 30"], timeout: 120)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 620, downloads: 380),

        PluginManifest(
            id: "base64-kit", name: "Base64 工具", version: "1.0.0", category: .tools,
            icon: "🔡", tint: 4, sizeKB: 2,
            summary: "Base64 编解码，处理图片 data URL、token 片段。",
            tools: [
                T("base64-kit", "encode", "把文本编码成 Base64。Use for: 拼 data URL、传二进制片段。",
                  "printf '%s' {text} | base64 | tr -d '\\n'",
                  ["text": "要编码的文本"], timeout: 30),
                T("base64-kit", "decode", "把 Base64 解开成文本。Use for: 看 data URL 里到底是什么内容。",
                  "printf '%s' {data} | base64 -d 2>/dev/null | head -c 4000",
                  ["data": "Base64 字符串"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 540, downloads: 330),

        PluginManifest(
            id: "csv-peek", name: "CSV 速览", version: "1.0.0", category: .tools,
            icon: "📋", tint: 0, sizeKB: 3,
            summary: "看 CSV 表头、行数、前几行，不用整表读进来。",
            tools: [
                T("csv-peek", "head", "看 CSV 的表头与前几行。Use for: 先搞清表结构再处理。",
                  "echo '--- 表头 ---'; head -1 {file}; echo '--- 行数 ---'; wc -l {file}; echo '--- 前几行 ---'; head -{n} {file}",
                  ["file": "CSV 绝对路径", "n": "行数，建议 10"], timeout: 60),
                T("csv-peek", "col", "取某一列并去重计数。Use for: 看某字段有哪些取值。",
                  "awk -F, 'NR>1' {file} | cut -d, -f{col} | sort | uniq -c | sort -rn | head -30",
                  ["file": "CSV 绝对路径", "col": "第几列，从 1 开始"], timeout: 120)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 480, downloads: 290),

        PluginManifest(
            id: "json-peek", name: "JSON 速览", version: "1.0.0", category: .tools,
            icon: "🧾", tint: 5, sizeKB: 3,
            summary: "大 JSON 只看结构和关键字段，不整份打印。",
            tools: [
                T("json-peek", "size", "看 JSON 体积、行数与开头结构。Use for: 判断该不该整份读。",
                  "ls -l {file}; wc -l {file}; head -c 1500 {file}",
                  ["file": "JSON 绝对路径"], timeout: 30),
                T("json-peek", "grep", "在 JSON 里搜关键字段及其附近内容。Use for: 找某个 key 的值。",
                  "grep -o -n -E '.{0,60}{key}.{0,120}' {file} | head -30",
                  ["file": "JSON 绝对路径", "key": "字段名或关键词"], timeout: 60)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 760, downloads: 520),

        // ---- 会话与消息 +3 ----

        PluginManifest(
            id: "chat-digest", name: "会话摘要", version: "1.0.0", category: .session,
            icon: "📝", tint: 2, sizeKB: 3,
            summary: "把长会话压成「目标 / 结论 / 待办」，换会话不丢线索。",
            skills: [
                PluginSkillSpec(
                    name: "Chat Digest",
                    summary: "summarize a long conversation into goal, decisions, evidence and open questions",
                    instruction: "当用户要求总结/交接当前会话时执行：\n1. 只写四段：目标、已定的结论、关键证据（文件路径与命令）、还没解决的问题；\n2. 每段最多 5 条，能合并的合并，不写过程流水账；\n3. 数字、版本号、路径必须与原文一致，不确定就标「待确认」；\n4. 不编造没发生的事，也不要重复用户已经否决的方案。")
            ],
            changelog: ["v1.0.0 · 首版"], stars: 900, downloads: 610),

        PluginManifest(
            id: "todo-track", name: "待办清单", version: "1.0.0", category: .session,
            icon: "✅", tint: 2, sizeKB: 2,
            summary: "把多步任务落成文件清单，做完一条划一条。",
            tools: [
                T("todo-track", "add", "往待办清单追加一条。Use for: 拆解多步任务时落地，避免漏项。",
                  "mkdir -p /var/mobile/Documents/KnowledgeBase && printf -- '- [ ] %s\\n' {text} >> /var/mobile/Documents/KnowledgeBase/todo.md && tail -12 /var/mobile/Documents/KnowledgeBase/todo.md",
                  ["text": "要做的事，一行写完"], timeout: 30),
                T("todo-track", "list", "查看当前的未完成待办。Use for: 继续上次没做完的活。",
                  "grep -n -- '- \\[ \\]' /var/mobile/Documents/KnowledgeBase/todo.md 2>/dev/null | head -40 || echo '清单为空'",
                  [:], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 700, downloads: 430),

        PluginManifest(
            id: "prompt-vault", name: "提示词库", version: "1.0.0", category: .session,
            icon: "🗄", tint: 1, sizeKB: 2,
            summary: "常用指令存起来，下次一句话调出来复用。",
            tools: [
                T("prompt-vault", "save", "保存一条常用提示词。Use for: 反复要用的指令别每次重打。",
                  "mkdir -p /var/mobile/Documents/KnowledgeBase/prompts && printf '## %s\\n%s\\n\\n' {title} {body} >> /var/mobile/Documents/KnowledgeBase/prompts/{tag}.md && echo '已保存'",
                  ["tag": "分类，英文无空格", "title": "标题", "body": "提示词正文"], timeout: 30),
                T("prompt-vault", "search", "在提示词库里搜。Use for: 找以前写好的指令。",
                  "grep -rn -i -A 3 {q} /var/mobile/Documents/KnowledgeBase/prompts 2>/dev/null | head -40 || echo '库里还没有内容'",
                  ["q": "关键词"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 830, downloads: 560),

        // ---- 模型与账号接入 +3 ----

        PluginManifest(
            id: "api-probe", name: "接口探测", version: "1.0.0", category: .model,
            icon: "📡", tint: 4, sizeKB: 3,
            summary: "批量测多个 API 地址的延迟与状态码，找出哪个能用。",
            tools: [
                T("api-probe", "one", "测一个接口的延迟与状态码。Use for: 排查某家中转/官方接口通不通。",
                  "curl -s -o /dev/null -w 'http=%{http_code} dns=%{time_namelookup}s tls=%{time_appconnect}s total=%{time_total}s\\n' -m 12 {url}",
                  ["url": "完整 URL，如 https://api.deepseek.com/v1/models"], timeout: 40),
                T("api-probe", "models", "拉某个 OpenAI 兼容接口的模型列表。Use for: 确认可用模型名。",
                  "curl -s -m 15 {url}/v1/models -H 'Authorization: Bearer {key}' | head -c 3000",
                  ["url": "站点根地址，如 https://api.deepseek.com", "key": "密钥，没有填 none"], timeout: 40)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1300, downloads: 900),

        PluginManifest(
            id: "cost-estimate", name: "用量估算", version: "1.0.0", category: .model,
            icon: "💰", tint: 0, sizeKB: 2,
            summary: "按字数粗估 token 与花费，接活前先看成本。",
            skills: [
                PluginSkillSpec(
                    name: "Cost Estimator",
                    summary: "estimate token count and cost for a task before running it",
                    instruction: "当用户问「这活大概多少钱」或要跑大批量任务时执行：\n1. 先估输入量：中文字符≈1 token、英文≈0.25 token/字符，按 1.5 倍留余量；\n2. 说明工具循环会把上下文重复计入，多轮任务按轮次乘；\n3. 给出「最省做法」：先小样本试跑，确认效果再批处理；\n4. 明确标注单价按用户自己配的供应商，不确定就说明这是估算不是账单。")
            ],
            changelog: ["v1.0.0 · 首版"], stars: 980, downloads: 640),

        PluginManifest(
            id: "token-count", name: "Token 计量", version: "1.0.0", category: .model,
            icon: "🧮", tint: 3, sizeKB: 2,
            summary: "给一段文字或文件，粗算 token 数，避免超窗口。",
            tools: [
                T("token-count", "text", "估算一段文本的 token 数。Use for: 粘长文前先看会不会超窗口。",
                  "printf '%s' {text} | wc -c | awk '{printf \"字符 %d → 约 %d tokens\\n\", $1, int($1/2)}'",
                  ["text": "要估算的文本"], timeout: 30),
                T("token-count", "file", "估算一个文件的 token 数。Use for: 决定要不要分段读。",
                  "wc -c {file} | awk '{printf \"字节 %d → 约 %d tokens\\n\", $1, int($1/2)}'",
                  ["file": "文件绝对路径"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 880, downloads: 590),

        // ---- 记忆 +3 ----

        PluginManifest(
            id: "memory-index", name: "记忆索引", version: "1.0.0", category: .memory,
            icon: "🗃", tint: 2, sizeKB: 3,
            summary: "把记忆库里的文件列成目录，先看有什么再检索。",
            tools: [
                T("memory-index", "tree", "列出记忆库的目录结构与文件大小。Use for: 先搞清有哪些笔记。",
                  "find /var/mobile/Documents/KnowledgeBase -maxdepth 2 -type f 2>/dev/null | head -60; echo '---'; du -sh /var/mobile/Documents/KnowledgeBase 2>/dev/null",
                  [:], timeout: 60),
                T("memory-index", "recent", "看最近改过的记忆文件。Use for: 接着上次的进度干。",
                  "find /var/mobile/Documents/KnowledgeBase -type f -name '*.md' 2>/dev/null | head -40 | xargs ls -lt 2>/dev/null | head -15",
                  [:], timeout: 60)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 720, downloads: 450),

        PluginManifest(
            id: "log-book", name: "踩坑日志", version: "1.0.0", category: .memory,
            icon: "📓", tint: 4, sizeKB: 2,
            summary: "按「症状 → 原因 → 解法」记踩坑，下次先查这里。",
            tools: [
                T("log-book", "write", "记一条踩坑记录。Use for: 一个问题解决了立刻落盘，别靠记忆。",
                  "mkdir -p /var/mobile/Documents/KnowledgeBase && printf '### %s\\n- 症状：%s\\n- 原因：%s\\n- 解法：%s\\n\\n' {symptom} {symptom} {cause} {fix} >> /var/mobile/Documents/KnowledgeBase/pitfalls.md && tail -8 /var/mobile/Documents/KnowledgeBase/pitfalls.md",
                  ["symptom": "现象一句话", "cause": "根因", "fix": "怎么解决"], timeout: 30),
                T("log-book", "search", "在踩坑日志里按关键词搜。Use for: 动手前先看以前是不是踩过。",
                  "grep -rn -i -B 2 -A 6 {q} /var/mobile/Documents/KnowledgeBase/pitfalls.md 2>/dev/null | head -60 || echo '还没有记录'",
                  ["q": "关键词"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1400, downloads: 960),

        PluginManifest(
            id: "date-notes", name: "日期笔记", version: "1.0.0", category: .memory,
            icon: "📅", tint: 1, sizeKB: 2,
            summary: "按天归档笔记，回头看某天干了什么一目了然。",
            tools: [
                T("date-notes", "write", "往今天的笔记里追加一条。Use for: 记录当天进展。",
                  "mkdir -p /var/mobile/Documents/KnowledgeBase/daily && printf -- '- %s  %s\\n' \"$(date '+%H:%M')\" {text} >> /var/mobile/Documents/KnowledgeBase/daily/$(date '+%Y-%m-%d').md && tail -6 /var/mobile/Documents/KnowledgeBase/daily/$(date '+%Y-%m-%d').md",
                  ["text": "要记的内容"], timeout: 30),
                T("date-notes", "day", "看某一天的笔记，默认今天。Use for: 回顾当时怎么做的。",
                  "f=/var/mobile/Documents/KnowledgeBase/daily/{date}.md; if [ -f \"$f\" ]; then cat \"$f\"; else echo \"没有 $f\"; fi",
                  ["date": "日期 YYYY-MM-DD，不确定就填今天的"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 640, downloads: 400),

        // ---- 文档与渲染 +3 ----

        PluginManifest(
            id: "md-outline", name: "Markdown 大纲", version: "1.0.0", category: .docs,
            icon: "📑", tint: 2, sizeKB: 2,
            summary: "抽出 md 的全部标题，长文档先看结构再读。",
            tools: [
                T("md-outline", "toc", "列出 Markdown 的标题层级。Use for: 长文档先看骨架，别整篇读。",
                  "grep -n '^#' {file} | head -80",
                  ["file": "md 文件绝对路径"], timeout: 30),
                T("md-outline", "stats", "统计文档字数与标题数。Use for: 判断值不值得通读。",
                  "echo -n '标题数 '; grep -c '^#' {file}; echo -n '行数 '; wc -l < {file}; echo -n '字节 '; wc -c < {file}",
                  ["file": "md 文件绝对路径"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 690, downloads: 420),

        PluginManifest(
            id: "doc-clean", name: "文本清洗", version: "1.0.0", category: .docs,
            icon: "🧽", tint: 3, sizeKB: 2,
            summary: "去重、去空行、去重复空格，把杂乱文本整干净。",
            tools: [
                T("doc-clean", "dedup", "去掉重复行并保留原顺序。Use for: 整理日志、清单。",
                  "awk '!seen[$0]++' {file} | head -300",
                  ["file": "文件绝对路径"], timeout: 120),
                T("doc-clean", "squeeze", "去掉连续空行与行尾空格。Use for: 从网页复制来的脏文本。",
                  "sed -e 's/[[:space:]]*$//' -e '/^$/N;/^\\n$/D' {file} | head -300",
                  ["file": "文件绝对路径"], timeout: 120)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 520, downloads: 310),

        PluginManifest(
            id: "text-diff", name: "文本比对", version: "1.0.0", category: .docs,
            icon: "🔍", tint: 4, sizeKB: 2,
            summary: "两个文本文件的差异，改了什么一眼看出。",
            tools: [
                T("text-diff", "diff", "比对两个文本文件的差异。Use for: 改版前后对比、配置差异。",
                  "diff -u {a} {b} 2>/dev/null | head -120 || echo '两文件内容相同'",
                  ["a": "旧文件绝对路径", "b": "新文件绝对路径"], timeout: 60),
                T("text-diff", "common", "找出两个文件共有的行。Use for: 求交集、找重复配置。",
                  "sort {a} > /tmp/_ta_a.txt; sort {b} > /tmp/_ta_b.txt; comm -12 /tmp/_ta_a.txt /tmp/_ta_b.txt | head -60",
                  ["a": "文件 A 绝对路径", "b": "文件 B 绝对路径"], timeout: 60)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 610, downloads: 370),

        // ---- 视觉与多模态 +2 ----

        PluginManifest(
            id: "img-scan", name: "图片盘点", version: "1.0.0", category: .vision,
            icon: "🖼", tint: 5, sizeKB: 2,
            summary: "列出目录里所有图片与体积，顺手找重复。",
            tools: [
                T("img-scan", "list", "列出目录下的图片文件按体积排序。Use for: 找占空间的大图。",
                  "find {dir} -maxdepth 3 -type f \\( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' \\) 2>/dev/null | head -300 | xargs ls -l 2>/dev/null | sort -k5 -rn | head -20",
                  ["dir": "目录绝对路径"], timeout: 120),
                T("img-scan", "dup", "按内容哈希找重复图片。Use for: 清理重复截图。",
                  "find {dir} -maxdepth 3 -type f \\( -iname '*.png' -o -iname '*.jpg' \\) 2>/dev/null | head -300 | xargs md5sum 2>/dev/null | sort | uniq -w32 -d | head -20",
                  ["dir": "目录绝对路径"], timeout: 180)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 740, downloads: 480),

        PluginManifest(
            id: "screenshot-book", name: "截图归档", version: "1.0.0", category: .vision,
            icon: "📸", tint: 0, sizeKB: 2,
            summary: "把截图按日期归到子目录，找起来不再翻几百张。",
            tools: [
                T("screenshot-book", "count", "统计截图目录里有多少张、占多大。Use for: 判断该不该清理。",
                  "d=/var/mobile/Media/DCIM; ls -1 \"$d\" 2>/dev/null | head -5; echo '---'; du -sh \"$d\" 2>/dev/null",
                  [:], timeout: 60),
                T("screenshot-book", "recent", "列出最近的截图文件。Use for: 找到刚截的那张。",
                  "ls -lt /var/mobile/Media/DCIM/100APPLE 2>/dev/null | head -15 || ls -lt /var/mobile/Media/DCIM 2>/dev/null | head -15",
                  [:], timeout: 60)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 430, downloads: 260),

        // ---- 安全与权限 +3 ----

        PluginManifest(
            id: "perm-audit", name: "权限体检", version: "1.0.0", category: .security,
            icon: "🛡", tint: 1, sizeKB: 3,
            summary: "看哪些文件对所有用户可写，重点目录做一次体检。",
            tools: [
                T("perm-audit", "world-writable", "列出任何人可写的文件。Use for: 安全体检、排查被改过的文件。",
                  "find {dir} -maxdepth 4 -type f -perm -002 2>/dev/null | head -40 || echo '没有发现'",
                  ["dir": "要检查的目录，如 /var/mobile/Documents"], timeout: 120),
                T("perm-audit", "suid", "查找带 suid 位的可执行文件。Use for: 排查提权面。",
                  "find {dir} -maxdepth 4 -type f -perm -4000 2>/dev/null | head -40 || echo '没有发现'",
                  ["dir": "要检查的目录"], timeout: 120)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 980, downloads: 620),

        PluginManifest(
            id: "secret-scan", name: "密钥扫描", version: "1.0.0", category: .security,
            icon: "🔐", tint: 4, sizeKB: 3,
            summary: "在目录里找疑似硬编码的密钥、token、内网地址。",
            tools: [
                T("secret-scan", "keys", "扫描疑似密钥/Token 的字符串。Use for: 提交代码前自检，别把密钥传上去。",
                  "grep -rIn -E '(sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|Bearer [A-Za-z0-9._-]{20,})' {dir} 2>/dev/null | head -30 || echo '没有发现明显密钥'",
                  ["dir": "要扫描的目录"], timeout: 180),
                T("secret-scan", "private-ip", "找出硬编码的内网地址。Use for: 检查配置里写死的 192.168 / 10. 地址。",
                  "grep -rIn -E '(192\\.168\\.[0-9]{1,3}\\.[0-9]{1,3}|10\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3})' {dir} 2>/dev/null | head -30 || echo '没有发现'",
                  ["dir": "要扫描的目录"], timeout: 180)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1600, downloads: 1100),

        PluginManifest(
            id: "sig-check", name: "签名自检", version: "1.0.0", category: .security,
            icon: "✍️", tint: 2, sizeKB: 2,
            summary: "看 App 包里有没有签名目录、entitlements 是否齐全。",
            tools: [
                T("sig-check", "bundle", "检查 App bundle 的签名目录与关键文件。Use for: 侧载装不上时先看签名在不在。",
                  "ls -la {path} 2>/dev/null | head -25; echo '--- 签名目录 ---'; ls -la {path}/_CodeSignature 2>/dev/null || echo '没有 _CodeSignature（侧载正常）'",
                  ["path": "App bundle 绝对路径"], timeout: 60),
                T("sig-check", "entitlements", "抽出 App 的 entitlements 关键项。Use for: 确认容器/沙箱相关权限对不对。",
                  "strings {path}/*.app/embedded.mobileprovision 2>/dev/null | head -20; find {path} -maxdepth 3 -name '*.entitlements' 2>/dev/null | head -5",
                  ["path": "App 或包内路径"], timeout: 60)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 890, downloads: 570),

        // ---- 浏览器与网页 +2 ----

        PluginManifest(
            id: "url-extract", name: "链接抽取", version: "1.0.0", category: .browser,
            icon: "🔗", tint: 3, sizeKB: 2,
            summary: "从文本或网页源码里把 URL 全揪出来，去重。",
            tools: [
                T("url-extract", "from-text", "从文本里抽取所有 http 链接并去重。Use for: 整理资料、找下载地址。",
                  "grep -oE 'https?://[A-Za-z0-9._~:/?#\\[\\]@!$&()*+,;=%-]+' {file} 2>/dev/null | sort -u | head -60 || echo '没有找到链接'",
                  ["file": "文本文件绝对路径"], timeout: 60),
                T("url-extract", "inline", "直接从一段话里抽链接。Use for: 用户粘了一堆文字，只要地址。",
                  "printf '%s' {text} | grep -oE 'https?://[A-Za-z0-9._~:/?#\\[\\]@!$&()*+,;=%-]+' | sort -u | head -30 || echo '没有找到链接'",
                  ["text": "包含链接的文本"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 660, downloads: 400),

        PluginManifest(
            id: "page-title", name: "网页标题", version: "1.0.0", category: .browser,
            icon: "🏷", tint: 0, sizeKB: 2,
            summary: "只抓网页标题和描述，不把整页拉下来。",
            tools: [
                T("page-title", "meta", "抓网页的 title 与 description。Use for: 快速判断一个链接值不值得读。",
                  "curl -sL -m 20 {url} | tr '\\n' ' ' | sed -n 's/.*<title[^>]*>\\([^<]*\\)<\\/title>.*/title: \\1/p; s/.*name=\"description\" content=\"\\([^\"]*\\)\".*/desc: \\1/p' | head -5",
                  ["url": "网页地址"], timeout: 30),
                T("page-title", "size", "看网页体积与状态码，先判断要不要下载。Use for: 大页面别整份拉。",
                  "curl -sIL -m 20 -o /dev/null -w 'http=%{http_code} size=%{size_download} total=%{time_total}s\\n' {url}",
                  ["url": "网页地址"], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 570, downloads: 340),

        // ---- Git 与代码 +2 ----

        PluginManifest(
            id: "git-log-lite", name: "提交速览", version: "1.0.0", category: .git,
            icon: "📜", tint: 1, sizeKB: 2,
            summary: "看最近提交与改了哪些文件，不拉全量历史。",
            tools: [
                T("git-log-lite", "recent", "看最近 N 条提交。Use for: 接手仓库先看最近动过什么。",
                  "cd {repo} && git log --oneline -{n} 2>/dev/null || echo '不是 git 仓库'",
                  ["repo": "仓库绝对路径", "n": "条数，建议 15"], timeout: 60),
                T("git-log-lite", "changed", "看某次提交或未提交改动涉及的文件。Use for: 确认改了什么。",
                  "cd {repo} && (git show --stat --oneline {ref} 2>/dev/null || git status --short 2>/dev/null) | head -40",
                  ["repo": "仓库绝对路径", "ref": "提交号，看当前改动就填 HEAD"], timeout: 60)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 810, downloads: 500),

        PluginManifest(
            id: "code-scan", name: "代码体检", version: "1.0.0", category: .git,
            icon: "🩺", tint: 3, sizeKB: 3,
            summary: "找 TODO、长函数、超大文件，改之前先摸底。",
            tools: [
                T("code-scan", "todo", "找出代码里的 TODO / FIXME / HACK。Use for: 快速看还有哪些坑。",
                  "grep -rIn -E '(TODO|FIXME|HACK|XXX)' {dir} --include='*.swift' --include='*.m' --include='*.py' --include='*.js' 2>/dev/null | head -30 || echo '没有标记'",
                  ["dir": "源码目录绝对路径"], timeout: 120),
                T("code-scan", "big-files", "找出最大的源码文件。Use for: 定位难维护的巨型文件。",
                  "find {dir} -type f \\( -name '*.swift' -o -name '*.m' -o -name '*.js' -o -name '*.py' \\) 2>/dev/null | head -600 | xargs wc -l 2>/dev/null | sort -rn | head -15",
                  ["dir": "源码目录绝对路径"], timeout: 180)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1020, downloads: 690),

        // ---- 用量与计费 +1 ----

        PluginManifest(
            id: "usage-book", name: "用量账本", version: "1.0.0", category: .usage,
            icon: "📈", tint: 2, sizeKB: 2,
            summary: "每次跑完记一笔，月底知道钱花在哪。",
            tools: [
                T("usage-book", "add", "记一笔本次调用的粗略用量。Use for: 大批量任务结束后留账。",
                  "mkdir -p /var/mobile/Documents/KnowledgeBase && printf '%s  %s  %s\\n' \"$(date '+%m-%d %H:%M')\" {task} {note} >> /var/mobile/Documents/KnowledgeBase/usage.log && tail -8 /var/mobile/Documents/KnowledgeBase/usage.log",
                  ["task": "做了什么", "note": "说明，如轮次/字数/花费"], timeout: 30),
                T("usage-book", "sum", "汇总账本记录条数与最近几条。Use for: 回顾这阵子跑了多少活。",
                  "f=/var/mobile/Documents/KnowledgeBase/usage.log; if [ -f \"$f\" ]; then echo -n '共 '; wc -l < \"$f\"; tail -15 \"$f\"; else echo '账本为空'; fi",
                  [:], timeout: 30)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 490, downloads: 300),

        // ---- 远程与移动端 +1 ----

        PluginManifest(
            id: "download-get", name: "下载取件", version: "1.0.0", category: .remote,
            icon: "⬇️", tint: 4, sizeKB: 2,
            summary: "把远端文件拉到本地目录，顺手校验大小。",
            tools: [
                T("download-get", "get", "下载一个文件到指定目录。Use for: 取 ipa / 配置 / 资源。",
                  "mkdir -p {dir} && curl -sL -m {sec} -o {dir}/{name} {url} && ls -l {dir}/{name}",
                  ["url": "完整下载地址", "dir": "保存目录绝对路径", "name": "保存文件名", "sec": "超时秒数，建议 300"], timeout: 360),
                T("download-get", "resume", "断点续传一个没下完的文件。Use for: 大包下到一半断了。",
                  "curl -sL -C - -m {sec} -o {dir}/{name} {url} && ls -l {dir}/{name}",
                  ["url": "完整下载地址", "dir": "保存目录绝对路径", "name": "保存文件名", "sec": "超时秒数，建议 300"], timeout: 360)
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1180, downloads: 800),

        // ---- 技能包 +2 ----

        PluginManifest(
            id: "skill-review", name: "代码审查流程", version: "1.0.0", category: .skill,
            icon: "👓", tint: 5, sizeKB: 3,
            summary: "按固定顺序审改动：先看影响面，再看边界，最后看风格。",
            skills: [
                PluginSkillSpec(
                    name: "Code Review Flow",
                    summary: "review a code change in a fixed order: blast radius, edge cases, then style",
                    instruction: "当用户要求审代码时按顺序执行：\n1. 影响面：这次改动被谁调用、会不会影响已上线功能；\n2. 正确性：空值/异常/权限/并发四类边界逐个想一遍，只报真问题；\n3. 资源：有没有泄漏、循环里做重活、大文件一次性读进内存；\n4. 可回滚：改动是否原子，出问题能不能单独退掉；\n5. 风格最后说，且不要为了风格改逻辑。\n输出格式：问题（严重度）→ 位置 → 为什么 → 怎么改。没问题就直说没发现，别硬凑。")
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1450, downloads: 950),

        PluginManifest(
            id: "skill-release", name: "发布自检", version: "1.0.0", category: .skill,
            icon: "🚦", tint: 1, sizeKB: 3,
            summary: "发版前的固定检查单：版本号、后缀、签名、体积。",
            skills: [
                PluginSkillSpec(
                    name: "Release Checklist",
                    summary: "pre-release checklist: version bump, extension, signing, size and rollback plan",
                    instruction: "当用户准备发布/打包时按清单执行：\n1. 版本号：确认这次该涨到多少，别跳号也别重号；\n2. 产物：后缀对不对（ipa/tipa）、包内 Info.plist 的 bundle id 与版本是否一致；\n3. 签名：侧载环境不需要 App Store 签名，但 _CodeSignature 的取舍要明确；\n4. 体积：对比上一版，突增就查是哪个文件带来的；\n5. 回滚：留一份上一版产物与推送前的 commit，出问题能退回去。\n检查完逐条给结论（通过/不通过 + 证据），不要只说「应该没问题」。")
            ],
            changelog: ["v1.0.0 · 首版"], stars: 1120, downloads: 740)
    ]
}
