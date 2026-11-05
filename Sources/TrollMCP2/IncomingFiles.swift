import Foundation
import UIKit

/// 2026-11-05：从别的 App「共享/用其他应用打开」进来的文件暂存区。
///
/// **为什么需要这个东西**（用户原话）：
///   「我在 QQ 或者微信下载的文件，我要共享到这个 ipa 的聊天输入框上进行直接发送给 AI，
///     分享的时候为什么看不到咱们的 IPa 呢」
///
/// 两个独立原因，缺一不可：
///
///   ① **Info.plist 里没有 `CFBundleDocumentTypes`** —— 系统分享面板 / 「用其他应用打开」
///      靠 UTI 声明来筛选收件人。没声明就等于告诉系统"我什么文件都不收"，
///      所以那个列表里永远不会出现我们（微信、QQ 里都看不到）。
///      → 已在 Support/Info.plist 补上（Public.Data / Content 等，见那里的注释）。
///
///   ② **收到了也不会进输入框** —— 光声明类型只能让图标出现，点完系统把
///      `file://...` 交给 `application(_:open:options:)`，而那个方法原来第一行就是
///      `guard url.scheme == "trollagent"`，file URL 直接 return false：
///      表现为「图标能看见，点了没反应/文件丢了」。
///      → 这里做暂存 + 通知，由 ChatView 取走塞进 `pendingAttachments`。
///
/// 之所以要暂存而不是直接写 ChatView 的 @State：AppDelegate 拿不到 View 的 State。
/// 暂存 + Notification 是这套代码里已验证可行的模式（见 PendingImport）。
final class IncomingFiles: ObservableObject {
    static let shared = IncomingFiles()
    /// 有新文件进来（ChatView 监听它把文件塞进输入框）
    static let didReceiveNotification = Notification.Name("trollagent.incomingFiles.received")

    /// 待处理的文件 URL（已复制进沙盒，可安全读取）
    @Published var pending: [URL] = []

    private init() {}

    /// AppDelegate 收到 file URL 时调用。
    ///
    /// 关键：**必须先把文件复制进自己的沙盒**。
    /// 微信/QQ 交过来的 URL 可能在对方容器里、或是临时目录（Inbox），
    /// 出了这次回调就失效（尤其带 security-scoped 的），
    /// 等用户真正点发送时早就读不到了。所以这里立刻复制一份到
    /// `Documents/incoming/`，后续所有读取都走这份副本。
    ///
    /// 复制放后台队列：`application(_:open:)` 在主线程被调用，
    /// 用户从微信分享一个几百 MB 的 ipa 时，同步 copy 会把界面冻住
    /// （系统还可能因主线程超时直接杀掉我们）。这里只做"登记"，
    /// 复制完再回主线程发通知。
    func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var saved: [URL] = []
            for u in urls {
                if let copy = Self.importIntoSanbox(u) {
                    saved.append(copy)
                }
            }
            guard !saved.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 去重：同一次分享系统可能重复投递（openURL + launchOptions 两条路径）
                let existing = Set(self.pending.map { $0.path })
                let fresh = saved.filter { !existing.contains($0.path) }
                guard !fresh.isEmpty else { return }
                self.pending.append(contentsOf: fresh)
                NotificationCenter.default.post(name: Self.didReceiveNotification, object: nil)
            }
        }
    }

    /// 取走并清空（ChatView 消费完调用，避免同批文件被塞两次）
    ///
    /// ⚠️ 只在主线程调用（ChatView 的 onReceive / onAppear 里）。
    /// 这里**不加 @MainActor**：本工程是 Swift 5 语言模式、全项目没有并发标注
    /// （ConversationStore 等都没有），单加一个会让调用点变成需要 await 报错。
    /// 写入侧也已经在 DispatchQueue.main.async 里，所以实际是安全的。
    func take() -> [URL] {
        let out = pending
        pending = []
        return out
    }

    /// 把外部 URL 复制到沙盒 `Documents/incoming/`，返回副本 URL。
    ///
    /// 三种来源都要兜住：
    ///   · 沙盒外 + security-scoped（别的 App 容器、iCloud）→ 必须 startAccessing
    ///   · 已在临时 Inbox 里（`.../Documents/Inbox/xxx`）→ 直接可读
    ///   · 某些越狱环境路径 → 直接复制
    private static func importIntoSanbox(_ src: URL) -> URL? {
        var scoped = false
        if src.startAccessingSecurityScopedResource() { scoped = true }
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        // 目录不进附件区：本 App 的附件模型是"单个文件"，塞目录会在发送时读失败。
        // Info.plist 已经排除了 public.folder，这里再兜一层（某些系统版本仍会投递目录）。
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue {
            return nil
        }
        // 目标是 Documents/incoming（跟其他用户数据放一起，TrollStore 下可写）
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent("incoming", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var name = src.lastPathComponent
        if name.isEmpty { name = "file-\(Int(Date().timeIntervalSince1970))" }
        var dest = dir.appendingPathComponent(name)
        // 重名不覆盖：追时间戳（用户可能连着分享两个同名文件）
        if fm.fileExists(atPath: dest.path) {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            let ts = Int(Date().timeIntervalSince1970 * 1000)
            let newName = ext.isEmpty ? "\(base)-\(ts)" : "\(base)-\(ts).\(ext)"
            dest = dir.appendingPathComponent(newName)
        }
        do {
            try fm.copyItem(at: src, to: dest)
            return dest
        } catch {
            // copy 失败（跨容器权限、目录被占用）→ 退回整份读出来再写
            if let data = try? Data(contentsOf: src), !data.isEmpty {
                if (try? data.write(to: dest)) != nil { return dest }
            }
            return nil
        }
    }

    /// 启动时清理过旧的 incoming 文件（避免越用越多）。
    /// 保留 7 天——用户分享进来又没发送的文件，一周后删掉足够安全。
    func cleanupOld() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let dir = docs.appendingPathComponent("incoming", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for u in items {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let d = d, d < cutoff { try? FileManager.default.removeItem(at: u) }
        }
    }
}
