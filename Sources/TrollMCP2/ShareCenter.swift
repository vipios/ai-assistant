import SwiftUI
import UIKit

/// v4.3.46：分享中转站。
///
/// 2026-11-05 **重大更正**：这个文件过去一直宣称「侧载环境任何系统分享面板都不可用」，
/// 于是所有分享入口都被改成自建 UIAlertController（只有"存储到文件/用 TrollStore 安装"）。
/// 用户实测反馈：那两个按钮远不如系统面板好用 —— 他要的是面板里直接有微信、QQ。
///
/// 现在查明，当年那次崩溃的根因是**图标资源缺失**，不是"分享面板本身不可用"：
///   · 崩溃栈：ShareSheet → SharingUI → UIKitCore
///             → MobileIcons(LICreateIconForImages) → CoreImage → SIGSEGV
///   · 真正的触发条件：包里**没有 Assets.car**，图标只有散装 PNG，
///     而 Info.plist 声明了 `CFBundleIconName = AppIcon` ——
///     系统按 name 去 Assets 里查图标查不到，生成扩展图标时崩。
///   · 当年注释归因到 `CFBundleDocumentTypes = All Files`，但 `git log -S` 查证：
///     这条声明**从未被提交过**，最早的上游快照 8c9eea0 里就是 0 次 ——
///     那个"修复"什么都没改，隐患一直留着。
///
/// 修复（两处，缺一不可）：
///   1. `Support/Info.plist` 删掉 `CFBundleIconName`，只留 `CFBundleIconFiles`；
///   2. 本文件恢复真正的 `UIActivityViewController`。
///
/// 保底：**已不设第二套菜单**（2026-11-05 用户选择"只留系统面板"）。
/// 系统面板能不能用，全靠 Info.plist 删掉 CFBundleIconName 这一处修复 ——
/// 两套菜单并存会让"到底点了哪个"难以解释，也会让崩溃问题更难定位。
final class ShareCenter: ObservableObject {
    static let shared = ShareCenter()

    /// 提示文案（nil = 无提示）
    @Published var clipboardNotice: String?

    private init() {}

    // MARK: - 文件分享：系统共享面板（2026-11-05 恢复）

