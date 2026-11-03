import Foundation

// v7.2.3-fix18: AI 正文 block 化——正文/工具强隔离（对齐 OpenMinis block 模型）。
// 模型误输出 <|DSML| invoke> / <antml:invoke> / <invoke> 文本调用时，
// 渲染前从正文剥出工具段（.tool 块），剩余文本（.text 块）正常渲染——
// 工具调用绝不混进 AI 正文。
struct ContentBlock: Equatable {
    enum Kind: Equatable { case text, tool }
    var kind: Kind
    var text: String
    var toolName: String?
    var toolArgs: String?
    var toolTitle: String?
}

enum ContentBlocks {
    // v7.2.5-fix63：split 结果缓存——打字机每 tick / LazyVStack 离屏重建都会重跑
    // 正则分块（长消息成本高）；同一内容只算一次。容量上限 128，超限整体清空
    // （内容即 key，天然近似 LRU：重复出现的旧消息自动命中）。
    //
    // 2026-11-03 **崩溃修复**：这个缓存原来是裸的 `static var [String: [ContentBlock]]`，
    // split() 在 SwiftUI 渲染路径（主线程）和其它调用路径都会进 —— 而 Swift 的
    // Dictionary 不是线程安全的，两个线程同时写会破坏内部存储，直接
    // EXC_BAD_ACCESS 闪退（用户反馈「回复完直接卡闪退」，崩在工具卡刚出现那一下，
    // 正是流式收尾 + 主线程重渲染撞在一起）。
    // 现在用 NSLock 串行化。锁粒度是整段读写，但因为命中缓存时只是一次字典查找，
    // 开销可忽略；真正耗时的 splitRaw 在锁外做（下面那段），避免长文本持锁阻塞 UI。
    private static var splitCache: [String: [ContentBlock]] = [:]
    private static let splitLock = NSLock()

