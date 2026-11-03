import Foundation
import SwiftUI

// MARK: - 聊天运行时诊断
//
// 2026-11-03 新增。用户原话：
//   「你在 ipa 里面上上一个检测所有的探针不行吗，现在 bug 太多了尤其是聊天，
//     还有 ai 在给我制作的时候还有就是不知道怎么就停止了，也没有原因」
//
// 背景：项目里原有一套 DeviceProbe（查越狱/TrollStore/注入/权限/存储），
// 但它查的是**设备环境**，查不到聊天为什么断、为什么停、为什么没结果。
// 那类问题是**运行时状态**，必须有另一套记录。
//
// 这套东西只做三件事，都很朴素：
//   ① 每次请求结束（成功/失败/被停）写一条结构化记录到本地环形日志
//   ② 停止时一定给用户一条看得懂的中文说明 —— 不再有「莫名停止」
//   ③ 聊天页能查到最近 50 条记录，看清是哪一步断的
//
// 为什么不接后台服务器：手机在外面时后台可能都连不上，本地记录才查得到。

/// 一次请求的最终命运。用来在诊断页上一眼筛出「不正常结束」的那些。
enum ChatTurnOutcome: String, Codable {
    case success        // 正常完成
    case failed         // 网络/接口失败
    case stopped        // 用户自己点的停止
    case autoStopped    // 系统判定继续没意义，自动停下（必须带原因）
    case emptyReply     // 模型给了空回复
    case toolLoop       // 工具重复调用到上限

    var label: String {
        switch self {
        case .success:     return "正常完成"
        case .failed:      return "请求失败"
        case .stopped:     return "手动停止"
        case .autoStopped: return "自动停止"
        case .emptyReply:  return "空回复"
        case .toolLoop:    return "工具循环"
        }
    }

    /// 是不是「用户没主动停，但也没正常完成」——诊断页默认高亮这一类。
    var isAbnormal: Bool {
        switch self {
        case .success, .stopped: return false
        default: return true
        }
    }
}

struct ChatTurnRecord: Codable, Identifiable {
    var id: String = UUID().uuidString
    var at: Date = Date()
    var modelName: String = ""
    var outcome: String = ChatTurnOutcome.success.rawValue
    var reason: String = ""            // 中文的一句话原因（autoStopped 时必有）
    var detail: String = ""            // 更细的上下文：状态码、轮次、换号次数
    var durationMs: Int = 0
    var rounds: Int = 0                // 工具轮次
    var switches: Int = 0              // 换账号/换模型次数
    var httpStatus: Int? = nil

    var outcomeEnum: ChatTurnOutcome {
        ChatTurnOutcome(rawValue: outcome) ?? .success
    }
}

/// 环形日志 + 用户可见说明的统一入口。
final class ChatDiagnostics: ObservableObject {
    static let shared = ChatDiagnostics()
    private init() { load() }

    /// 最多留 200 条：够回溯好几天的正常使用，也不会把 UserDefaults 撑大。
    private let cap = 200
    private let storeKey = "chat.diagnostics.v1"

    @Published private(set) var records: [ChatTurnRecord] = []

    // MARK: - 写入

    func record(_ r: ChatTurnRecord) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.records.insert(r, at: 0)
            if self.records.count > self.cap {
                self.records.removeLast(self.records.count - self.cap)
            }
            self.save()
        }
    }

    /// 便捷入口：从当前状态拼一条记录。
    func log(model: String, outcome: ChatTurnOutcome, reason: String = "",
             detail: String = "", durationMs: Int = 0, rounds: Int = 0,
             switches: Int = 0, httpStatus: Int? = nil) {
        var r = ChatTurnRecord()
        r.modelName = model
        r.outcome = outcome.rawValue
        r.reason = reason
        r.detail = detail
        r.durationMs = durationMs
        r.rounds = rounds
        r.switches = switches
        r.httpStatus = httpStatus
        record(r)
    }

    func clear() {
        records.removeAll()
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    // MARK: - 读

    /// 诊断页默认展示：最近 N 条，异常优先。
    func recent(_ n: Int = 50) -> [ChatTurnRecord] {
        Array(records.prefix(n))
    }

    var abnormalCount: Int {
        records.prefix(50).filter { $0.outcomeEnum.isAbnormal }.count
    }

    // MARK: - 存档

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([ChatTurnRecord].self, from: data) else { return }
        records = list
    }
}

// MARK: - 停止时给用户的话

extension ConversationStore {

    /// 统一的「就这么停了」出口。
    ///
    /// 为什么需要它：代码里以前有六七处 `return` 收尾，每一处都只改了内部状态，
    /// 界面上的表现就是「转圈没了，啥也没说」——用户只能反复问「怎么又停了」。
    /// 现在所有自动停止都必须从这里走，强制带一条中文说明落到会话里。
    ///
    /// 为什么内部状态复位放在 Models.swift 的 `finishTurnInternal()` 里：
    /// `currentClient` / `activeConvId` / `thinkBuffer` 等都是 `private`，
    /// 跨文件（本文件）访问不到。那些私有状态由类内部的方法处理，
    /// 这里只负责「给用户看得见的东西」和日志。
    ///
    /// - Parameters:
    ///   - title: 气泡首行，一句话说清发生了什么
    ///   - body: 详细说明 + 下一步怎么办（给用户，不是给开发者）
    ///   - reason: 写进诊断日志的简短原因（一两个词，方便统计）
    static func reportStop(to store: ConversationStore,
                           title: String,
                           body: String,
                           reason: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "⚠️ \(title)"
            : "⚠️ \(title)\n\n\(body)"
        let msg = ChatMessage(role: "assistant", content: text, isError: true)
        _ = store.appendToCurrent(msg)

        // 内部状态复位（含 private 成员）由类内部完成
        store.finishTurnInternal()

        CrashBreadcrumb.shared.mark("自动停止：\(reason)")
        ChatDiagnostics.shared.log(
            model: ModelStore.shared.defaultConfig?.model ?? "",
            outcome: .autoStopped,
            reason: reason,
            detail: String(title.prefix(80)))
    }
}