    /// 文件分享菜单 —— 2026-11-05 **用户明确要求改回系统共享面板**。
    ///
    /// 用户原话：「直接共享文件，这个按钮，然后我点击共享文件这个按钮里面
    ///           微信 qq 所有的都在里面，你懂吗」
    ///
    /// 之前这里是自建的 UIAlertController（只有"存储到文件"和"用 TrollStore 安装"），
    /// 原因是历史上有两次真机 SIGSEGV，栈是：
    ///   ShareSheet → SharingUI → UIKitCore → MobileIcons(LICreateIconForImages)
    ///   → CoreImage → Segmentation fault: 11
    ///
    /// **2026-11-05 查明真正的根因**（不是当年注释里写的 CFBundleDocumentTypes ——
    /// 那条声明 git 历史里从未提交过，上游快照就是 0 次，所以那个"修复"是空转）：
    ///   包里**没有 Assets.car**，图标是散装 PNG，而 Info.plist 声明了
    ///   `CFBundleIconName = AppIcon` —— 系统分享面板枚举扩展、让 MobileIcons
    ///   按 name 去 Assets 里查图标时查不到，走异常路径崩溃。
    ///   已在 Support/Info.plist 删掉 CFBundleIconName，只留 CFBundleIconFiles。
    ///
    /// 所以这里恢复成真正的 UIActivityViewController：微信/QQ/AirDrop/存储到文件
    /// 全部由系统列出，用户要的就是这个。
    ///
    /// 保底：系统面板万一仍然崩，回退办法是 `git revert` 本文件的分享函数，
    /// 改回 UIAlertController 版本（历史版本里有）。这里不保留第二套 UI，
    /// 因为两套菜单并存会让"点了哪个"难以解释。
    func presentShareMenuFile(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.showNotice(L10n.t("i18n_867"))
                return
            }
            guard let top = Self.topViewController() else { return }
            // 放行所有活动：微信/QQ/AirDrop/存储到文件/拷贝 都会出现在面板里。
            // 不传 excludedActivityTypes —— 用户要的就是"所有的都在里面"。
            let activity = UIActivityViewController(activityItems: [url],
                                                   applicationActivities: nil)
            // iPad / 大屏兼容：popover 需要锚点，否则 present 会崩
            if let pop = activity.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX,
                                        y: top.view.bounds.maxY,
                                        width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            top.present(activity, animated: true)
            AuditLog.shared.log("share.system_sheet_file", detail: url.lastPathComponent)
        }
    }

    /// 保底菜单已删除（2026-11-05 用户选择：只留系统面板）。
    /// 系统面板崩不崩，靠 Info.plist 那个 CFBundleIconName 的修复来保证。

    /// 文字分享 —— 2026-11-05 同样改成系统共享面板（与文件分享同一原因，见上）。
    /// 文字分享不会触发 MobileIcons（面板里没有扩展图标要生成），历史上没崩过，
    /// 但保持一致：用户要的是"微信 QQ 都在里面"。
    func presentShareMenuText(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self.showNotice(L10n.t("i18n_1058"))
                return
            }
            guard let top = Self.topViewController() else { return }
            let activity = UIActivityViewController(activityItems: [trimmed],
                                                   applicationActivities: nil)
            if let pop = activity.popoverPresentationController {
                pop.sourceView = top.view
                pop.sourceRect = CGRect(x: top.view.bounds.midX,
                                        y: top.view.bounds.maxY,
                                        width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            top.present(activity, animated: true)
            AuditLog.shared.log("share.system_sheet_text", detail: "len=\(trimmed.count)")
        }
    }

    /// 保底文字菜单已删除（2026-11-05 用户选择：只留系统面板）。

    // MARK: - 存储到文件（UIDocumentPicker，安全路径）

    /// 存储到文件：UIDocumentPickerViewController(forExporting:) 弹出 Files 保存界面。
    /// 不经过 ShareSheet，不枚举分享扩展，侧载环境安全。
    func saveToFiles(_ url: URL) {
        // 延迟 0.45s：contextMenu 按钮点击后 dismiss 动画约 0.5s，立即 present 会被吞
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                self.showNotice(L10n.t("i18n_873"))
                return
            }
            guard let top = Self.topViewController() else { return }
            let picker = UIDocumentPickerViewController(forExporting: [url])
            picker.modalPresentationStyle = .fullScreen
            top.present(picker, animated: true)
            AuditLog.shared.log("share.save_to_files", detail: url.lastPathComponent)
        }
    }

    // MARK: - 用 TrollStore 安装

    /// 用 TrollStore 安装 —— 2026-11-05 **修「点了完全没反应」**。
    ///
    /// 原来的实现是 `UIApplication.shared.open(file://...)`。这条路**必然失败**：
    /// `open()` 对 file URL 走的是 Launch Services 的 **UTI 类型匹配**
    /// （谁能打开这个类型），而本包 Info.plist 里 `CFBundleDocumentTypes` 是空的
    /// （`git log -S` 查过，从未声明），于是没有 App 认领 → `ok=false` → 什么都不发生。
    /// 失败提示又走 `shareCenter.clipboardNotice`，那个绑定只在 RootView 上，
    /// 用户在更新页点时根本弹不出来 —— 表现就是"点了没反应"。
    ///
    /// TrollStore 确实支持本地文件安装，但那是**它自己去读**文件
    /// （TSSceneDelegate 的 isFileURL 分支），不是由我们 open() 出来的。
    ///
    /// 现在：直接弹**系统共享面板**。面板里 TrollStore 会作为能接收 .tipa 的 App
    /// 出现（UTI 匹配，走分享扩展机制，和失败的 open() 完全不是同一套），
    /// 点它即可安装。同时也满足用户「里面微信 QQ 所有的都在」的要求。
    ///
    /// ⚠️ 曾经的 apple-magnifier://install?url= 也不要再用：它走
    /// URLSessionDownloadTask，只认 http/https，给 file:// 必报 unsupported URL。
    func openInTrollStore(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "tipa" || ext == "ipa" else {
            self.showNotice(L10n.t("i18n_874"))
            return
        }
        presentShareMenuFile(url)
        AuditLog.shared.log("share.trollstore_via_sheet", detail: url.lastPathComponent)
    }

    // 2026-11-05：`openIn(_:)`（UIDocumentInteractionController.presentOpenInMenu）
    // 连同 docControllerKey / DocInteractionDelegate 一并删除。
    // 它本来就是"打开方式列表"，同样要渲染 App 图标（与旧分享面板同一崩溃点），
    // 且当前**没有任何调用方**（grep 确认）。留着只是给以后埋雷。

    // MARK: - 文字 → 临时 txt

    /// 把文字写入临时 txt 文件，返回 URL；失败返回 nil。
    static func writeTextToTemp(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefix = String(trimmed.prefix(12))
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let name = "Share_\(prefix.isEmpty ? "text" : prefix)_\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try trimmed.data(using: .utf8)?.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - 拷贝兜底

    /// 纯文字/链接复制兜底
    func fallbackClipboard(_ text: String) {
        UIPasteboard.general.string = text
        showNotice(L10n.t("i18n_879"))
        AuditLog.shared.log("share.fallback_clipboard", detail: "texts=1")
    }

    private func showNotice(_ text: String) {
        DispatchQueue.main.async {
            self.clipboardNotice = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                self.clipboardNotice = nil
            }
        }
    }

    /// iPad 兼容：actionSheet 需要 popover 锚点
    static func anchor(_ alert: UIAlertController) {
        guard let vc = topViewController(), let view = vc.view else { return }
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1)
        alert.popoverPresentationController?.permittedArrowDirections = []
    }

    /// 找到当前最顶层 UIViewController（绕开 SwiftUI 层级，直接往 key window 上 present）
    static func topViewController() -> UIViewController? {
        var vc: UIViewController?
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        } else if let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) {
            vc = window.rootViewController
        }
        while let presented = vc?.presentedViewController {
            vc = presented
        }
        return vc
    }
}
