// PolicyConfirm.swift — v1.0.35 授权确认门（break-glass / human-in-the-loop）
//
// 解决的问题：用户让 AI 做一件它「本来会拒绝」或「自己觉得该先问一句」的事，
// 老行为是 AI 直接输出一段「这违反 XX，建议你…」然后停手，用户再说「确定」
// 也只能靠模型自己理解中文意图——有效但不可靠，且没有任何留痕。
//
// 现在的路径：
//   ① AI 调 policy.confirm(action/detail/risk)，不执行任何实际操作；
//   ② 聊天界面弹出一张确认卡，用户点「允许执行一次」或「拒绝」；
//   ③ 允许 → 签发一张**一次性票据**（5 分钟、单次、可绑定到具体工具）；
//   ④ AI 把票据作为 `_confirm_token` 传给真正要调的工具，dispatch 校验后放行一次；
//   ⑤ 全过程写 Documents/Policy/decisions.log。
//
// 刻意不做的事：
//   · 票据不是万能钥匙——它只代表「用户点过确认」，不等于绕过模型底线。
//     第三方 App 付费/授权验证破解这类事，用户点一百次允许也不会执行。
//   · 聊天文本不构成授权。只有用户在卡片上点按钮才算，避免提示词注入骗过确认门。

import Foundation
import SwiftUI
import UIKit

// MARK: - 请求模型

struct PolicyRequest: Identifiable {
    let id: String
    let action: String
    let detail: String
    let risk: String
    let createdAt: Date
}

// MARK: - 确认门

final class ConfirmGate: ObservableObject {
    static let shared = ConfirmGate()

    /// 当前待确认请求（nil = 没有）。界面绑定它来显示/隐藏卡片。
    @Published private(set) var pending: PolicyRequest?

    /// 已批准的次数（界面用它刷新「本次会话已放行 N 次」这类计数）
    @Published private(set) var approvedCount: Int = 0
    @Published private(set) var deniedCount: Int = 0

    private struct Ticket {
        let action: String
        let tool: String        // 空 = 任意工具
        let expires: Date
        var used: Bool
    }

    private var tickets: [String: Ticket] = [:]
    private var semaphores: [String: DispatchSemaphore] = [:]
    private var results: [String: Bool] = [:]
    private let lock = NSLock()

    private let enabledKey = "trollmcp2.policy_confirm_enabled"

