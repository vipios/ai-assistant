import Foundation

// v7.2.3-fix20：连续工具折叠——相邻的已完成 tool 消息聚合成一组
// （对齐 OpenMinis "连续工具调用折叠为一行运行了 N 个工具 + 总耗时"）。
//
// 2026-11-05 **用户定调（重要，别再改回去）**：
//   「连续使用的你都给折叠起来工具，他运用了我页看不懂，但是给我干什么，
//     我只要最后我想要的，在过程中如果出现什么错误他最后的总结报告里面就写一下就完了」
//
// 所以折叠规则从「≥2 条已完成才折」放宽成**所有工具消息一律折叠**，理由有三：
//   ① 用户根本不看工具细节，单条工具卡展开占大半屏，纯噪声；
//   ② **单条 → 多条的过渡会让 id 从 `m-<uuid>` 跳成 `t-<uuid>`**。
//      SwiftUI 把它当成「旧视图消失 + 新视图出现」，LazyVStack 会销毁重建
//      这一片 cell，contentSize 瞬间塌陷 → UIScrollView 把 contentOffset
//      夹回 0 → 视觉上就是从最新回复**直接跳到列表最顶端**，而且因为
//      吸附状态被连带判成 false，就再也不回来了。这是用户报的
//      「ai在干活的时候直接从最下面的最新回复跳到最上面」的直接病根。
//      统一折叠后，工具从出现到完成 id 恒为 `t-<首条 uuid>`，永不变。
//   ③ running 中的卡也纳入折叠，界面上就只剩一行「执行中 · N 个工具」，
//      真正的实时进度由输入框上方那条常驻 RunStatusStrip 负责
//      （它不随列表滚动，AI 干活时一直看得见）。
enum ChatListGrouping {
    enum Item: Equatable {
        case msg(ChatMessage)
        case tools([ChatMessage])

        var id: String {
            switch self {
            case .msg(let m): return "m-" + m.id.uuidString
            case .tools(let ms):
                // v7.2.3-fix20.1：组 id 只用首条 UUID（去掉条数）——
                // 并发波内工具增量完成（A → A+B → A+B+C）时组 id 保持稳定，
                // 用户已展开的组不会因条数变化而折叠回去。
                // 2026-11-05：这条现在**同时**是防「AI 干活时跳顶」的关键，
                // 见文件头 ② —— 千万别再加回条数或内容摘要。
                return "t-" + (ms.first?.id.uuidString ?? "")
            }
        }

        /// 组内总耗时（秒）——各工具卡耗时之和
        var totalDuration: Double? {
            if case .tools(let ms) = self {
                let sum = ms.reduce(0.0) { $0 + ($1.toolDuration ?? 0) }
                return sum > 0 ? sum : nil
            }
            return nil
        }

        /// 组内失败条数（用于折叠行上那个 ❌ 角标——用户不需要看细节，
        /// 但必须知道"这一步出过错"，细节交给本轮总结报告）
        var failedCount: Int {
            if case .tools(let ms) = self {
                return ms.reduce(0) { $0 + ($1.isError ? 1 : 0) }
            }
            return 0
        }

        /// 组内是否还有正在执行的卡
        var hasRunning: Bool {
            if case .tools(let ms) = self {
                return ms.contains { $0.isRunning }
            }
            return false
        }
    }

