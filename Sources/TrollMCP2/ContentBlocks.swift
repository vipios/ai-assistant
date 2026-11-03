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
    private static var splitCache: [String: [ContentBlock]] = [:]
    static func split(_ text: String) -> [ContentBlock] {
        if let hit = splitCache[text] { return hit }
        let result = splitRaw(text)
        if splitCache.count >= 128 { splitCache.removeAll(keepingCapacity: true) }
        splitCache[text] = result
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
        while i < chars.count {
            if chars[i] == "<" {
                if let (name, endIdx) = matchStartTag(chars, i),
                   let closeIdx = findCloseTag(chars, endIdx) {
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
                    continue
                }
            }
            textBuf.append(chars[i])
            i += 1
        }
        if !textBuf.isEmpty {
            blocks.append(ContentBlock(kind: .text, text: textBuf))
        }
        if blocks.isEmpty {
            // 用原文（不是归一化后的）——没切出块时保持用户看到的原样
            blocks.append(ContentBlock(kind: .text, text: text))
        }
        return blocks
    }

    /// 从 startIdx 匹配文本调用起始标签，返回 (工具名, 标签结束位置)
    private static func matchStartTag(_ chars: [Character], _ startIdx: Int) -> (String, Int)? {
        let s = String(chars[startIdx...])
        let patterns = [
            // 2026-11-03 关键：归一化后是 "<|DSML|invoke ...>"（竖线后**没有**空格），
            // 原正则写成 "\| invoke" 强制要求空格 → 一条都匹配不到 → 整段 XML 当正文打印。
            // 这里改成 \s* 容忍零个或多个空格。
            #"^<\|DSML\|\s*invoke\s+name="([^"]+)"[^>]*>"#,
            #"^<antml:invoke\s+name="([^"]+)"[^>]*>"#,
            #"^<invoke\s+name="([^"]+)"[^>]*>"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range, in: s),
               let nr = Range(m.range(at: 1), in: s) {
                return (String(s[nr]), startIdx + r.upperBound.utf16Offset(in: s))
            }
        }
        return nil
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
