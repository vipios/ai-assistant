import Foundation
import SwiftUI
import Combine

// MARK: - 自动上下文提取器
// 自动从用户消息中提取关键信息（App 名、bundle id、文件路径等）
// 存到上下文里，下次用户问的时候自动加进去

final class AutoContextExtractor: ObservableObject {
    static let shared = AutoContextExtractor()

    /// 2026-11-05 **跨会话污染根治：上下文从「一份全局」改成「按会话各一份」**。
    ///
    /// 用户实测（截图）：会话 1 让它「分析 siri 智能」，会话 2 让它「做一个去广告的」，
    /// 结果会话 2 的 AI 说要去查 siriai 相关的 App、还报出 `com.zh.launch`
    /// ——那全是会话 1 的东西。
    ///
    /// 完整因果链（三个 bug 叠在一起才炸）：
    ///   ① 这四个字段原本是**单例上的四个属性**，所有会话共用一份；
    ///   ② `extract` 是**增量更新**——这句提不到 bundle id 就保留上一次的值，「做一个去广告的」
    ///      里既没有 com.xxx 也没有已知 App 名，于是 `lastBundleID` 原封不动还是会话 1 的；
    ///   ③ `contextHint()` **从不过期、从不清空**，只要进程活着就一直注入，
    ///      连提示词里都写着 `If user says "it" / "this app" ... use the above context`
    ///      ——等于主动教模型去用别人的上下文。
    ///
    /// 修法：按 sessionId 分桶存。会话 2 没有自己的上下文时返回 nil，
    /// 一个字都不注入。指代消解（「给它去广告」）仍然有效，因为同会话内是累积的。
    struct Context {
        var bundleID: String?
        var appName: String?
        var filePath: String?
        var action: String?
        var updatedAt: Date = Date()

        var isEmpty: Bool {
            bundleID == nil && appName == nil && filePath == nil && action == nil
        }
    }

    /// 上下文有效期。同一会话内「给它去广告」这种指代必须还在有效期内才注入；
    /// 隔了太久还拿出来用，就是把模型往错误方向引。
    private static let ttl: TimeInterval = 15 * 60

    /// 最多保留多少个会话的上下文（防止长年不清理无线增长）
    private static let maxSessions = 64

    private var bySession: [UUID: Context] = [:]

    /// 最近一次提取的字段（仅用于界面回显 / 调试；**不参与请求构造**）
    @Published var lastBundleID: String?
    @Published var lastAppName: String?
    @Published var lastFilePath: String?
    @Published var lastAction: String?

    private init() {}

    /// 从用户消息中提取关键信息——**必须带上会话 ID**。
    ///
    /// 传 nil 等于「不知道属于哪个会话」，此时只更新回显字段、不写任何会话桶，
    /// 宁可丢了上下文也不要写错会话。
    func extract(from message: String, sessionId: UUID?) {
        let bundleID = extractBundleID(from: message)
        let filePath = extractFilePath(from: message)
        let appName = extractAppName(from: message)
        let action = extractAction(from: message)

        // 回显字段照常更新（界面上「最近提到的 App」之类）
        if let v = bundleID { lastBundleID = v }
        if let v = appName { lastAppName = v }
        if let v = filePath { lastFilePath = v }
        if let v = action { lastAction = v }

        guard let sid = sessionId else { return }

        // 同会话内累积：能提取到就覆盖，提取不到保留该会话自己的旧值
        // （这才是正确的「指代消解」语义——但只在**同一个会话**里成立）
        var ctx = bySession[sid] ?? Context()
        if let v = bundleID { ctx.bundleID = v }
        if let v = filePath { ctx.filePath = v }
        if let v = appName { ctx.appName = v }
        if let v = action { ctx.action = v }
        ctx.updatedAt = Date()

        // 这条消息一个字段都没提取到 → 不新建空桶（否则会把「无上下文」写成「有桶但全空」）
        guard !ctx.isEmpty else { return }

        bySession[sid] = ctx
        evictIfNeeded()

        if bundleID != nil || appName != nil || action != nil {
            print("📝 AutoContext[\(sid.uuidString.prefix(8))]: bundle=\(ctx.bundleID ?? "-") app=\(ctx.appName ?? "-") action=\(ctx.action ?? "-")")
        }
    }

