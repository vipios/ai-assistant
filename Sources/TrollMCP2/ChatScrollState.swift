import SwiftUI
import UIKit
// P78：CFAbsoluteTime / CFAbsoluteTimeGetCurrent 来自 CoreFoundation
import CoreFoundation
// activity.objectWillChange 的 sink 需要 Combine
import Combine

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

    /// 2026-11-03：滚动活动状态**必须独立成另一个对象**。
    ///
    /// 原因：ChatView.body 要读 isScrollingFast 才能决定消息正文用轻量 Text
    /// 还是 UITextView。如果它跟 offset 放在同一个对象里，body 一订阅就
    /// 连 offset 的每帧更新一起收 —— 直接把本类开头注释修好的性能问题退回去。
    /// 拆开后 offset 那条高频链谁都不读，isScrollingFast 每轮滚动只翻转两次。
    let activity = ChatScrollActivity()

    /// 2026-11-03 **关键修复**：把 activity 的变化转发到本对象的 objectWillChange。
    ///
    /// 之前这里没有这段转发，后果很严重：
    /// ChatView 里写的是 `@StateObject private var scroll = ChatScrollState()`，
    /// 它订阅的是**外层** scroll 的 objectWillChange。而 isScrollingFast 变更
    /// 只发生在内层 activity 上 → 外层收不到通知 → ChatView.body 不重新求值
    /// → `fastScrolling` 永远是初始值 false。
    /// 也就是说「滚动时降级为轻量 Text」这个优化**从来没生效过**，
    /// 快速上滑时几十个 UITextView 照样疯进疯出，这就是用户反复反馈的
    /// 「上下滑动完全没反应 / 卡死」的真实原因。
    ///
    /// 注意不能简单地把 activity 改成 @Published：那会连带每帧 offset 一起刷新。
    /// 这里只转发 activity 的变更（每轮滚动仅两次），不影响 offset 的高频链。
    private var activityObserver: AnyCancellable?

    init() {
        // receive(on: RunLoop.main)：objectWillChange 的 sink 必须在主线程调用
        // SwiftUI 的刷新链。noteScrolled 是从 KVO 回调进来的（本来就在主线程），
        // 但显式声明调度更安全——绝不能在后台线程触发 @Published 的 willChange，
        // 否则是 "Publishing changes from background threads is not allowed" 崩溃。
        activityObserver = activity.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    /// 由 ScrollGeometryBridge 的 onOffset 调用（每帧都会调，必须极轻）。
    func noteScrolled() {
        activity.noteScrolled()
    }

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
    func shouldAutoFollow() -> Bool {
        if contentHeight > 0 { return isNearBottom() }
        return offset > -50
    }
}

/// 2026-11-03：滚动活动状态（与滚动数值分离，避免高频刷新）。
///
/// 解决什么问题：消息正文用 SelectableText(UITextView) 才有长按划词和
/// 「复制全文」，但 UITextView 是重量级控件——被 LazyVStack 回收后重建，
/// 每次都要走文本布局、intrinsicContentSize 计算、文本选择系统挂载。
/// 一个几百条的会话里同时存在几十个，用户快速上滑时这些 cell 疯进疯出，
/// 主线程被重建任务占满，表现就是反馈里的「快速上滑翻看聊天记录时界面卡死」。
///
/// 解法：滚动期间把正文降级为轻量 Text（纯 SwiftUI，无 UIKit 控件开销），
/// 停手 0.3 秒后再换回 UITextView。用户滑动时不会去长按选字，
/// 所以这个降级对功能零影响，但能削掉滚动期绝大部分重建成本。
final class ChatScrollActivity: ObservableObject {
    @Published var isScrollingFast: Bool = false

    /// P78（2026-11-04）：停止判定改用时间戳 —— 见下方 noteScrolled 的详细说明。
    /// restoreWork 是「唯一的待执行任务槽」，非 nil 表示已排程、不重复排。
    private var restoreWork: DispatchWorkItem?

    /// 每帧调用。只在状态真的需要翻转时才写 @Published，否则仅更新令牌，
    /// 避免每帧一次 objectWillChange 又把 body 重算拉回高频频率。
    ///
    /// P78（2026-11-04）修卡顿：原来每次调用都 `restoreWork?.cancel()` + 新建
    /// DispatchWorkItem + asyncAfter，在 120Hz 屏上滚动 1 秒就是 120 次对象分配
    /// 和 120 次主队列排程 —— 分配和 cancel 本身把主线程占住，用户感知就是
    /// 「往上滑聊天记录很卡」。数值逻辑没错，坏在每帧的固定开销。
    ///
    /// 现在改成：只在「首次进入滚动」时排一次延时任务（每轮滚动 1 次，不是每帧 1 次）；
    /// 后续每帧只更新 timestamp。延时任务醒来后比对「距最后一次滚动过了多久」，
    /// 不足 0.3 秒就把剩余时间再排一次（尾随触发），够了才恢复。
    /// 这样无论滚多久，同一时刻最多只有 1 个待执行任务，且不产生每帧分配。
    private var lastScrollTime: CFAbsoluteTime = 0
    /// 停止判定阈值：0.3 秒。比手指离屏略长，避开回弹动画期间的反复切换；
    /// 又不能太长——否则停手后想长按选字要等半秒才有反应。
    private let stopInterval: CFAbsoluteTime = 0.3

    func noteScrolled() {
        lastScrollTime = CFAbsoluteTimeGetCurrent()

        // 只有从「静止」进入「滚动」这一次写 @Published（每轮滚动仅 1 次翻转）
        if !isScrollingFast {
            isScrollingFast = true
        }

        // 已有待执行任务就不重复排程 —— 这是省掉每帧分配的关键。
        // 该任务自己会检查 lastScrollTime 决定是收尾还是续排。
        guard restoreWork == nil else { return }

        scheduleRestoreCheck()
    }

    private func scheduleRestoreCheck() {
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let idle = CFAbsoluteTimeGetCurrent() - self.lastScrollTime
            if idle < self.stopInterval {
                // 还在滚（或刚停不足 0.3s）：把剩余时间再排一次，任务槽保持占用
                let remain = self.stopInterval - idle
                let next = DispatchWorkItem { [weak self] in self?.runRestoreCheck() }
                self.restoreWork = next
                DispatchQueue.main.asyncAfter(deadline: .now() + remain, execute: next)
                return
            }
            self.runRestoreCheck()
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stopInterval, execute: work)
    }

    /// 真正收尾：解除任务槽 + 恢复重量级控件。
    private func runRestoreCheck() {
        restoreWork = nil
        if isScrollingFast {
            isScrollingFast = false
        }
    }
}
