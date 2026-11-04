import SwiftUI
import UIKit
// CFAbsoluteTimeGetCurrent 用于 pin 冷却计时
import CoreFoundation

/// v7.4.1-fix73h：UIKit 桥接滚动检测（替代 SwiftUI preference + named coordinateSpace 方案）。
///
/// 背景：原方案在 iOS 16.0-16.3 的 ScrollView 下不可靠——内容视图的 frame(in: .named(...)) 在滚动时
/// 不重新计算、preference 不重新提交 → chatScrollOffset 恒为初始值 → ↑ 按钮永不显示、⬇️ 按钮永不隐藏
/// （用户实测 7.1.212-7.1.215 连续四个版本修复无效的根因）。
/// 修复：直接 KVO 监听底层 UIScrollView 的 contentOffset / contentSize / frame——UIKit 精确数值，
/// 无惰性渲染、无坐标系竞态、无 preference 时序问题，iOS 15-17 通吃（对齐 OpenMinis 的
/// UICollectionView contentSize/bounds 精确计算思路）。
///
/// 用法：作为 ScrollView 的第一个内容子视图（frame height 0，不撑内容），superview 链直达
/// 底层 UIScrollView；滚动/内容变化时经 KVO 回调上报。
///
/// ---
/// 2026-11-05 **重写（fix-freeze-2）** —— 修「发完消息就卡死、点哪都没反应、必须杀进程重进」。
///
/// 上一版有两个致命缺陷，叠在一起就是一个**自激死循环**：
///
///   ① `observe(\.bounds)` 监听错了对象。
///      UIScrollView 滚动时的实现就是改 `bounds.origin`，所以 bounds 的 KVO
///      **每帧都会触发**（不只是视口大小变的时候）。上一版的回调里无条件调
///      `pinToBottom`，于是每帧都排一次 setContentOffset。
///
///   ② offset 的 KVO 里无条件调 `onOffset` → `ChatScrollState.setOffset` →
///      `activity.noteScrolled()`。而 `noteScrolled` 会把 `isScrollingFast` 置 true，
///      让**所有**气泡正文从 UITextView 降级成 Text（见 ChatScrollState 的说明）。
///      行高一变，contentSize 就变；contentSize 一变，又触发 ①的 pinToBottom……
///
///   合起来的循环：
///      pin → setContentOffset → offset KVO → noteScrolled → isScrollingFast=true
///      → 全部气泡换控件 → 行高全变 → contentSize 变 → bounds/contentSize KVO
///      → 再 pin → ……（0.3 秒后降级恢复，高度再变一次，循环继续）
///
///   结果：主线程被「几十条消息重新布局 + UITextView 重建」无限占满，
///   界面一帧都刷不出来。但网络请求和数据落盘都在别的线程，照样完成任务——
///   这正是用户描述的「发完就卡死、屏幕点什么都没反应、杀进程重进才看到他给我的回复」。
///
/// 修法（三条，缺一不可）：
///   · **视口高度改监听 `frame`**：滚动只改 bounds.origin，不改 frame，所以 frame 的 KVO
///     只在键盘/旋转时触发一次，不会每帧打进来。
///   · **只有用户真的在拖/惯性滚动时才上报「用户在滚」**：判据用 UIScrollView 自带的
///     `isTracking / isDragging / isDecelerating`（系统维护，绝对可靠），
///     而不是旁挂 panGestureRecognizer 猜手势状态。程序性 setContentOffset 不触发降级，
///     循环从根上断掉。
///   · **贴底吸附只在用户没碰屏幕时生效**：`userIsScrolling` 为真时 pin 直接返回，
///     手指一碰就被拽回底部的问题（用户反馈「滑下去还划不动」）一并解决。
struct ScrollGeometryBridge: UIViewRepresentable {
    /// 2026-11-05：外部请求「重新吸附到底部」的通知名。
    /// 由 ChatScrollState.requestStickToBottom() 发出，BridgeView 收到后恢复吸附并钉一次底。
    static let stickToBottomNote = Notification.Name("TrollAgent.scroll.stickToBottom")
    /// 2026-11-05：外部请求「解除吸附」的通知名（点 ↑ 回顶部时用）。
    static let releaseStickNote = Notification.Name("TrollAgent.scroll.releaseStick")

    /// 滚动偏移（对齐原 marker 语义：顶部=0，向下滚为负）
    var onOffset: (CGFloat) -> Void
    /// 内容总高
    var onContentHeight: (CGFloat) -> Void
    /// 视口高度
    var onViewportHeight: (CGFloat) -> Void
    /// **仅当用户真的用手指拖拽/惯性滚动时**才回调。
    ///
    /// 接 `ChatScrollState.noteUserScrolled()`，也就是「滚动期间把正文降级为轻量 Text」
    /// 那个优化的唯一触发点。程序性 `setContentOffset`（贴底吸附、scrollTo）绝不走这里——
    /// 那正是上一版自激死循环的入口。
    var onUserScroll: (() -> Void)? = nil

