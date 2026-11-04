import SwiftUI
import UIKit
// P78：CFAbsoluteTime / CFAbsoluteTimeGetCurrent 来自 CoreFoundation
import CoreFoundation
// activity.objectWillChange 的 sink 需要 Combine
import Combine

/// 滚动位置/内容高度/视口高度的状态容器。
///
/// 2026-11-05 **重写（fix-jitter-2，关键）**——上一版仍然让聊天页每帧全量重建。
///
/// 上一版的问题：把 offset / contentHeight / viewportHeight 三个都写成 `@Published`，
/// 然后 ChatView 里声明 `@StateObject private var scroll = ChatScrollState()`。
/// 注释里写着「主 body 完全不读这三个值，所以每帧不会重算」——**这个推断是错的**：
/// `@StateObject` 的语义就是「这个 View 订阅该对象的 objectWillChange」，
/// body 读不读它的属性完全不影响订阅关系。于是：
///
///   KVO 每帧回调 → offset 写 @Published → objectWillChange → ChatView.body 重算
///   → ChatListGrouping.group(全部消息) + 全部 MessageBubble 重新求值
///   → 每条消息都重跑 MarkdownBlocks.parse / CitationExtractor.extract / 正则着色
///
/// 手指轻轻一滑就是每帧一次全量重建，几百条消息的会话里主线程直接被占满。
/// 这就是用户反复反馈的「上下滑动聊天记录直接卡死」——之前几版都在优化被重建的**内容**
/// （降级 Text、加缓存），但重建本身从没被止住，所以治不好。
///
/// 现在的结构：
///   · 三个数值（offset / contentHeight / viewportHeight）改成**普通属性**，
///     高频写入完全不产生任何 SwiftUI 通知；
///   · 只有 `canScrollUp` / `canScrollDown` 这两个「按钮显示位」是 @Published，
///     且只在**真的翻转**时才赋值 —— 一轮滚动最多 2 次通知（不是每帧）；
///   · `isScrollingFast` 保持独立对象 + 转发，道理同上（每轮滚动 2 次翻转）。
///
/// 结果：滚动期间 ChatView.body 基本不重算，只有那个 40pt 圆钮会动。
///
/// ---
/// 2026-11-05 再修（fix-freeze-2）：**「用户在滚」的判定从本类内部挪到桥接层**。
/// 见 `setOffset` 上方的长篇说明 —— 本类不再具备把程序性滚动误判为用户滚动的能力。
@MainActor
final class ChatScrollState: ObservableObject {
    /// 滚动偏移（对齐原 marker 语义：顶部 = 0，向下滚为负）
    /// ⚠️ 普通属性，不是 @Published —— 这是本类最重要的约束，别改回去。
    private(set) var offset: CGFloat = 0
    /// 内容总高。同上，普通属性。
    private(set) var contentHeight: CGFloat = 0
    /// 视口高度。同上，普通属性。
    private(set) var viewportHeight: CGFloat = 0

    /// 悬浮按钮显示位——**只有这两个**是 @Published，但**不放在本类里**。
    ///
    /// 2026-11-05 fix-freeze-3：它们原本是本类的 `@Published`，而 ChatView 用
    /// `@StateObject` 持有本类 → 这两个布尔翻转就会让 **ChatView.body 全量重算**。
    /// 流式输出时内容一直在变高：内容变高 → canScrollDown 翻 true → 贴底 →
    /// 又翻 false → 下一条 delta 再翻 true……每条增量触发 2 次全量 body 重算
    /// （全量 = ChatListGrouping + 每条消息的 ContentBlocks.split / MarkdownBlocks.parse /
    /// 正则着色），几十条消息的会话里主线程直接被吃满 —— 这就是「发完消息点哪都没反应」。
    ///
    /// 现在这两个值挪进独立对象 `flags`，只有 FloatingScrollButtons 订阅它，
    /// ChatView 完全不感知按钮显隐的变化。
    let flags = ChatScrollFlags()

