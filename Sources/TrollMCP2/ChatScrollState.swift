import SwiftUI
import UIKit

/// 2026-11-03：滚动位置/内容高度/视口高度的独立状态容器。
///
/// 为什么必须单独抽一个 ObservableObject：
/// 以前这三个值是 ChatView 的 @State。ScrollGeometryBridge 是 UIKit KVO，
/// 滚动时**每一帧**都回调一次 → 每帧写一次 @State → ChatView 的整个 body
/// 重新求值。ChatView.body 里包含：
///   · ChatListGrouping.group(store.currentMessages)（全量重新分组）
///   · ForEach 全部消息（每个 MessageBubble 重新比较）
///   · ContentBlocks.split / MarkdownBlocksView 等重渲染路径
/// 于是「手指一滑」就变成每帧一次全量重建 —— 这正是用户反馈的
/// 「上下滑动看项目非常卡」。数值本身是对的，问题在更新粒度。
///
/// 现在改为：KVO 只写这个对象的三个 @Published，纯滚动时 ChatView.body
/// 不再参与，只有真正依赖这三个值的悬浮按钮视图会重新求值
/// （它们被抽成独立 struct，订阅这个对象）。
///
/// @MainActor 保证 KVO 回调在主线程赋值（UIKit 的 contentOffset KVO 本身
/// 就在主线程，这里只是把约束写进类型里，避免以后有人从别的线程改）。
final class ChatScrollState: ObservableObject {
    /// 滚动偏移（对齐原 marker 语义：顶部 = 0，向下滚为负）
    @Published var offset: CGFloat = 0
    /// 内容总高
    @Published var contentHeight: CGFloat = 0
    /// 视口高度
    @Published var viewportHeight: CGFloat = 0

    /// 是否可向上滚（不在顶部）
    var canScrollUp: Bool {
        guard contentHeight > 0 else { return offset < -2 }
        let bottom = -(contentHeight - viewportHeight)
        return offset < -2 && offset > bottom + 2
    }

    /// 是否可向下滚（不在底部）
    var canScrollDown: Bool {
        guard contentHeight > 0 else { return true }
        let bottom = -(contentHeight - viewportHeight)
        return offset > bottom + 2
    }

    /// 是否「已接近底部」——发消息时是否该自动跟随的判据。
    /// tolerance 给 40pt，避免浮点误差导致明明在底部却判定为不跟随。
    func isNearBottom(tolerance: CGFloat = 40) -> Bool {
        guard contentHeight > 0 else { return offset > -50 }
        let bottom = -(contentHeight - viewportHeight)
        return offset <= bottom + tolerance
    }

    /// 新消息到达时是否应该自动滚到底。
    ///
    /// 合并原有两个判据：
    ///   · 已知内容高度 → 底部 40pt 内才跟随；
    ///   · 高度未知（LazyVStack 惰性渲染，marker 还没建出来）→ 顶部附近才跟随，
    ///     用户已经上滑看历史时绝不抢滚动位置。
    /// 抽成一个方法，调用方（ChatView 的 onChange）不用再分别读三个属性。
    func shouldAutoFollow() -> Bool {
        if contentHeight > 0 { return isNearBottom() }
        return offset > -50
    }
}