    func makeUIView(context: Context) -> BridgeView {
        let v = BridgeView()
        v.onOffset = onOffset
        v.onContentHeight = onContentHeight
        v.onViewportHeight = onViewportHeight
        v.onUserScroll = onUserScroll
        return v
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        // SwiftUI 每次 body 重算会用新的闭包（捕获新的 self），必须刷新到已存在的 view 上，
        // 否则 @State 永远写进旧副本。
        uiView.onOffset = onOffset
        uiView.onContentHeight = onContentHeight
        uiView.onViewportHeight = onViewportHeight
        uiView.onUserScroll = onUserScroll
    }

    final class BridgeView: UIView {
        var onOffset: ((CGFloat) -> Void)?
        var onContentHeight: ((CGFloat) -> Void)?
        var onViewportHeight: ((CGFloat) -> Void)?
        var onUserScroll: (() -> Void)?

        private weak var scrollView: UIScrollView?
        private var offsetObs: NSKeyValueObservation?
        private var contentSizeObs: NSKeyValueObservation?
        private var frameObs: NSKeyValueObservation?
        /// 惯性滚动结束的判定（系统 KVO 属性，比 pan 手势可靠）
        private var decelObs: NSKeyValueObservation?
        private var attachAttempts = 0

        // MARK: - 贴底吸附状态（2026-11-05）

        /// 是否处于「跟随底部」状态。只有 true 时才在内容变高时把 offset 钉到底。
        /// 初值 true —— 打开会话默认就要停在最新消息处。
        private var stickToBottom = true
        /// 贴底判定的容差：距底部 24pt 内都算「在底部」。
        private let stickTolerance: CGFloat = 24
        /// 防 pinToBottom 重入（async 排程期间又来一次 contentSize 变更）
        private var pinning = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                attach(to: findScrollView())
            } else {
                detach()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // didMoveToWindow 时 SwiftUI 可能尚未把内容挂进 UIScrollView，兜底重试（最多 5 次）
            if scrollView == nil, window != nil, attachAttempts < 5 {
                attachAttempts += 1
                attach(to: findScrollView())
            }
        }

        /// 从自身沿 superview 链向上找最近的 UIScrollView（SwiftUI ScrollView 底层即 UIScrollView）
        private func findScrollView() -> UIScrollView? {
            var v: UIView? = superview
            while let cur = v {
                if let sv = cur as? UIScrollView { return sv }
                v = cur.superview
            }
            return nil
        }

        /// 用户是否正在用这根手指/这口气的惯性滚动接管滚动视图。
        ///
        /// 这三个属性由 UIScrollView 自己维护，是判断「用户操作 vs 程序操作」最可靠的依据：
        ///   · isTracking   —— 手指按在滚动视图上（含按住不动）
        ///   · isDragging   —— 正在拖拽
        ///   · isDecelerating —— 松手后的惯性减速中
        /// 三者皆 false 就是「静止」，此时 offset 的任何变化都只能是代码设的。
        private func userIsScrolling(_ sv: UIScrollView) -> Bool {
            sv.isTracking || sv.isDragging || sv.isDecelerating
        }

        private func attach(to sv: UIScrollView?) {
            guard let sv else { return }
            // fix73j-审计 M-6：attach 成功复位重试计数——否则后续 detach/重建（视图复用、
            // 会话切换）后 attachAttempts 已到 5，layoutSubviews 兜底重试永久失效，
            // KVO 桥接再也装不上 → 滚动按钮静默失效。
            attachAttempts = 0
            // 已经挂在同一个 scrollView 上就不要重复注册 KVO（先全部作废再重建，
            // 保证任何时候只有一套观察者）。
            if scrollView === sv, offsetObs != nil {
                return
            }
            scrollView = sv

            offsetObs = sv.observe(\.contentOffset, options: [.initial, .new]) { [weak self] sv, _ in
                guard let self = self else { return }
                // UIKit offset.y：顶部=0（或 -adjustedInset.top），向下滚为正。
                // 转回原 marker 语义（顶部=0，向下为负），ChatView 的显示矩阵判断完全不用改。
                self.onOffset?(-sv.contentOffset.y)

                if self.userIsScrolling(sv) {
                    // 用户在拖/惯性滚 → 立即解除吸附（上滑看历史绝不被拽回），
                    // 并通知上层「这是用户操作」才允许把正文降级为轻量 Text。
                    self.stickToBottom = false
                    self.onUserScroll?()
                } else {
                    // 静止状态下的 offset 变化 = 代码设的（贴底吸附 / scrollTo）。
                    // 不触发降级，只顺手校正一次吸附判定，保证「程序性滚到底后继续跟随」。
                    self.stickToBottom = self.isAtBottom(sv)
                }
            }

            contentSizeObs = sv.observe(\.contentSize, options: [.initial, .new]) { [weak self] sv, _ in
                guard let self = self else { return }
                self.onContentHeight?(sv.contentSize.height)
                // 内容变高（流式追加 / 新 cell 渲染）且用户没在操作 → 钉到底，无动画。
                self.pinToBottom(sv)
            }

            // 关键修复：**监听 frame 而不是 bounds**。
            // UIScrollView 滚动的实现就是改 bounds.origin，所以 observe(\.bounds) 每帧都会触发；
            // frame 只在键盘弹出/收起、旋转、分屏时变 —— 这才是真正意义上的「视口高度变化」。
            // 上一版监听 bounds 导致每帧都调 pinToBottom，是自激死循环的一半。
            frameObs = sv.observe(\.frame, options: [.initial, .new]) { [weak self] sv, _ in
                guard let self = self else { return }
                self.onViewportHeight?(sv.bounds.height)
                self.pinToBottom(sv)
            }

            // 惯性滚动结束的那一刻 offset 可能不再变化，但吸附状态需要恢复判定：
            // 用户滑到最底部松手停下 → 后续新消息应该继续自动跟随。
            decelObs = sv.observe(\.isDecelerating, options: [.new]) { [weak self] sv, _ in
                guard let self = self else { return }
                guard !self.userIsScrolling(sv) else { return }
                self.stickToBottom = self.isAtBottom(sv)
                // 停稳后如果确实在底部，把最后那点估算误差补上（LazyVStack 常见差几十 pt）
                if self.stickToBottom { self.pinToBottom(sv) }
            }

            observeStickRequest()
        }

