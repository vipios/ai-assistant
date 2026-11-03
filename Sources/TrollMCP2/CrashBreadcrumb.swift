import Foundation
import UIKit

// MARK: - 崩溃面包屑
//
// 2026-11-03 新增。用户原话：
//   「探针已经加上了，那就让探针自动获取出问题了他就自动返回日志让你查看，
//     这样，就能精确锁定位置，而不是在这猜」
//
// 先说清一个物理限制，这决定了实现方式：
//   iPhone 上闪退那一刻进程是被系统直接杀掉的（EXC_BAD_ACCESS / SIGSEGV 等），
//   **不在主线程、不给你跑任何回调**。所以「崩了之后再上传」是不可能的，
//   任何号称能做到的方案都是假的。
//
// 唯一可行的做法是「**崩之前就把现场写好**」：
//   每到一个关键节点就**立刻 fsync 落盘**一行面包屑。等真崩了，磁盘上已经躺着
//   「崩之前最后在做哪一步」。下次启动时把这份未上报的日志自动传上去。
//   这样我拿到的是「崩在哪一行、崩前在做什么」，而不是靠猜。
//
// 三条铁律：
//   ① 写入必须便宜：一行 append + fsync，不做 JSON 序列化整表——否则它自己变成卡顿源
//   ② 写入必须不崩：全部在串行队列里做，失败就静默放弃，绝不因为记日志把 App 弄崩
//   ③ 崩了也不能丢：fsync 保证内核缓冲区落盘，不会因为进程猝死丢掉最后几行

final class CrashBreadcrumb {
    static let shared = CrashBreadcrumb()
    private init() {}

    /// 串行队列：所有写入排队，避免多线程同时 append 把文件写乱。
    private let q = DispatchQueue(label: "com.trollagent.breadcrumb", qos: .utility)

    /// 单文件上限，超了就把老的截掉一半——面包屑只需要「最近发生了什么」。
    private let maxBytes = 512 * 1024

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("breadcrumb.log")
    }

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - 写

    /// 记一个节点。哪怕一秒调上百次也没问题（纯 append）。
    ///
    /// 2026-11-03 重要约束（教训）：
    /// 这个方法**绝对不能在 SwiftUI 的 body / 渲染路径里调用**。
    /// 它内部有 fsync（强制刷盘），是真正的磁盘 IO。曾经把它接在
    /// ContentBlocks.split() 里（那是每个气泡每帧都会跑的地方），
    /// 直接把主线程堵死，用户实测「上下滑动完全没反应」。
    /// 只允许在低频节点调用：发消息、工具开始/结束、一轮结束、停止。
    func mark(_ event: String) {
        let line = "\(formatter.string(from: Date())) \(event)\n"
        q.async { [weak self] in
            guard let self = self else { return }
            guard let data = line.data(using: .utf8) else { return }
            let url = self.fileURL

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                // fsync：不用 synchronizeFile 的话，进程猝死时最后几行还在内核缓冲里，会丢。
                // 这正是「崩前最后一步」最要紧的几行。
                try? handle.synchronize()
            } else {
                try? data.write(to: url, options: .atomic)
            }

            // 只计数，不每次都去 stat 文件——stat 也是同步系统调用。
            // 每 200 次才真正检查一次体积。
            self.writeCount += 1
            if self.writeCount % 200 == 0 {
                self.trimIfNeeded(url)
            }
        }
    }

    /// 写计数（只在串行队列内部读写，无需加锁）
    private var writeCount = 0

    /// 把当前会话的上下文整体记一笔（发消息时调用，方便把日志和消息对上）。
    func markTurn(_ kind: String, text: String) {
        let brief = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        mark("\(kind): \(String(brief.prefix(120)))")
    }

    private func trimIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > maxBytes else { return }
        guard let all = try? String(contentsOf: url, encoding: .utf8) else { return }
        // 留最后一半：一行可能被截断，丢掉首行保证从完整行开始
        let lines = all.split(separator: "\n", omittingEmptySubsequences: false)
        let keep = lines.suffix(lines.count / 2)
        let text = keep.dropFirst().joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 读 / 清理

    func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func sizeBytes() -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size]) as? Int) ?? 0
    }

    func clear() {
        q.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    // MARK: - 启动时自检「上次是不是崩了」

    /// 正常退出会写这个标记。启动时发现标记不在、或时间戳对不上
    /// → 上次一定是异常终止（闪退/被系统杀）。
    ///
    /// 为什么不用系统崩溃日志：TrollStore 安装的 App 没有正常签名链路，
    /// 系统的 DiagnosticReports 常常收不到（用户上次那几条我也确实没在本机找到）。
    /// 自己判断更可靠。
    private let cleanExitKey = "diag.lastCleanExit"

    func markCleanExit() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cleanExitKey)
    }

    /// 返回 true 表示「上次是异常结束」。
    func detectPreviousCrash() -> Bool {
        let last = UserDefaults.standard.double(forKey: cleanExitKey)
        guard last > 0 else { return false }   // 首次安装，不算崩
        let gap = Date().timeIntervalSince1970 - last
        // 超过 12 小时没写正常退出标记：可能只是很久没用，不当成崩溃，避免误报
        return gap < 12 * 3600
    }

    // MARK: - 崩溃循环自救（2026-11-03，用户反馈「点桌面图标进不去，一直闪退」）
    //
    // 场景：某条聊天消息的内容会让渲染崩溃（比如模型的畸形 XML 让解析器越界）。
    // 每次启动都恢复那条消息 → 每次都崩在同一处 → App 彻底进不去，数据也导不出来。
    // 这是最坏的情况：用户被锁在门外，连删掉那条消息的机会都没有。
    //
    // 自救策略：
    //   · 每次启动给「启动计数」+1，正常跑到主界面后清零
    //   · 连续 2 次启动都没能跑到主界面 → 判定进了崩溃循环
    //   · 这时**不删任何数据**，只是让本次启动跳过「自动打开上次会话」，
    //     先进到会话列表。用户能自己点开、删掉问题消息，数据一条不少。
    //
    // 为什么是 2 次不是 3 次：用户已经明确说「一直闪退进不去」，
    // 多试一轮只是多锁他一分钟，没有额外价值。
    private let launchCountKey = "diag.launchAttemptCount"

    /// 启动最早期调用。返回 true 表示「前几次启动都失败了，本次进安全模式」。
    func registerLaunchAttempt() -> Bool {
        let n = UserDefaults.standard.integer(forKey: launchCountKey) + 1
        UserDefaults.standard.set(n, forKey: launchCountKey)
        // 第 2 次及以后仍没跑通（说明上一次也失败）→ 安全模式
        return n >= 2
    }

    /// 成功跑到主界面后调用，清零计数。
    func markLaunchSucceeded() {
        UserDefaults.standard.set(0, forKey: launchCountKey)
    }

    /// 安全模式标记：本次启动不自动打开上次会话。
    /// 只在内存里生效，不进 UserDefaults——下次若正常了就自动恢复。
    static var safeModeThisLaunch: Bool = false
}