    /// 总开关：关掉后 AI 调 policy.confirm 直接报错（不给请求通道，不是自动放行）。
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            objectWillChange.send()
        }
    }

    private init() {
        // 晚于 registerBuiltinTools（AppMain 里同步执行）——避免注册表尚未就绪
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.registerTool()
        }
    }

    // MARK: 对外

    /// 请求一次授权并阻塞等待用户点击。
    /// 返回值直接作为工具结果交给模型，所以文案要写成「给模型看的下一步指示」。
    func ask(action: String, detail: String, risk: String,
             tool: String, timeout: Double) -> [String: Any] {
        // 主线程调用会死锁（弹卡本身要主线程渲染）。正常工具链都在后台线程，
        // 这里只是兜底——真走到这条就明确告诉模型别等了。
        guard !Thread.isMainThread else {
            return ["ok": false, "status": "unsupported",
                    "message": "当前上下文不能在主线程弹确认框。换到后台线程再调，或直接让用户手动操作。"]
        }

        let token = Self.token()
        let req = PolicyRequest(id: token, action: action, detail: detail,
                                risk: risk, createdAt: Date())
        let sem = DispatchSemaphore(value: 0)

        lock.lock()
        semaphores[token] = sem
        lock.unlock()

        DispatchQueue.main.async {
            // 已经有一张卡在等：前一张判为「被新请求取代」，避免卡片叠在一起。
            // 实际极少发生（模型通常一次只请求一个授权）。
            if let old = self.pending, old.id != token {
                self.settle(old.id, allow: false)
                self.audit("superseded", old.action)
            }
            self.pending = req
            // 用户可能正停在别的页面（设置页会盖住这张卡），震一下至少他知道有事
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }

        let wait = sem.wait(timeout: .now() + timeout)

        lock.lock()
        let approved = results[token] ?? false
        results.removeValue(forKey: token)
        semaphores.removeValue(forKey: token)
        lock.unlock()

        DispatchQueue.main.async {
            if self.pending?.id == token { self.pending = nil }
        }

        if wait == .timedOut {
            audit("timeout", "\(action)（\(Int(timeout))s 无响应）")
            return ["ok": false, "status": "timeout",
                    "message": "用户 \(Int(timeout)) 秒内没有响应授权请求。先停下这一步，用一句话告诉用户「卡在授权确认」并说明你打算做什么，等他再说继续。"]
        }

        if !approved {
            audit("denied", action)
            return ["ok": false, "status": "denied",
                    "message": "用户拒绝了这次授权。不要重试、不要换措辞再问一遍、不要绕路实现同一件事。用一句话说明这一步按用户意愿跳过了。"]
        }

        let ticket = issue(action: action, tool: tool)
        audit("approved", "\(action) → ticket \(ticket)")
        return ["ok": true, "status": "approved", "ticket": ticket,
                "message": "用户已允许。把 _confirm_token=\(ticket) 作为参数传给你要执行的那个工具，立刻调用一次。票据单次有效、5 分钟过期，不要拿它做别的事。"]
    }

    /// 界面按钮回调。
    func answer(_ token: String, allow: Bool) {
        DispatchQueue.main.async {
            if self.pending?.id == token { self.pending = nil }
        }
        settle(token, allow: allow)
    }

    private func settle(_ token: String, allow: Bool) {
        lock.lock()
        guard let sem = semaphores[token] else { lock.unlock(); return }
        if results[token] == nil { results[token] = allow }
        lock.unlock()
        // @Published 必须在主线程改——ask() 的等待线程是后台线程，不能直接写
        DispatchQueue.main.async {
            if allow { self.approvedCount += 1 } else { self.deniedCount += 1 }
        }
        sem.signal()
    }

    // MARK: 票据

    private func issue(action: String, tool: String) -> String {
        let tk = Self.token()
        lock.lock()
        pruneExpired()
        tickets[tk] = Ticket(action: action, tool: tool,
                             expires: Date().addingTimeInterval(300), used: false)
        lock.unlock()
        return tk
    }

    /// 目标工具执行前调用：有效则标记为已用并返回 true。
    func consume(_ token: String, tool: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneExpired()
        guard var t = tickets[token], !t.used else { return false }
        if !t.tool.isEmpty {
            let want = t.tool.replacingOccurrences(of: "_", with: ".")
            let got = tool.replacingOccurrences(of: "_", with: ".")
            guard want == got else { return false }
        }
        t.used = true
        tickets[token] = t
        return true
    }

    /// 调用方持 lock 时使用
    private func pruneExpired() {
        let now = Date()
        tickets = tickets.filter { $0.value.expires > now && !$0.value.used }
    }

    private static func token() -> String {
        // 短、可读、够用：票据只在本机内存里活 5 分钟
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    // MARK: 审计

    private var policyDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Policy", isDirectory: true)
    }

    private func audit(_ action: String, _ detail: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] \(action) \(detail)\n"
        let url = policyDir.appendingPathComponent("decisions.log")
        try? FileManager.default.createDirectory(at: policyDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            if let d = line.data(using: .utf8) { h.write(d) }
            try? h.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
        // 和插件审计一样的上限策略：超 200KB 只留最后 500 行
        if let sz = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, sz > 200_000 {
            if let txt = try? String(contentsOf: url, encoding: .utf8) {
                let tail = txt.components(separatedBy: "\n").suffix(500).joined(separator: "\n")
                try? tail.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        print("[TA] 🛡 policy: \(action) \(detail)")
    }

    // MARK: 工具注册

    private func registerTool() {
        let def = ToolDefinition(
            name: "policy.confirm",
            summary: "向用户请求一次执行授权（break-glass）。当你认为某操作有风险、需要用户亲自点头、或者你本来打算拒绝时，调用它，不要直接拒绝——用户会在界面上看到确认卡片，点「允许」后你会拿到一张一次性票据，把它作为 _confirm_token 参数传给你要调用的工具即可。仅覆盖用户自己设备/App/数据上的操作；破解第三方 App 的付费或授权验证不在授权范围内，别拿它当万能钥匙。",
            parameters: [
                "action": "你要执行的动作，一句话，具体到你打算跑什么命令、改什么文件、装什么。用户就看这一行。",
                "detail": "为什么需要授权、会碰到什么、能不能回滚。写给用户看，2-3 句，别写技术黑话。",
                "risk": "low / medium / high，默认 medium。high 用于删除、覆盖、改系统配置、注入。",
                "tool": "可选。你接下来要调用的工具名。填了就只对这一个工具有效（更安全，建议填）。",
                "timeout": "可选。等用户多少秒，默认 180，最大 600。"
            ],
            returns: [
                "status": "approved / denied / timeout / unsupported",
                "ticket": "approved 时返回，传给目标工具的 _confirm_token 参数，单次有效",
                "message": "给你的下一步指示，照做即可"
            ],
            verified: false, category: "policy", uiSummary: "请求用户授权")
        ToolRegistry.shared.registerSystemTool(def) { params in
            let gate = ConfirmGate.shared
            guard gate.enabled else {
                throw MCPError.failed("用户关掉了「AI 请求授权」开关。不要反复尝试，直接把你打算做的事告诉用户，让他自己决定，或者去设置里打开这个开关。")
            }
            let action = ((params["action"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !action.isEmpty else { throw MCPError.invalidParams("缺 action：用一句话写明你要执行什么") }
            let detail = ((params["detail"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var risk = ((params["risk"] as? String) ?? "medium").lowercased()
            if !["low", "medium", "high"].contains(risk) { risk = "medium" }
            let tool = ((params["tool"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            var timeout = (params["timeout"] as? Double) ?? Double((params["timeout"] as? Int) ?? 180)
            if timeout <= 0 { timeout = 180 }
            timeout = min(max(timeout, 20), 600)
            let fallback = detail.isEmpty ? "没有补充说明。" : detail
            return gate.ask(action: action, detail: fallback, risk: risk,
                            tool: tool, timeout: timeout)
        }
    }

    /// 设置页用：最近若干条决策记录（只读展示，找不到文件就返回空）
    func recentDecisions(limit: Int = 30) -> [String] {
        let url = policyDir.appendingPathComponent("decisions.log")
        guard let txt = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = txt.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(lines.suffix(limit).reversed())
    }
}

// MARK: - 确认卡片

/// 覆盖整屏的授权卡。挂在 RootView 的最上层，任何时候 AI 请求授权都能看到。
struct ConfirmRequestOverlay: View {
    let request: PolicyRequest
    @State private var appear = false

    private var riskColor: Color {
        switch request.risk {
        case "high":   return Color(red: 0.85, green: 0.29, blue: 0.29)
        case "low":    return Color(red: 0.2, green: 0.62, blue: 0.4)
        default:       return Color(red: 0.9, green: 0.55, blue: 0.1)
        }
    }

    private var riskLabel: String {
        switch request.risk {
        case "high": return L10n.t("i18n_1617")
        case "low":  return L10n.t("i18n_1616")
        default:     return L10n.t("i18n_1615")
        }
    }

    var body: some View {
        GeometryReader { _ in
            ZStack {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .onTapGesture { }   // 吞掉点击，防止穿透到下面的聊天

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(riskColor)
                        Text(L10n.t("i18n_1609"))
                            .font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 8)
                        Text(riskLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(riskColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(riskColor.opacity(0.12))
                            .cornerRadius(6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(request.action)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text(request.detail)
                                .font(.system(size: 12.5))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 190)
                    .padding(.horizontal, 16)

                    Text(L10n.t("i18n_1613"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    HStack(spacing: 10) {
                        Button {
                            ConfirmGate.shared.answer(request.id, allow: false)
                        } label: {
                            Text(L10n.t("i18n_1612"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(10)
                        }

                        Button {
                            ConfirmGate.shared.answer(request.id, allow: true)
                        } label: {
                            Text(L10n.t("i18n_1611"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(riskColor)
                                .cornerRadius(10)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }
                .frame(maxWidth: 320)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(14)
                .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
                .padding(.horizontal, 28)
                .scaleEffect(appear ? 1 : 0.94)
                .opacity(appear ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.16)) { appear = true }
        }
    }
}