    static func split(_ text: String) -> [ContentBlock] {
        // 2026-11-03 **回退说明**（重要，别再犯）：
        //
        // 曾在这里加过一行 `CrashBreadcrumb.shared.mark(...)` 用来记录崩溃现场。
        // 结果是**灾难性的**：split() 在 MessageBubble.body 里被调用——
        // 打字机 0.02s 一帧、每个可见气泡都跑一次，而 mark() 内部是
        // FileHandle 写 + fsync 强制刷盘。主线程每秒被磁盘 IO 阻塞几十次，
        // 用户实测「上下滑动完全没反应」。
        //
        // 教训（已写进项目铁律）：**渲染路径上禁止任何 IO**。
        // 面包屑只允许出现在低频节点（发消息 / 工具执行 / 一轮结束），
        // 绝不能出现在 body 会被反复求值的地方。
        splitLock.lock()
        let hit = splitCache[text]
        splitLock.unlock()
        if let hit = hit { return hit }

        // 耗时计算放在锁外——持锁跑正则会让其它线程全排在这，滚动时就是卡顿源
        let result = splitRaw(text)

        splitLock.lock()
        if splitCache.count >= 128 { splitCache.removeAll(keepingCapacity: true) }
        splitCache[text] = result
        splitLock.unlock()
        return result
    }
    private static func splitRaw(_ text: String) -> [ContentBlock] {
        // 2026-11-03：先把 DeepSeek 系特殊 token 归一化（全角竖线 U+FF5C、双竖线 ||DSML||、
        // 零宽空格等）成半角 <|DSML|…>。否则下面 matchStartTag / findCloseTag 一条都匹配
        // 不到，整段 XML 会被当成正文原样打到气泡里——用户看到的就是「底部全是英文」。
        let normalized = ConversationStore.normalizeDSML(text)
        var blocks: [ContentBlock] = []
        var textBuf = ""
        let chars = Array(normalized)
        var i = 0
        // 2026-11-03：只要剥离过协议残渣，末尾的「保底吐原文」就不能再用原文。
        // 否则 `<|DSML|calls></|DSML|calls>` 这种「只有壳、没 invoke」的输出，
        // 全部被 skipWrapperTag 吞掉 → blocks 为空 → 兜底把**整段原文**打回气泡，
        // 用户看到的还是一行 `<|DSML|calls></|DSML|calls>`。等于白剥。
        var didStrip = false
        while i < chars.count {
            if chars[i] == "<" {
                if let (name, endIdx) = matchStartTag(chars, i) {
                    // ① 自闭合形态：<tool.describe name="app" />
                    //    标签本身就是完整的一次调用，后面根本没有闭合标签。
                    //    以前 isSelfClosing 定义了却没人调用，findCloseTag 对这类
                    //    返回 nil → 整个分支被跳过 → 用户就在气泡里看到这行英文。
                    if isSelfClosing(chars, from: i, endIdx: endIdx) {
                        let segment = String(chars[i..<endIdx])
                        if !textBuf.isEmpty {
                            blocks.append(ContentBlock(kind: .text, text: textBuf))
                            textBuf = ""
                        }
                        blocks.append(ContentBlock(
                            kind: .tool,
                            text: segment,
                            toolName: name,
                            toolArgs: inlineArgs(segment),
                            toolTitle: inlineTitle(segment)))
                        i = endIdx
                        didStrip = true
                        continue
                    }
                    // ② 成对形态（原有行为，不变）
                    if let closeIdx = findCloseTag(chars, endIdx) {
                        let segment = String(chars[endIdx..<closeIdx])
                        let (args, title) = parseParams(segment)
                        if !textBuf.isEmpty {
                            blocks.append(ContentBlock(kind: .text, text: textBuf))
                            textBuf = ""
                        }
                        blocks.append(ContentBlock(
                            kind: .tool,
                            text: String(chars[i...closeIdx]),
                            toolName: name,
                            toolArgs: args,
                            toolTitle: title))
                        i = closeIdx + 1
                        didStrip = true
                        continue
                    }
                }
                // ③ 外层包裹标签（<function_calls> / <|DSML|calls> …）
                //    它本身不是调用，但必须从正文剥掉，否则气泡里会留下英文壳子
                //    （穷举扫描的 L/K 两种形态就是栽在这里：只剥离不解析 / 只解析不剥离）。
                if let skipTo = skipWrapperTag(chars, i) {
                    i = skipTo
                    didStrip = true
                    continue
                }
            }
            textBuf.append(chars[i])
            i += 1
        }
        if !textBuf.isEmpty {
            blocks.append(ContentBlock(kind: .text, text: textBuf))
        }
        if blocks.isEmpty && !didStrip {
            // 用原文（不是归一化后的）——没切出块时保持用户看到的原样。
            // 注意条件里带了 !didStrip：剥离过就不能回退原文。
            blocks.append(ContentBlock(kind: .text, text: text))
        }
        return blocks
    }