        /// 2026-11-05：监听「重新吸附到底部」请求（用户发消息 / 切换会话时发出）。
        /// 这些是低频动作，所以走通知没有性能顾虑；高频的流式追加完全靠自动吸附，不发通知。
        private var stickObserver: NSObjectProtocol?
        private var releaseObserver: NSObjectProtocol?

        private func observeStickRequest() {
            guard stickObserver == nil else { return }
            stickObserver = NotificationCenter.default.addObserver(
                forName: ScrollGeometryBridge.stickToBottomNote,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self, let sv = self.scrollView else { return }
                self.stickToBottom = true
                // 立刻钉一次，不用等 contentSize 下一次变化。
                let maxOffset = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
                if maxOffset > 0 {
                    sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: maxOffset), animated: false)
                }
            }
            // 2026-11-05：解除吸附（点 ↑ 回顶部）。只翻转状态，不动 offset ——
            // offset 由调用方的 proxy.scrollTo 负责，这里插手会互相打断。
            //
            // 上一版在这里加了 0.4 秒的「交战中」并强写 userInteracting = true，
            // 现在不需要了：用户是否在操作由 UIScrollView.isTracking 直接读，
            // 不靠自己维护的布尔。少一个状态就少一处可能卡死的分支。
            releaseObserver = NotificationCenter.default.addObserver(
                forName: ScrollGeometryBridge.releaseStickNote,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.stickToBottom = false
            }
        }

        /// 是否已在底部（含容差）
        private func isAtBottom(_ sv: UIScrollView) -> Bool {
            let maxOffset = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
            guard maxOffset > 0 else { return true }   // 内容比视口短 = 天然在底部
            return sv.contentOffset.y >= maxOffset - stickTolerance
        }

        /// 无动画钉到底部。用 setContentOffset(animated: false) 而不是 UIView.animate，
        /// 避免与用户手势、与 SwiftUI 自身布局动画互相插值 —— 那正是「跳」的来源。
        private func pinToBottom(_ sv: UIScrollView) {
            // 三重闸门，任一不满足立刻返回（这是保证不出现自激循环的关键）：
            //   1) 不是吸附态（用户明确在看历史）→ 不动
            //   2) 用户正在操作（拖拽/惯性）→ 不动，否则手指会被系统判定为手势冲突
            //   3) 上一帧排的 pin 还没执行 → 不重复排
            guard stickToBottom, !userIsScrolling(sv), !pinning else { return }
            let maxOffset = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
            guard maxOffset > 0 else { return }
            guard abs(sv.contentOffset.y - maxOffset) > 0.5 else { return }   // 已到底，不重复设
            pinning = true
            // 不能在最内层 KVO 回调里同步改 offset（UIKit 不允许在观察回调中改自身状态，
            // 且会递归触发自身 KVO）。丢到下一个 runloop。
            DispatchQueue.main.async { [weak self, weak sv] in
                guard let self = self else { return }
                self.pinning = false
                guard let sv = sv, self.stickToBottom, !self.userIsScrolling(sv) else { return }
                let m = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
                guard m > 0 else { return }
                guard abs(sv.contentOffset.y - m) > 0.5 else { return }
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: m), animated: false)
            }
        }

        private func detach() {
            if let o = stickObserver {
                NotificationCenter.default.removeObserver(o)
                stickObserver = nil
            }
            if let o = releaseObserver {
                NotificationCenter.default.removeObserver(o)
                releaseObserver = nil
            }
            offsetObs = nil
            contentSizeObs = nil
            frameObs = nil
            decelObs = nil
            scrollView = nil
            pinning = false
        }

        deinit { detach() }
    }
}
