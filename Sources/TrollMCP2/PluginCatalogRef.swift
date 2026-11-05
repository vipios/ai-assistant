// PluginCatalogRef.swift — 2026-11-05 外部插件参考目录（12 类 / 4687 条）
//
// 用户原话：「插件市场里面的插件我要电脑桌面上那些，主要把这 12 类都弄到咱们的插件市场里面」。
// 桌面上那个 ipa 是竞品 Rein（DSH），它的市场是一个 npm 包 `dsh-plugin-catalog`，
// 里面 8879 条（23 类）。我们只取用户点名的那 12 类，共 4687 条，压成一份静态
// JSON 塞进 App 资源（Resources/PluginCatalog.json，约 1.5MB）。
//
// ⚠️ 关键定位：这些是 **Node/Cordis 插件**，跑在 DSH 的 node22 运行时里，
// 我们这边是 Alpine shell（iSH 血统），**装不了**。所以这份目录的用途只有一个：
//   让 AI 知道「世界上有人做过这个功能」→ 按它的思路用 shell 重写一遍（plugin.define）。
// 界面上必须和「可安装的内置插件」明确区分，否则用户点了装不上，比没有更糟。
//
// 所以这里是**两套目录并存**：
//   · builtinCatalog  = 真能装、装完立刻有工具（59 个）
//   · referenceCatalog = 只能查、能一键「照着做一个」（4687 条）

import Foundation

/// 外部目录里的一条（字段刻意用短名压缩体积：4687 条 × 长字段名会让文件胖 40%）
struct RefPlugin: Identifiable, Hashable {
    let id: String
    /// 名字（可能是 npm 包名或仓库名）
    let name: String
    let owner: String
    let repo: String
    /// 分类：tools / session / model / ... 与 PluginCategory.rawValue 一一对应
    let category: String
    let summary: String
    let stars: Int
    /// npm 包名，空 = 只能从 GitHub 装
    let pkg: String

    /// 打开项目主页（给用户看原项目长什么样，不引导下载）
    var pageURL: URL? {
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return URL(string: "https://github.com/\(owner)/\(repo)")
    }
}

/// 外部目录加载器。
/// 只在第一次访问时读盘并解析（4687 条 JSON 解析约 30–80ms，放懒加载 + 后台队列，
/// 绝不进首屏）。
enum PluginCatalogRef {

    /// 解析结果缓存
    private static var cache: [RefPlugin]?
    private static var loading = false
    private static let lock = NSLock()

    /// 已加载的条目（同步返回；未加载完成时返回空数组，界面先显示「加载中」）
    static var entries: [RefPlugin] {
        lock.lock(); defer { lock.unlock() }
        return cache ?? []
    }

