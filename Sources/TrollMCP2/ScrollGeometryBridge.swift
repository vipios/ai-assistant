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
        /// 防越界修正重复排程（2026-11-05 fix-blank-2）
        private var overshootFixScheduled = false

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
            // 2026-11-05 fix-blank：**挂上之后立刻补一次贴底**。
            //
            // 时序问题：ChatView 的 onAppear 早于本视图 attach 到 UIScrollView
            // （didMoveToWindow/layoutSubviews 要等 SwiftUI 真正把内容树挂进宿主）。
            // 所以 onAppear 发出的 stickToBottom 通知经常**没人接**——那时 stickObserver
            // 还没注册（它在 attach 里才装）。结果就是：打开会话 → 吸附请求石沉大海
            // → 停在 offset 0（顶部）或停在某个未渲染位置 → 用户看到空白/位置不对。
            //
            // 这里在首次 attach 成功后主动补一次分步贴底，把「通知早于监听」这个窗口关掉。
            // 用 contentSize > 0 作为「真有内容可贴」的判据：内容还没布局出来时
            // 不置位，留给后续 layoutSubviews 再试（置位太早会永远错过这一轮）。
            if !didInitialPin, window != nil, let sv = scrollView, sv.contentSize.height > 0 {
                didInitialPin = true
                pinToBottom(sv)
            }
        }

        /// 是否已在 attach 后补过首次贴底（避免每帧 layoutSubviews 都重来）
        private var didInitialPin = false

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
                    //
                    // 2026-11-05 fix-blank-2：**先判越界**。滚过真实底部时绝不能往下走
                    // 那个「stickToBottom = isAtBottom(sv)」——那时它必然是 false，
                    // 等于把自动跟随关掉，空白就永久留下了。这里改为夹回并保持跟随。
                    if self.isOverscrolled(sv) {
                        self.scheduleOvershootFix(sv)
                        return
                    }
                    //
                    // 2026-11-05 fix-blank **关键**：分步贴合进行到一半时，offset 停在
                    // 「还没到底」的位置，如果这里照常把 stickToBottom 改写成 isAtBottom
                    // （= false），后面几步会被自己的闸门拦掉，永远贴不到底 —— 又变成
                    // 打开会话停在半路。所以分步期间跳过这个改写。
                    if !self.pinning {
                        self.stickToBottom = self.isAtBottom(sv)
                    }
                }
            }

            contentSizeObs = sv.observe(\.contentSize, options: [.initial, .new]) { [weak self] sv, _ in
                guard let self = self else { return }
                self.onContentHeight?(sv.contentSize.height)
                // 2026-11-05 fix-blank-2：内容**变矮**时 offset 不会变，offset 观察者不会重入，
                // 于是「offset 停在旧内容高度」这个越界状态会一直留着 = 空白。
                // 这是发送消息后最容易踩到的一条：新消息进 LazyVStack 会触发分组重算 /
                // 估算高度重算，contentSize 可能先鼓后缩。所以这里必须主动判一次越界。
                if self.isOverscrolled(sv) {
                    self.scheduleOvershootFix(sv)
                    return
                }
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
                // 视口变高（键盘收起）→ maxOffset 变小 → 原来「在底部」的 offset 现在越界。
                // 同上，先夹回再贴底。
                if self.isOverscrolled(sv) {
                    self.scheduleOvershootFix(sv)
                    return
                }
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
                // 2026-11-05 fix-blank：改走 pinToBottom（分步靠近）—— 这里原来是
                // 一次性 setContentOffset 到底，正是「打开会话整屏空白」的来源。
                self.pinToBottom(sv)
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

        /// 内容可滚动的最大 offset（= 停在最底部时 contentOffset.y 的值）。
        /// 统一走这里，避免各处各写一遍公式后漏掉 adjustedContentInset。
        private func maxOffset(_ sv: UIScrollView) -> CGFloat {
            sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
        }

        /// 是否已在底部（含容差）
        private func isAtBottom(_ sv: UIScrollView) -> Bool {
            let m = maxOffset(sv)
            guard m > 0 else { return true }   // 内容比视口短 = 天然在底部
            return sv.contentOffset.y >= m - stickTolerance
        }

        /// 是否**滚过了真实内容底部**（视口落在内容之外的空白区）。
        ///
        /// 2026-11-05 fix-blank-2：这是「发完消息整屏空白」的判据。
        /// 越界只可能来自代码（用户手指拖不过底部，松手会回弹），所以一旦判定越界，
        /// 就直接夹回底部 —— 不用管是谁设的（SwiftUI scrollTo 的估算落位、
        /// LazyVStack 内容变矮、键盘收起后视口变高导致 m 变小，全都覆盖）。
        private func isOverscrolled(_ sv: UIScrollView) -> Bool {
            let m = maxOffset(sv)
            guard m > 0 else { return false }
            return sv.contentOffset.y > m + 1
        }

        /// 越界修正：夹回真实底部，并恢复「跟随底部」状态。
        ///
        /// 为什么必须单独做这件事：越界时 `contentOffset` 本身不会再变（除非用户动手），
        /// 于是 offset 观察者不会重入、contentSize 观察者也不一定再触发 ——
        /// 越界状态会**一直停在那里**，正是用户说的「内容全顶没了，下滑一下才出来」。
        /// 而且越界那一刻若不拦住，offset 观察者会把 stickToBottom 判成 false，
        /// 等于自己把唯一的自动恢复机制关掉了。
        private func scheduleOvershootFix(_ sv: UIScrollView) {
            guard !overshootFixScheduled else { return }
            overshootFixScheduled = true
            DispatchQueue.main.async { [weak self, weak sv] in
                guard let self = self else { return }
                self.overshootFixScheduled = false
                guard let sv = sv, !self.userIsScrolling(sv) else { return }
                let m = self.maxOffset(sv)
                guard m > 0, sv.contentOffset.y > m + 1 else { return }
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: m), animated: false)
                self.stickToBottom = true
                // 夹回之后再请分步贴底一次：内容可能还在长（LazyVStack 陆续建 cell）。
                self.pinToBottom(sv)
            }
        }

        /// 无动画钉到底部。用 setContentOffset(animated: false) 而不是 UIView.animate，
        /// 避免与用户手势、与 SwiftUI 自身布局动画互相插值 —— 那正是「跳」的来源。
        ///
        /// 2026-11-05 **再修（fix-blank）——修「打开会话偶尔整屏空白，往上滑几下才出内容」**。
        ///
        /// 病根不是「没滚到底」，而是**一步跳太远**：
        /// `LazyVStack` 只渲染「当前可见范围 + 预取范围」的 cell，可见范围由
        /// SwiftUI 的布局系统在每一帧里按 contentOffset 反推。用 setContentOffset
        /// 一次性从 0 跳到几千 pt 的底部时，这一帧里可见范围还没重算完，
        /// 目标区域一个 cell 都还没创建 → 视口落在空白上 → 用户看到整屏空白。
        /// 只要手指一动，SwiftUI 重新计算可见范围、把 cell 建出来，内容就"突然"出现
        /// —— 这正是用户描述的「往上滑动几下就出来了内容」。
        ///
        /// 修法：**分步靠近**。每帧只走剩余距离的一部分（最少 3 步），
        /// 每一步之间隔一个 runloop，SwiftUI 有完整一帧去更新可见范围并创建新 cell。
        /// 因为每一步的目标都在"已经渲染出来的区域附近"，所以任何一帧都不会落在空白上。
        /// 视觉上就是「一进会话就停在最新消息处」，不会有跳或空白。
        private func pinToBottom(_ sv: UIScrollView) {
            // 三重闸门，任一不满足立刻返回（这是保证不出现自激循环的关键）：
            //   1) 不是吸附态（用户明确在看历史）→ 不动
            //   2) 用户正在操作（拖拽/惯性）→ 不动，否则手指会被系统判定为手势冲突
            //   3) 上一帧排的 pin 还没执行 → 不重复排
            guard stickToBottom, !userIsScrolling(sv), !pinning else { return }
            let m = maxOffset(sv)
            guard m > 0 else { return }
            guard abs(sv.contentOffset.y - m) > 0.5 else { return }   // 已到底，不重复设
            pinning = true
            stepTowardBottom(sv, remaining: 3)
        }

        /// 分步靠近底部：每步走剩余距离的 1/remaining，最后一步精确落位。
        ///
        /// 为什么不能一步到位 —— 见 pinToBottom 里 fix-blank 的说明。
        /// 步数固定 3 是权衡：再多会让「打开会话」有可见的逐格移动感，
        /// 再少则 LazyVStack 来不及在两帧内建完全部需要的 cell。
        private func stepTowardBottom(_ sv: UIScrollView, remaining: Int) {
            // 不能在最内层 KVO 回调里同步改 offset（UIKit 不允许在观察回调中改自身状态，
            // 且会递归触发自身 KVO）。丢到下一个 runloop —— 这一步同时也是
            // 「给 SwiftUI 一帧去更新可见范围」的保证。
            DispatchQueue.main.async { [weak self, weak sv] in
                guard let self = self else { return }
                guard let sv = sv, self.stickToBottom, !self.userIsScrolling(sv) else {
                    self.pinning = false
                    return
                }
                // 目标要重新算：这一帧里 LazyVStack 可能又建出了几个 cell，
                // contentSize 已经变大，用上一帧的旧目标会「差一点到底」。
                let m = self.maxOffset(sv)
                guard m > 0 else {
                    self.pinning = false
                    return
                }
                let cur = sv.contentOffset.y
                let dest = remaining <= 1 ? m : cur + (m - cur) / CGFloat(remaining)
                if abs(dest - cur) > 0.5 {
                    sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: dest), animated: false)
                }
                if remaining > 1 && abs(m - dest) > 0.5 {
                    self.stepTowardBottom(sv, remaining: remaining - 1)
                } else {
                    self.pinning = false
                }
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
            // 2026-11-05 fix-blank-2：越界修正的排程标记同样要复位，
            // 否则 detach 时正好排着一个未执行的修正，重建后会被这个标记永久挡掉。
            overshootFixScheduled = false
            // 2026-11-05 fix-blank：切会话/离屏后要允许新一轮补贴底，
            // 否则新会话 attach 上来时 didInitialPin 还是 true → 不再补 → 又停在空白/顶部。
            didInitialPin = false
            // stickToBottom 同理复位：新会话默认就该停在最新消息处。
            stickToBottom = true
        }

        deinit { detach() }
    }
}