    /// 生成上下文提示。**只返回该会话自己的、且没过期的**上下文。
    ///
    /// 返回 nil 就一个字都不注入——这是修复跨会话串台的关键。
    func contextHint(sessionId: UUID?) -> String? {
        guard let sid = sessionId, let ctx = bySession[sid] else { return nil }
        guard Date().timeIntervalSince(ctx.updatedAt) <= Self.ttl else {
            bySession.removeValue(forKey: sid)
            return nil
        }

        var hints: [String] = []
        if let bundleID = ctx.bundleID {
            hints.append("Last mentioned app bundle_id: \(bundleID)")
        }
        if let appName = ctx.appName {
            hints.append("Last mentioned app: \(appName)")
        }
        if let filePath = ctx.filePath {
            hints.append("Last mentioned file: \(filePath)")
        }
        if let action = ctx.action {
            hints.append("Last action: \(action)")
        }
        guard !hints.isEmpty else { return nil }

        return """
        
        === AUTO CONTEXT (this conversation only) ===
        \(hints.joined(separator: "\n"))
        If user says "it" / "this app" / "its file" / "do it", use the above context.
        """
    }

    /// 会话被删除时清掉它的桶
    func clear(sessionId: UUID) {
        bySession.removeValue(forKey: sessionId)
    }

    /// 清理过期桶 + 超量淘汰（按更新时间留最新的 maxSessions 个）
    private func evictIfNeeded() {
        let now = Date()
        bySession = bySession.filter { now.timeIntervalSince($0.value.updatedAt) <= Self.ttl }
        guard bySession.count > Self.maxSessions else { return }
        let keep = bySession
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(Self.maxSessions)
            .map { $0.key }
        let keepSet = Set(keep)
        bySession = bySession.filter { keepSet.contains($0.key) }
    }

    // MARK: - 提取器

    /// 提取 bundle id
    private func extractBundleID(from text: String) -> String? {
        // 匹配 com.xxx.xxx 格式
        let pattern = #"com\.[a-zA-Z0-9]+\.[a-zA-Z0-9.]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    /// 提取文件路径
    private func extractFilePath(from text: String) -> String? {
        // 匹配 /var/mobile/... 或 ~/Documents/... 格式
        let pattern = #"(/var/mobile/[^\s]+|~/[^\s]+|/private/var/[^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    /// 提取常见 App 名（简单版）
    private func extractAppName(from text: String) -> String? {
        let knownApps = [
            "微信": "com.tencent.xin",
            "小红书": "com.xingin.xhs",
            "抖音": "com.ss.iphone.ugc.Aweme",
            "淘宝": "com.taobao.taobao",
            "支付宝": "com.alipay.iphoneclient",
            "QQ": "com.tencent.mqq",
            "百度": "com.baidu.searchbox",
            "B站": "tv.danmaku.bili",
            "哔哩哔哩": "tv.danmaku.bili",
            "微博": "com.sina.weibo",
            "网易云音乐": "com.netease.163music",
            "QQ音乐": "com.tencent.QQMusic",
            "快手": "com.smile.gifmaker",
            "美团": "com.sankuai.meituan",
            "饿了么": "me.ele.iphone",
            "携程": "ctrip.iphone",
            "京东": "com.jd.iphone",
            "拼多多": "com.xunmeng.pinduoduo",
            "闲鱼": "com.taobao.fleamarket",
            "钉钉": "com.laiwang.DingTalk",
            "飞书": "com.larksuite.lark",
        ]

        for (name, _) in knownApps {
            if text.contains(name) {
                return name
            }
        }

        return nil
    }

    /// 提取操作类型（用户想做什么）
    func extractAction(from text: String) -> String? {
        // v3.1.71：查询/状态语境不记为 action（AI 实测：用户查"抓包状态"被误注入 "Last action: 抓包"，
        // 导致上下文推断错误）。只有明确的祈使/发起意图才记录。
        let queryContexts = ["状态", "查看", "检查", "查询", "看看", "看下", "看一下", "多少",
                             "是否", "能不能", "在不在", "有没有", "有吗", "吗", "?", "？",
                             "什么情况", "结果", "报错", "失败", "成功"]
        if queryContexts.contains(where: { text.contains($0) }) {
            return nil
        }
        let actions = [
            "分析": "分析 App 结构",
            "抓包": "网络抓包分析",
            "注入": "注入 dylib",
            "截图": "截图",
            "录屏": "录屏",
            "清理": "清理缓存",
            "备份": "备份",
            "恢复": "恢复",
            "安装": "安装 App",
            "卸载": "卸载 App",
            "启动": "启动 App",
            "重启": "重启 App",
            "停止": "停止 App",
            "修改": "修改内容",
            "读取": "读取内容",
            "写入": "写入内容",
            "删除": "删除内容",
        ]

        for (action, _) in actions {
            if text.contains(action) {
                return action
            }
        }

        return nil
    }
}
