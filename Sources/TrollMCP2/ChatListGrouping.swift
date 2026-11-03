import Foundation

// v7.2.3-fix20：连续工具折叠——相邻的已完成 tool 消息聚合成一组
// （对齐 OpenMinis "连续工具调用折叠为一行运行了 N 个工具 + 总耗时"）。
// 规则：连续 isTool 且 !isRunning（已完成）的消息，≥2 条折叠成组；
// running 中的工具卡不折叠（避免流式过程布局跳动），单条不折叠。
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
                // 用户已展开的组不会因条数变化而折叠回去
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
    }

    static func group(_ messages: [ChatMessage]) -> [Item] {
        // 2026-11-03 性能：加一级缓存。
        //
        // group() 被放在 ChatView.body 的 ForEach 里，body 每次重算都会调用它，
        // 而它是 O(n) 全量遍历 + 构造新数组。长会话（几百上千条消息）时，
        // 每次微小状态变化（打字机 tick、滚动、工具卡刷新）都要重跑一遍，
        // 这是「看 AI 干活时手机发烫」的主要来源之一。
        //
        // 缓存键不比对整份数组内容（那本身就是 O(n)），而是用三个便宜且可靠的
        // 特征量判定「消息列表有没有变」：
        //   · 条数
        //   · 首条 id
        //   · 末条 id + 末条内容长度（覆盖"最后一条还在流式增长"的情况）
        // 这三者任一变化就重算，否则直接返回上次结果。
        // 注意：必须在主线程访问（SwiftUI body 恒在主线程），所以不加锁。
        let count = messages.count
        let firstId = messages.first?.id
        let lastId = messages.last?.id
        let lastLen = messages.last?.content.count ?? 0
        let lastRunning = messages.last?.isRunning ?? false
        if let c = _cache,
           c.count == count, c.firstId == firstId, c.lastId == lastId,
           c.lastLen == lastLen, c.lastRunning == lastRunning {
            return c.items
        }

        var out: [Item] = []
        var run: [ChatMessage] = []
        func flush() {
            if run.count >= 2 {
                out.append(.tools(run))
            } else {
                out.append(contentsOf: run.map { .msg($0) })
            }
            run = []
        }
        for m in messages {
            if m.isTool && !m.isRunning {
                run.append(m)
            } else {
                flush()
                out.append(.msg(m))
            }
        }
        flush()
        _cache = (count, firstId, lastId, lastLen, lastRunning, out)
        return out
    }

    /// 最近一次分组结果 + 判定用的特征量
    private static var _cache: (count: Int, firstId: UUID?, lastId: UUID?,
                                lastLen: Int, lastRunning: Bool, items: [Item])?
}