    static func group(_ messages: [ChatMessage]) -> [Item] {
        // 2026-11-03 性能：加一级缓存。
        //
        // group() 被放在 ChatView.body 的 ForEach 里，body 每次重算都会调用它，
        // 而它是 O(n) 全量遍历 + 构造新数组。长会话（几百上千条消息）时，
        // 每次微小状态变化（打字机 tick、滚动、工具卡刷新）都要重跑一遍，
        // 这是「看 AI 干活时手机发烫」的主要来源之一。
        //
        // 缓存键不比对整份数组内容（那本身就是 O(n)），而是用几个便宜且可靠的
        // 特征量判定「消息列表有没有变」：
        //   · 条数
        //   · 首条 id
        //   · 末条 id + 末条内容长度（覆盖"最后一条还在流式增长"的情况）
        //   · 工具消息里「还在跑的条数」「出错的条数」「内容总长」
        //     （覆盖并行批：A 完成后 B 还在跑时末条没变，但折叠行要跟着变）
        // 这些任一变化就重算，否则直接返回上次结果。
        // 注意：必须在主线程访问（SwiftUI body 恒在主线程），所以不加锁。
        let count = messages.count
        let firstId = messages.first?.id
        let lastId = messages.last?.id
        let lastLen = messages.last?.content.count ?? 0
        // 2026-11-05：把「还在跑的条数」「出错的条数」「工具内容总长」也纳入缓存键。
        //
        // 只比对末条是不够的：并行批里 A 完成、B 还在跑时，末条（B）的
        // id/长度/isRunning 全都没变，缓存会命中 → A 那张卡永远停在「执行中」。
        // 这里遍历一遍只读布尔和一个 O(1) 的 utf8.count，微秒级，
        // 远低于重建 Item 数组 + 重排全部气泡的代价。
        var runningCount = 0
        var errorCount = 0
        var toolBytes = 0
        for m in messages where m.isTool {
            if m.isRunning { runningCount += 1 }
            if m.isError { errorCount += 1 }
            toolBytes += m.content.utf8.count
        }
        // 2026-11-05：正在流式/正在产出的消息 id 要参与缓存判定。
        //
        // 为什么必须先读再判缓存：`liveIDs` 决定某条空壳 assistant 吞不吞（见下方
        // isInvisibleAssistant 的 ⚠️）。流式刚开始时 content 还是空的、id 在 liveIDs 里
        // → 不吞；流式结束后 id 移出 liveIDs → 同一份 messages 会算出不同分组。
        // 若这俩 id 不进缓存键，第二次会命中第一次的结果，表现为"流式结束后气泡布局错位"。
        //
        // 读的是两个可选 UUID，O(1)，不影响这个函数原本的性能目标。
        var liveIDs = Set<UUID>()
        // 类名是 ConversationStore（不是 ChatStore）——属性是 internal，同模块可读。
        if let sid = ConversationStore.shared.streamingMessageId { liveIDs.insert(sid) }
        if let pid = ConversationStore.shared.liveProducedID { liveIDs.insert(pid) }
        if let c = _cache,
           c.count == count, c.firstId == firstId, c.lastId == lastId,
           c.lastLen == lastLen, c.running == runningCount,
           c.errors == errorCount, c.toolBytes == toolBytes,
           c.liveIDs == liveIDs {
            return c.items
        }

        var out: [Item] = []
        var run: [ChatMessage] = []
        func flush() {
            // 2026-11-05：≥1 就成组（原来 ≥2）。单条工具也折成一行的理由见文件头 ②：
            // 一旦单条走 .msg，等第二条进来时 id 会从 m- 跳成 t-，那次跳变
            // 就是「AI 干活时滚到最上面」的触发点。
            if !run.isEmpty {
                out.append(.tools(run))
            }
            run = []
        }
        // 2026-11-05 **用户报「4 张『运行了 N 个工具』卡拆成 4 个」的直接修复**：
        //
        // 现象：模型每调一次工具，往往在两次调用之间吐一小段 assistant 文本
        //      （有时是空串，有时只有空白，有时是一句解说）。
        //      原来的逻辑「非 tool 就地 flush()」导致工具流被这些消息**切断**，
        //      4 次工具调用 → 4 个独立折叠组。
        // 用户原话：「运用了什么工具，能不能整体都折叠到一起，
        //           不要单独显示这么多，我不需要看它运行了什么，我只要结果」
        //
        // 修法：**空壳 assistant 消息不打断工具流**（判定见 isInvisibleAssistant）。
        //      有正文的消息仍照常 flush 单独成气泡——那段话用户是要看的。
        //      liveIDs 已在上面算好（参与缓存判定），这里直接用。
        for m in messages {
            if m.isTool {
                run.append(m)
            } else if Self.isInvisibleAssistant(m, liveIDs: liveIDs) {
                // 空壳 assistant：不打断工具串，直接跳过（不占屏）
                continue
            } else {
                flush()
                out.append(.msg(m))
            }
        }
        flush()
        _cache = (count, firstId, lastId, lastLen, runningCount, errorCount, toolBytes, liveIDs, out)
        return out
    }

    /// 这条消息是不是「用户看不见的空壳」。
    ///
    /// 只有 assistant 角色才可能被吞：user / system 消息即使短也要显示（用户自己发的、
    /// 系统提示），tool 消息走 isTool 分支，根本到不了这里。
    ///
    /// 2026-11-05 **为什么会走到这里**（不是猜的，对着 Models.swift 写入点看出来的）：
    ///   `onThinking` 收到思考增量时，若当前没有流式消息，会新建一条
    ///     `ChatMessage(role: "assistant", content: "")` + `thinking = delta`（2074 行）。
    ///   所以**每个"思考阶段"都可能留下一条正文为空的 assistant 消息**。
    ///   它夹在两次工具调用之间就会切断工具流 —— 用户看到的 4 张
    ///   「运行了 2/1/1/1 个工具」就是这么来的。
    ///
    /// 判定**不看 thinking**：思考是过程信息（用户明确说不看过程）。
    /// 而且工具卡内部本来就会渲染同一份 thinking（ChatView.toolBubble 3778 行），
    /// 所以吞掉这条空壳不会丢失思考内容。
    ///
    /// ⚠️ 但**正在流式的那条绝不能吞**：
    ///   那条消息是流式载体（`streamingMessageId` 指向它），正文到达时会被原地填入。
    ///   刚开始 content 就是空的，若此刻吞掉，会出现"正文一到达才突然冒出一个气泡"的闪烁。
    ///   所以这里显式排除流式/正在产出的消息 id。
    static func isInvisibleAssistant(_ m: ChatMessage, liveIDs: Set<UUID> = []) -> Bool {
        guard m.role == "assistant", !m.isTool else { return false }
        // 正在流式/正在产出的，一律不吞（见上 ⚠️）
        if liveIDs.contains(m.id) { return false }
        if !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if let imgs = m.imageDataURLs, !imgs.isEmpty { return false }
        // 注意：**不检查 thinking**。理由见上。
        return true
    }

    /// 最近一次分组结果 + 判定用的特征量
    private static var _cache: (count: Int, firstId: UUID?, lastId: UUID?,
                                lastLen: Int, running: Int, errors: Int,
                                toolBytes: Int, liveIDs: Set<UUID>, items: [Item])?
}