// MARK: - 诊断日志自动回流
//
// 用户要的是「出问题自动回日志给你看，不要让我手动导」。
//
// 实现：本地攒 → 下次启动自动传 → 传成功就标记，不重复传。
// 传到哪里：优先中转站后台（用户自己的服务器，别人看不到），失败就留在本地等下次。
final class DiagnosticUploader {
    static let shared = DiagnosticUploader()
    private init() {}

    private let uploadedKey = "diag.lastUploadedAt"
    private let pendingPrefix = "diag.pending."

    /// 启动时调用一次：把上次的崩溃现场打包上传。
    /// 全程静默——失败不影响使用，也不弹窗打扰。
    func uploadPendingIfNeeded() {
        let crashed = CrashBreadcrumb.shared.detectPreviousCrash()
        CrashBreadcrumb.shared.mark("—— App 启动（上次\(crashed ? "异常终止" : "正常退出")）——")

        let log = CrashBreadcrumb.shared.read()
        let records = ChatDiagnostics.shared.recent(50)
        // 没崩溃、也没有异常结束的请求 → 不值得占流量，跳过
        let hasAbnormal = records.contains { $0.outcomeEnum.isAbnormal }
        guard crashed || hasAbnormal else {
            CrashBreadcrumb.shared.markCleanExit()
            return
        }
        // 同一份现场 6 小时内只传一次，避免每次冷启动都传
        let lastUp = UserDefaults.standard.double(forKey: uploadedKey)
        if lastUp > 0, Date().timeIntervalSince1970 - lastUp < 6 * 3600 {
            CrashBreadcrumb.shared.markCleanExit()
            return
        }

        let report = buildReport(crashed: crashed, breadcrumb: log, records: records)
        post(report) { ok in
            if ok {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.uploadedKey)
            }
            CrashBreadcrumb.shared.markCleanExit()
        }
    }

    private func buildReport(crashed: Bool,
                             breadcrumb: String,
                             records: [ChatTurnRecord]) -> [String: Any] {
        let info = Bundle.main.infoDictionary
        let abnormal = records.filter { $0.outcomeEnum.isAbnormal }
        var lines: [String] = []
        for r in abnormal.prefix(20) {
            let t = Self.timeText(r.at)
            lines.append("[\(t)] \(r.modelName) · \(r.outcomeEnum.label) · \(r.reason) \(r.detail)")
        }
        return [
            "kind": crashed ? "crash" : "abnormal",
            "version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "device": UIDevice.current.model,
            "ios": UIDevice.current.systemVersion,
            "at": ISO8601DateFormatter().string(from: Date()),
            "abnormalCount": abnormal.count,
            "abnormalSummary": lines.joined(separator: "\n"),
            // 面包屑只带最后 200 行：够定位，不传几 MB
            "breadcrumb": breadcrumb.split(separator: "\n").suffix(200).joined(separator: "\n"),
        ]
    }

    private static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    /// 发到中转站。走和模型请求同一条通道（用户自己的服务器）。
    /// 失败就算了——绝不重试到把用户流量吃光。
    private func post(_ payload: [String: Any], done: @escaping (Bool) -> Void) {
        guard let cfg = ModelStore.shared.defaultConfig else { done(false); return }
        var base = cfg.effectiveBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, var url = URL(string: base) else { done(false); return }
        url.appendPathComponent("admin/api/client-log")

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            done(false); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        // 用项目封装的 setHTTPMethod（iOS 15.6 上直接设 req.httpMethod 会闪退，
        // 原因见 UIComponents.swift 注释）
        setHTTPMethod("POST", on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = cfg.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 后端还没实现这个接口时会是 404——也算「尝试过」，别每次启动都打一遍
            done((200...299).contains(code) || code == 404)
        }.resume()
    }
}
