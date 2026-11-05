import SwiftUI
import UIKit

/// 统一分享器 —— **2026-11-05 恢复系统共享面板**。
///
/// 历史上这里写着「侧载环境任何系统分享面板都不可用」，
/// 但那个结论是建立在错误归因上的（详见 ShareCenter.swift 文件头的更正）：
/// 真实根因是包内缺 `Assets.car` 而 Info.plist 又声明了 `CFBundleIconName`，
/// 系统生成扩展图标时 MobileIcons/CoreImage SIGSEGV。
/// `Support/Info.plist` 删掉 CFBundleIconName 后，系统面板即可正常使用。
///
/// 现在的行为：
///   · 文件 → 系统 UIActivityViewController（微信/QQ/AirDrop/存储到文件全在里面）
///   · 文字 → 同上
/// 用户原话：「直接共享文件，这个按钮，然后我点击共享文件这个按钮里面
///           微信 qq 所有的都在里面」
enum SharePresenter {

    /// 命令式分享入口（兼容 UpdateManager / MoreViews Alert 等非 View 上下文调用点）。
    /// 文件 → 自建文件分享菜单；纯文字 → 自建文字分享菜单；均不触达系统分享面板。
    static func present(
        _ items: [Any],
        excluded: [UIActivity.ActivityType] = [],
        completion: ((Bool, Error?) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            var fileURLs: [URL] = []
            var texts: [String] = []

            for item in items {
                if let url = item as? URL, url.isFileURL {
                    if FileManager.default.fileExists(atPath: url.path) {
                        fileURLs.append(url)
                    } else {
                        AuditLog.shared.log("share.invalid_url", detail: url.path)
                    }
                } else if let s = item as? String {
                    texts.append(s)
                }
            }

            if let file = fileURLs.first {
                AuditLog.shared.log("share.menu_file", detail: file.lastPathComponent)
                ShareCenter.shared.presentShareMenuFile(file)
                completion?(true, nil)
                return
            }

            if !texts.isEmpty {
                AuditLog.shared.log("share.menu_text", detail: "texts=\(texts.count)")
                ShareCenter.shared.presentShareMenuText(texts.joined(separator: "\n"))
                completion?(true, nil)
                return
            }

            AuditLog.shared.log("share.all_invalid", detail: "items=\(items.count)")
            completion?(false, NSError(domain: "SharePresenter", code: -2,
                                       userInfo: [NSLocalizedDescriptionKey: "Invalid share content"]))
        }
    }
}

// MARK: - SwiftUI 分享入口
//
// 2026-11-05：全部入口统一走 ShareCenter 的系统共享面板
// （Info.plist 删掉 CFBundleIconName 之后，面板不再崩，见 ShareCenter 文件头）。
extension SharePresenter {

    /// 上下文菜单里的"分享"项（文件 URL）→ 自建分享菜单
    static func menuShare(url: URL,
                          label: String = "Share",
                          systemImage: String = "square.and.arrow.up") -> some View {
        Button {
            ShareCenter.shared.presentShareMenuFile(url)
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    /// 上下文菜单里的"分享"项（文本）→ 自建分享菜单
    static func menuShare(text: String,
                          label: String = "Share",
                          systemImage: String = "square.and.arrow.up") -> some View {
        Button {
            ShareCenter.shared.presentShareMenuText(text)
        } label: {
            Label(label, systemImage: systemImage)
        }
    }

    /// 工具栏里的"分享"图标按钮（文本）→ 自建分享菜单
    static func toolbarShare(text: String) -> some View {
        Button {
            ShareCenter.shared.presentShareMenuText(text)
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
        }
    }

    /// 工具栏里的"分享"图标按钮（文件 URL）→ 自建分享菜单
    static func toolbarShare(url: URL) -> some View {
        Button {
            ShareCenter.shared.presentShareMenuFile(url)
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 18, weight: .semibold))
        }
    }
}