    static var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return cache != nil
    }

    /// 总条数（不复制数组）。
    /// `entries.count` 会先把 4687 条整个拷出来再取 count——chips 每帧都调，
    /// 那是每帧几万字节的无谓拷贝。这里只读一个 Int。
    static var totalCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cache?.count ?? 0
    }

    /// 按 id 取一条（同样避免整表拷贝）
    static func find(_ id: String) -> RefPlugin? {
        lock.lock()
        let list = cache
        lock.unlock()
        return list?.first { $0.id == id }
    }

    /// 分类计数（给筛选条上的数字用）。
    ///
    /// 不能用 `entries.reduce` 现算：chips 里 12 个分类各调一次，而 chips 挂在 body 上，
    /// 搜索框每敲一个字符就重算一次 → 12 × 4687 ≈ 5.6 万次比较/次按键，中文输入法连打时肉眼可见卡。
    /// 解析完成时顺手把计数表算好，这里只查表。
    static func count(in category: PluginCategory) -> Int {
        lock.lock()
        let tbl = counts
        let list = cache
        lock.unlock()
        if let n = tbl[category.rawValue] { return n }
        // 极小概率：计数表还没建（老缓存路径）。退回现算一次，别返回 0 骗人。
        return list?.reduce(0) { $0 + ($1.category == category.rawValue ? 1 : 0) } ?? 0
    }

    /// 分类 → 条数（解析时一次性建好）
    private static var counts: [String: Int] = [:]

    /// 开始加载（幂等，重复调用无副作用）。界面用这个：异步，不卡首屏。
    static func loadIfNeeded(completion: (() -> Void)? = nil) {
        lock.lock()
        if cache != nil { lock.unlock(); completion?(); return }
        if loading { lock.unlock(); return }
        loading = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            let parsed = parseBundle()
            lock.lock()
            cache = parsed
            counts = tally(parsed)
            loading = false
            lock.unlock()
            DispatchQueue.main.async { completion?() }
            print("[TA] 📚 ref catalog loaded: \(parsed.count)")
        }
    }

    /// 同步加载（工具层用）。
    ///
    /// 为什么需要它：`plugin.search` 是同步返回的闭包，之前写成
    /// `loadIfNeeded()` 紧跟 `search()`——首次调用时 JSON 还在后台解析，
    /// `entries` 是空数组，AI 会得到「0 条结果」，然后转头去编一个不存在的插件。
    /// 工具调用本来就在后台线程，直接同步读盘（30–80ms，一次性）是更稳的选择。
    static func loadSyncIfNeeded() {
        lock.lock()
        if cache != nil { lock.unlock(); return }
        lock.unlock()

        let parsed = parseBundle()
        lock.lock()
        // 后台那次可能刚好也解析完了，谁先到用谁的（内容一样）
        if cache == nil {
            cache = parsed
            counts = tally(parsed)
        }
        loading = false
        lock.unlock()
        print("[TA] 📚 ref catalog loaded(sync): \(parsed.count)")
    }

    /// 搜索（关键词匹配 id / 名称 / 仓库 / 简介，全部小写比较）。
    ///
    /// `cache` 在解析阶段就已经按 stars 降序排好，所以这里**不再排序**：
    /// 过滤是保序的，filter 完直接 prefix 就是「星多的在前」。
    /// 之前每次搜索都 `.sorted { $0.stars > $1.stars }`，4687 条一次约 5.5 万次比较，
    /// 而搜索框的 onEditingChanged 每敲一个字符就调一次 → 中文连打时明显掉帧。
    static func search(_ q: String, category: PluginCategory?, limit: Int = 200) -> [RefPlugin] {
        var list = entries
        if let c = category { list = list.filter { $0.category == c.rawValue } }
        let key = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty {
            list = list.filter {
                $0.id.contains(key) || $0.name.lowercased().contains(key)
                || $0.repo.lowercased().contains(key) || $0.summary.lowercased().contains(key)
                || $0.owner.lowercased().contains(key)
            }
        }
        return Array(list.prefix(limit))
    }

    /// 一次性算好 12 个分类的条数（只在解析完成后调用）
    private static func tally(_ list: [RefPlugin]) -> [String: Int] {
        var t: [String: Int] = [:]
        t.reserveCapacity(12)
        for r in list { t[r.category, default: 0] += 1 }
        return t
    }

    // MARK: 解析

    private static func parseBundle() -> [RefPlugin] {
        guard let url = Bundle.main.url(forResource: "PluginCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("[TA] 📚 PluginCatalog.json 不在包里，外部目录为空")
            return []
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["plugins"] as? [[String: Any]] else {
            print("[TA] 📚 PluginCatalog.json 结构不对")
            return []
        }
        var out: [RefPlugin] = []
        out.reserveCapacity(raw.count)
        for o in raw {
            guard let id = o["id"] as? String, !id.isEmpty else { continue }
            // 2026-11-05 瘦身：JSON 里 `n`(名字) 与 `r`(仓库名) 跟 id 高度重复
            // （4687 条里 3569 条 n==id、4182 条 n==r），生成时就把重复的省掉了，
            // 文件从 1.58MB 压到 1.41MB。这里按同一套规则补回来——
            // 缺 n 用 id，缺 r 用 n（也就是 id），跟写出去时的判断完全对称。
            let name = (o["n"] as? String) ?? id
            let owner = (o["o"] as? String) ?? ""
            let repo = (o["r"] as? String) ?? name
            let cat = (o["c"] as? String) ?? "tools"
            let desc = (o["d"] as? String) ?? ""
            let stars = (o["s"] as? Int) ?? 0
            let pkg = (o["p"] as? String) ?? ""
            out.append(RefPlugin(id: id, name: name, owner: owner, repo: repo,
                                 category: cat, summary: desc,
                                 stars: stars, pkg: pkg))
        }
        // 解析时排一次（降序），搜索时就不用再排了——见 search() 的注释。
        // 4687 条排一次约 15ms，只在懒加载里发生一次；换来的是每次按键省 5 万次比较。
        out.sort { $0.stars > $1.stars }
        return out
    }
}