    /// 从 startIdx 匹配文本调用起始标签，返回 (工具名, 标签结束位置)
    ///
    /// 2026-11-03 重写：加了自闭合短标签 + 命名空间变体。
    ///
    /// 为什么必须补：模型不止写 `invoke` 那一种。实测（用穷举脚本扫 14 种形态）
    /// 以下 5 种全部漏网，直接被当正文打到气泡里：
    ///   · `<tool.describe name="app" />`      ← 用户截图里这条
    ///   · `<call name="app" />`
    ///   · `<tool:describe name="app" />`
    ///   · `<function_calls>…</function_calls>`（外层残留）
    ///   · `<|DSML|calls></|DSML|calls>`（只有开闭、无 invoke）
    /// 原来只认 `invoke name=`，所以「补一个漏一个」永远补不完。
    ///
    /// 现在的策略分两层：
    ///   ① 先匹配成对的 invoke（原有 3 条，行为不变，优先级最高）；
    ///   ② 再匹配自闭合短标签 `<(tool[.:])?name ... />`——这条才是根治，
    ///      因为模型写自闭合形态时工具名一定带点号或前缀（tool. / call / tool:）。
    /// 名字不合法的（比如 `<p>`、`<br>` 这种 HTML）不会被误判：下面白名单会再过滤一次。
    private static func matchStartTag(_ chars: [Character], _ startIdx: Int) -> (String, Int)? {
        let s = String(chars[startIdx...])
        let patterns = [
            // ① 成对 invoke 形态（归一化后竖线后面**没有**空格，所以必须 \s* 而不是 " "）
            #"^<\|DSML\|\s*invoke\s+name=["']([^"']+)["'][^>]*>"#,
            #"^<antml:invoke\s+name=["']([^"']+)["'][^>]*>"#,
            #"^<invoke\s+name=["']([^"']+)["'][^>]*>"#,
            // ② 自闭合短标签：<tool.describe name="app" />
            //    工具名允许点号、下划线、短横、冒号（tool.describe / tool:describe /
            //    shell_exec / shell-exec 都合法），要求**至少含一个分隔符**才当工具调用，
            //    避免把 `<div>`、`<p>` 这类纯单词标签误判。
            #"^<\s*(tool[.:][A-Za-z0-9_.\-]+|[a-z][a-z0-9_\-]*[.:][A-Za-z0-9_.\-]+)\b([^>]*?)/\s*>"#,
            // ③ <call name="app" /> 这种只有 call 前缀的
            #"^<\s*call\s+name=["']([^"']+)["'][^>]*?/?>"#,
        ]
        for (idx, p) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let ns = s as NSString
            guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 1,
                  let full = Range(m.range, in: s),
                  let nameR = Range(m.range(at: 1), in: s) else { continue }
            var name = String(s[nameR])
            _ = idx

            name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            // 2026-11-03 坐标修复：原来用 `full.upperBound.utf16Offset(in: s)`，
            // 得到的是 **UTF-16 偏移**，却拿去切 `[Character]` 数组。
            // 只要消息里有 emoji（每个占 2 个 UTF-16 单元、1 个 Character），
            // 切点就会往后错位，轻则工具块粘连正文，重则越界崩在渲染路径上。
            // 必须用 distance(in:) 拿 Character 距离。
            let charLen = s.distance(from: s.startIndex, to: full.upperBound)
            return (name, startIdx + charLen)
        }
        return nil
    }

    /// 自闭合标签内联参数：`<tool.describe name="app" />` 里的 `name="app"` 之类。
    /// 成对形态有 <parameter> 段可解析；自闭合形态只能从标签属性里抠。
    private static func inlineArgs(_ tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"([A-Za-z_][A-Za-z0-9_\-]*)\s*=\s*["']([^"']*)["']"#) else {
            return nil
        }
        let ns = tag as NSString
        let ms = re.matches(in: tag, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return nil }
        var pairs: [String] = []
        for m in ms where m.numberOfRanges > 2 {
            let k = ns.substring(with: m.range(at: 1))
            let v = ns.substring(with: m.range(at: 2))
            // 工具名本身不是参数，跳过
            if k.lowercased() == "name" { continue }
            pairs.append("\"\(k)\": \"\(v)\"")
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: ",\n")
    }

    private static func inlineTitle(_ tag: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: #"tool_title\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 外层包裹标签（`<function_calls>` / `<|DSML|calls>` / `<antml:function_calls>` …）
    /// 既不是工具调用也不是正文，直接整段吞掉。返回吞完后的位置；不匹配返回 nil。
    ///
    /// 为什么不交给 matchStartTag：这些标签**没有工具名**，硬塞进工具块会生成
    /// 一张名字为 `calls` 的假工具卡；留在正文就是用户看到的英文残渣。
    private static func skipWrapperTag(_ chars: [Character], _ startIdx: Int) -> Int? {
        let rest = String(chars[startIdx...])
        let opens = [
            "<function_calls>", "<function_calls >",
            "<|DSML|calls>", "<|DSML| calls>",
            "<antml:function_calls>",
            "</function_calls>", "</|DSML|calls>", "</|DSML| calls>",
            "</antml:function_calls>",
        ]
        for o in opens where rest.hasPrefix(o) {
            return startIdx + o.count
        }
        return nil
    }

    /// 自闭合标签（`<tool.describe name="app" />`）没有闭合标签，
    /// 所以 findCloseTag 返回 nil 时不能直接放弃 —— 交给这个函数判断
    /// 「起始标签本身就是完整调用」。
    ///
    /// 怎么判：标签以 `/>` 结尾就是自闭合，调用到此结束。
    static func isSelfClosing(_ chars: [Character], from startIdx: Int, endIdx: Int) -> Bool {
        guard endIdx <= chars.count, endIdx > startIdx else { return false }
        var k = endIdx - 1
        // 跳过空白
        while k > startIdx, chars[k] == " " || chars[k] == "\n" || chars[k] == "\t" { k -= 1 }
        return chars[k] == ">"
            && k - 1 >= startIdx
            && chars[k - 1] == "/"
    }

    /// 从 endIdx 找闭合标签位置（多形态）
    ///
    /// 2026-11-03：原来只认 "</|DSML|>"，但模型真实输出的是
    /// "</|DSML|invoke>" / "</|DSML| invoke>"（带 invoke 字样），
    /// 于是 findCloseTag 永远返回 nil → 整块工具段被当正文打印。
    /// 这里按"竖线结尾 + 可选 invoke/空 + >"统一匹配。
    private static func findCloseTag(_ chars: [Character], _ from: Int) -> Int? {
        var j = from
        while j < chars.count {
            if chars[j] == "<" {
                let rest = String(chars[j...])
                let candidates = [
                    "</|DSML|invoke>", "</|DSML| invoke>", "</|DSML|>",
                    "</antml:invoke>", "</invoke>",
                    // 也允许里外多一层 calls 包裹
                    "</|DSML|calls>", "</|DSML| calls>",
                ]
                for c in candidates where rest.hasPrefix(c) {
                    return j + c.count
                }
            }
            j += 1
        }
        return nil
    }

    /// 解析 antml parameter 段；返回 (参数串, tool_title)
    /// 字符扫描版（闭合标签用拼接，字面量闭合序列会截断外层参数）
    private static func parseParams(_ segment: String) -> (String?, String?) {
        var dict: [String: String] = [:]
        // 2026-11-03：闭合标签有多种写法——</parameter> / </|DSML|parameter> / </antml:parameter>
        let closeTags = ["</" + "parameter>", "</|DSML|parameter>", "</|DSML| parameter>", "</antml:parameter>"]
        // 起始标记同理：<parameter name= / <|DSML|parameter name= / <antml:parameter name=
        let markers = ["<parameter name=", "<|DSML|parameter name=", "<|DSML| parameter name=",
                       "<antml:parameter name="]
        let chars = Array(segment)
        var i = 0
        while i < chars.count {
            let rest = String(chars[i...])
            guard let marker = markers.first(where: { rest.hasPrefix($0) }) else {
                i += 1
                continue
            }
            var j = i + marker.count
            var pname = ""
            while j < chars.count, chars[j] != "\"" { pname.append(chars[j]); j += 1 }
            j += 1
            while j < chars.count, chars[j] != ">" { j += 1 }
            j += 1
            guard j <= chars.count else { break }
            let tail = String(chars[j...])
            // 取最近的一个闭合标签（不同写法混用也能正确切）
            var hit: (Range<String.Index>, Int)?
            for c in closeTags {
                if let r = tail.range(of: c) {
                    if hit == nil || r.lowerBound < hit!.0.lowerBound {
                        hit = (r, c.count)
                    }
                }
            }
            if let h = hit {
                let value = String(tail[..<h.0.lowerBound])
                dict[pname] = value
                i = j + h.0.lowerBound.utf16Offset(in: tail) + h.1
                continue
            }
            i += 1
        }
        let title = dict["tool_title"]
        var args: String?
        if !dict.isEmpty {
            let pairs = dict.keys.sorted().map { k -> String in
                let v = dict[k] ?? ""
                return "\"\(k)\": \"\(v)\""
            }
            args = pairs.joined(separator: ",\n")
        } else {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { args = trimmed }
        }
        return (args, title)
    }
}