    /// 滚动活动状态**必须独立成另一个对象**。
    ///
    /// 原因：ChatView.body 要读 isScrollingFast 才能决定消息正文用轻量 Text
    /// 还是 UITextView。如果它跟 offset 放在同一个对象里，body 一订阅就
    /// 连 offset 的每帧更新一起收。拆开后 offset 那条高频链谁都不读，
    /// isScrollingFast 每轮滚动只翻转两次。
    let activity = ChatScrollActivity()

    private var activityObserver: AnyCancellable?

    init() {
        // receive(on: RunLoop.main)：objectWillChange 的 sink 必须在主线程调用
        // SwiftUI 的刷新链。noteScrolled 是从 KVO 回调进来的（本来就在主线程），
        // 但显式声明调度更安全——绝不能在后台线程触发 @Published 的 willChange，
        // 否则是 "Publishing changes from background threads is not allowed" 崩溃。
        //
        // 注意：**只转发 activity，不转发 flags**。字幕按钮显隐是纯本地的视觉状态，
        // 让它牵动 ChatView 重算是纯亏（见上面 flags 的说明）。
        activityObserver = activity.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - 写入入口（由 ScrollGeometryBridge 的 KVO 调用，每帧一次，必须极轻）

    /// 每帧写入滚动偏移。
    ///
    /// ⚠️ **不要在这里调 `activity.noteScrolled()`**（2026-11-05 fix-freeze-2）。
    ///
    /// 上一版就是在这一行调了 noteScrolled，导致「程序性贴底」被当成「用户正在滚动」：
    ///   pinToBottom → setContentOffset → 本方法 → noteScrolled → isScrollingFast=true
    ///   → 全部气泡从 UITextView 降级成 Text → 行高全变 → contentSize 变
    ///   → 又触发 pinToBottom → ……（0.3 秒后降级恢复，高度再变一次，继续循环）
    ///
    /// 主线程被无限次「几十条消息重新布局 + UITextView 重建」占满，表现就是
    /// 用户反馈的「发完消息就卡死、屏幕点什么都没反应、杀进程重进才看到回复」。
    ///
    /// 现在「用户在滚」只由 ScrollGeometryBridge 依据 UIScrollView.isTracking /
    /// isDragging / isDecelerating 判定后调 `noteUserScrolled()` —— 程序性滚动永不触发降级。
    func setOffset(_ v: CGFloat) {
        offset = v
        refreshButtonFlags()
    }

    /// **只有用户真的用手指拖拽或惯性滚动时**才调用（见 ScrollGeometryBridge.onUserScroll）。
    /// 语义：正文临时降级为轻量 Text，停手 0.3 秒后恢复。
    func noteUserScrolled() {
        activity.noteScrolled()
    }

    func setContentHeight(_ v: CGFloat) {
        // 高度变化不牵动按钮显隐判定以外的东西；但它是低频的（只在内容增长时变），
        // 顺手刷新一次按钮状态，避免内容从短变长后 ⬇️ 按钮该出现却没出现。
        contentHeight = v
        refreshButtonFlags()
    }

    func setViewportHeight(_ v: CGFloat) {
        viewportHeight = v
        refreshButtonFlags()
    }

    /// 只在值**真的翻转**时才赋给 flags —— 这是「每帧不发通知」的保证。
    private func refreshButtonFlags() {
        flags.update(up: computeCanScrollUp(), down: computeCanScrollDown())
    }

    // MARK: - 判定

    /// 是否可向上滚（不在顶部）
    private func computeCanScrollUp() -> Bool {
        guard contentHeight > 0 else { return offset < -2 }
        let bottom = -(contentHeight - viewportHeight)
        return offset < -2 && offset > bottom + 2
    }

    /// 是否可向下滚（不在底部）
    private func computeCanScrollDown() -> Bool {
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
    /// **2026-11-05 重要收敛**：现在真正的「跟随底部」由 ScrollGeometryBridge 在
    /// UIKit 层做（无动画吸附），这里只负责判断「该不该让桥接层去跟」。
    /// 所以本方法只回答「用户此刻在不在底部」，返回 false 时调用方**不要再 scrollTo**
    /// ——以前那种「不在底部也硬滚一次」正是把上滑看历史的用户拉回去的元凶。
    ///
    /// 另外把容差从 40pt 收到 24pt：40pt 太宽，用户明明已经上滑了一点
    /// 仍会被判成「在底部」然后被拽下去。
    func shouldAutoFollow() -> Bool {
        if contentHeight > 0 { return isNearBottom(tolerance: 24) }
        return offset > -50
    }

    /// 2026-11-05：请求桥接层「重新吸附到底部」。
    ///
    /// 用在两个地方：用户自己发消息（必须看到自己的话）、切换会话（必须停在最新处）。
    /// 这两个都是低频且语义明确的动作，不是流式高频追加——后者靠桥接层自动吸附，
    /// 绝不走这里。
    ///
    /// 实现：桥接层通过 NotificationCenter 收到信号后把 stickToBottom 置 true 并钉一次底。
    /// 用通知而不是给 BridgeView 加绑定，是为了避免把滚动状态再串回 SwiftUI 的更新环。
    func requestStickToBottom() {
        // 直接写字面量而不是引用 ScrollGeometryBridge.stickToBottomNote：
        // 后者是 UI 结构体的静态成员，在 @MainActor 类里跨类型访问在严格并发下会被判隔离冲突。
        NotificationCenter.default.post(name: Notification.Name("TrollAgent.scroll.stickToBottom"),
                                        object: nil)
    }

    /// 2026-11-05：请求桥接层「解除吸附」——用户主动要离开底部时用（点 ↑ 回顶部）。
    /// 不解除的话，桥接层会在下一次 contentSize 变化时把视图又拽回底部，
    /// 表现为「点了回顶部，一下又弹回去」。
    func releaseStick() {
        NotificationCenter.default.post(name: Notification.Name("TrollAgent.scroll.releaseStick"),
                                        object: nil)
    }
}

/// 悬浮滚动按钮的显隐状态（2026-11-05 fix-freeze-3 从 ChatScrollState 里拆出来）。
///
/// 为什么必须拆：ChatView 用 `@StateObject private var scroll = ChatScrollState()` 持有外层对象，
/// 而 `@StateObject` 的语义就是「本视图订阅该对象的 objectWillChange」——
/// 只要 canScrollUp/Down 是外层对象的 `@Published`，它们每次翻转都会让
/// **ChatView.body 全量重算**（ChatListGrouping + 所有 MessageBubble + markdown 解析）。
///
/// 而这两个布尔在流式输出时翻转极其频繁：
///   内容变高 → 不在底部 → canScrollDown=true → 桥接层贴底 → 又在底部 → false → 下一条 delta 再 true
/// 一条几十字的 AI 回复就能触发几十次全量重算，主线程被占满 → 点哪都没反应。
///
/// 拆成独立对象后，只有 FloatingScrollButtons（一个 40pt 圆钮）订阅它，
/// 它怎么翻都牵不动消息列表。
///
/// 加 @MainActor：只被 ChatScrollState（@MainActor）和 SwiftUI body 写/读，
/// 而 ChatScrollState 的写入入口来自 UIKit KVO 回调（主线程）。声明出来是让
/// 编译器帮我们挡住「从后台线程写 @Published」这种崩溃（Publishing changes
/// from background threads is not allowed）。
@MainActor
final class ChatScrollFlags: ObservableObject {
    @Published private(set) var canScrollUp: Bool = false
    @Published private(set) var canScrollDown: Bool = false

    /// 只在真的翻转时才写 —— 相同值重复赋值也会发 objectWillChange。
    func update(up: Bool, down: Bool) {
        if up != canScrollUp { canScrollUp = up }
        if down != canScrollDown { canScrollDown = down }
    }
}

/// 滚动活动状态（与滚动数值分离，避免高频刷新）。
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
