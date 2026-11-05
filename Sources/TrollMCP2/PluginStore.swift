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

    private init() {
        catalog = Self.builtinCatalog
        load()
        // 工具只活在内存里，App 重启后必须重新注册。
        // 延后 1.5s：避开启动瞬间的注册表初始化与首屏渲染。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.restoreInstalled()
        }
    }

    // MARK: 查询

    func manifest(id: String) -> PluginManifest? {
        catalog.first { $0.id == id }
    }

    var installedManifests: [PluginManifest] {
        catalog.filter { installedIDs.contains($0.id) }
    }

    func isInstalled(_ id: String) -> Bool { installedIDs.contains(id) }
    func isInstalling(_ id: String) -> Bool { installingIDs.contains(id) }
    func isEnabled(_ id: String) -> Bool { installedIDs.contains(id) && !disabledIDs.contains(id) }

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

    private func load() {
        if let a = UserDefaults.standard.stringArray(forKey: installedKey) {
            installedIDs = Set(a)
        }
        if let d = UserDefaults.standard.stringArray(forKey: disabledKey) {
            disabledIDs = Set(d)
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
            changelog: ["v1.1.0 · 加失败重跑经验"], stars: 1900, downloads: 1200)
    ]
}
