import SwiftUI
import UIKit

/// v7.4.1-fix73h：UIKit 桥接滚动检测（替代 SwiftUI preference + named coordinateSpace 方案）。
///
/// 背景：原方案在 iOS 16.0-16.3 的 ScrollView 下不可靠——内容视图的 frame(in: .named(...)) 在滚动时
/// 不重新计算、preference 不重新提交 → chatScrollOffset 恒为初始值 → ↑ 按钮永不显示、⬇️ 按钮永不隐藏
/// （用户实测 7.1.212-7.1.215 连续四个版本修复无效的根因）。
/// 修复：直接 KVO 监听底层 UIScrollView 的 contentOffset / contentSize / bounds——UIKit 精确数值，
/// 无惰性渲染、无坐标系竞态、无 preference 时序问题，iOS 15-17 通吃（对齐 OpenMinis 的
/// UICollectionView contentSize/bounds 精确计算思路）。
///
/// 用法：作为 ScrollView 的第一个内容子视图（frame height 0，不撑内容），superview 链直达
/// 底层 UIScrollView；滚动/内容变化时经 KVO 回调上报三个状态。
///
/// 2026-11-05 **贴底吸附（fix-jitter-1）** —— 修「杀进程重进后 AI 消息一直上下跳动」。
///
/// 老做法是「内容变了 → 算一次应该滚到哪 → proxy.scrollTo(.bottom)」，这条路在
/// LazyVStack + 流式增长下必然抖：
///   · LazyVStack 的内容高度是**估算**的，滚到底之后又新渲染出几个 cell，
///     contentSize 会突变（估计值与真实值差几十上百 pt）；
///   · scrollTo 每次都是重新计算目标 + 走一遍动画，两次计算之间内容又长了；
///   · 于是「滚到底 → 高度变大 → 又不在底了 → 再滚」循环，视觉上就是上下跳。
///
/// 现在改为 UIKit 层的吸附：只要用户**本来就在底部**，每次 contentSize 变化就
/// 直接把 contentOffset 设成 contentSize.height - bounds.height（无动画、无插值），
/// 一次设定到位。用户手指一碰（beginTracking / willBeginDragging）立刻解除吸附，
/// 上滑看历史绝不会被拉回。
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

    func makeUIView(context: Context) -> BridgeView {
        let v = BridgeView()
        v.onOffset = onOffset
        v.onContentHeight = onContentHeight
        v.onViewportHeight = onViewportHeight
        return v
    }

    func updateUIView(_ uiView: BridgeView, context: Context) {
        // SwiftUI 每次 body 重算会用新的闭包（捕获新的 self），必须刷新到已存在的 view 上，
        // 否则 @State 永远写进旧副本。
        uiView.onOffset = onOffset
        uiView.onContentHeight = onContentHeight
        uiView.onViewportHeight = onViewportHeight
    }

    final class BridgeView: UIView {
        var onOffset: ((CGFloat) -> Void)?
        var onContentHeight: ((CGFloat) -> Void)?
        var onViewportHeight: ((CGFloat) -> Void)?

        private weak var scrollView: UIScrollView?
        private var offsetObs: NSKeyValueObservation?
        private var contentSizeObs: NSKeyValueObservation?
        private var boundsObs: NSKeyValueObservation?
        private var attachAttempts = 0

        // MARK: - 贴底吸附状态（2026-11-05）

        /// 是否处于「跟随底部」状态。
        /// 只有它 true 时才会在内容高度变化时自动把 offset 钉到底部。
        /// 初值 true —— 打开会话默认就要停在最新消息处。
        private var stickToBottom = true
        /// 用户是否正在用手指拖/拽。（拖拽期间绝不自动改 offset，否则手势会被打断）
        private var userInteracting = false
        /// 贴底判定的容差：距底部 24pt 内都算「在底部」。
        /// 比原来 ChatScrollState 的 40pt 收紧——40pt 太宽，用户其实已经上滑一点了
        /// 还会被判定为在底部然后被拉下去。
        private let stickTolerance: CGFloat = 24

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

        private func attach(to sv: UIScrollView?) {
            guard let sv else { return }
            // 2026-11-05：attach 可能被调多次（didMoveToWindow + layoutSubviews 兜底），
            // 同一条 pan 手势重复 addTarget 会让 handlePan 被调用 N 次。
            // 换挂前先把旧的摘掉，保证只有一个监听。
            if let old = scrollView, old !== sv {
                old.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
            } else if scrollView === sv {
                sv.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
            }
            // fix73j-审计 M-6：attach 成功复位重试计数——否则后续 detach/重建（视图复用、
            // 会话切换）后 attachAttempts 已到 5，layoutSubviews 兜底重试永久失效，
            // KVO 桥接再也装不上 → 滚动按钮静默失效。
            attachAttempts = 0
            scrollView = sv
            // 2026-11-05：手势状态用 delegate 感知。
            // 注意：SwiftUI 的 ScrollView 自带 delegate（内部包装），直接覆盖 sv.delegate
            // 会把 SwiftUI 自己的滚动逻辑搞坏。所以这里不用 delegate，改用
            // panGestureRecognizer 的 target-action 旁挂监听 —— 只观察，不改任何行为。
            observePan(sv.panGestureRecognizer)
            observeStickRequest()

            offsetObs = sv.observe(\.contentOffset, options: [.initial, .new]) { [weak self] sv, _ in
                guard let self = self else { return }
                // UIKit offset.y：顶部=0（或 -adjustedInset.top），向下滚为正。
                // 转回原 marker 语义（顶部=0，向下为负），ChatView 的显示矩阵判断完全不用改。
                self.onOffset?(-sv.contentOffset.y)
                // 用户手动滚离底部 → 解除吸附；滚回底部 → 恢复吸附。
                // 拖拽期间不改判定（拖拽结束的回弹由下面的吸附收尾）。
                if !self.userInteracting {
                    self.stickToBottom = self.isAtBottom(sv)
                }
            }
            contentSizeObs = sv.observe(\.contentSize, options: [.initial, .new]) { [weak self] sv, _ in
                guard let self = self else { return }
                self.onContentHeight?(sv.contentSize.height)
                // 内容变高（流式追加 / 新 cell 渲染）且处于吸附态 → 直接钉到底，无动画。
                if self.stickToBottom, !self.userInteracting {
                    self.pinToBottom(sv)
                }
            }
            boundsObs = sv.observe(\.bounds, options: [.initial, .new]) { [weak self] sv, _ in
                guard let self = self else { return }
                self.onViewportHeight?(sv.bounds.height)
                // 视口高度变化（键盘弹出/收起、旋转）同理
                if self.stickToBottom, !self.userInteracting {
                    self.pinToBottom(sv)
                }
            }
        }

        /// 旁挂监听拖拽手势，只读状态、不介入处理。
        private func observePan(_ pan: UIPanGestureRecognizer?) {
            guard let pan else { return }
            pan.addTarget(self, action: #selector(handlePan(_:)))
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
                self.userInteracting = false
                self.stickToBottom = true
                // 立刻钉一次，不用等 contentSize 下一次变化。
                let maxOffset = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
                if maxOffset > 0 {
                    sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: maxOffset), animated: false)
                }
            }
            // 2026-11-05：解除吸附（点 ↑ 回顶部）。只翻转状态，不动 offset ——
            // offset 由调用方的 proxy.scrollTo 负责，这里插手会互相打断。
            releaseObserver = NotificationCenter.default.addObserver(
                forName: ScrollGeometryBridge.releaseStickNote,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                self.stickToBottom = false
                self.userInteracting = true
                // 短暂保持「交战中」，让 proxy.scrollTo 有时间生效；
                // 0.4 秒后若用户没再碰屏幕、且确实不在底部，才允许重新判定吸附。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self = self, let sv = self.scrollView else { return }
                    self.userInteracting = false
                    self.stickToBottom = self.isAtBottom(sv)
                }
            }
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                // 手指一落下就解除吸附 —— 这是「上滑看历史不被拉回」的关键。
                userInteracting = true
                stickToBottom = false
            case .ended, .cancelled, .failed:
                userInteracting = false
                // 松手后如果停在底部附近（含惯性滚动最终停在底部），恢复吸附。
                // 用 asyncAfter 等减速动画走完再判定，避免减速中途误判。
                if let sv = scrollView {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak sv] in
                        guard let self = self, let sv = sv, !self.userInteracting else { return }
                        self.stickToBottom = self.isAtBottom(sv)
                    }
                }
            default:
                break
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
            // 关键：不能在最内层 KVO 回调里同步改 offset（UIKit 会认为回调中改自身状态
            // 不合法，且可能递归触发 KVO）。丢到下一个 runloop。
            guard !pinning else { return }
            pinning = true
            DispatchQueue.main.async { [weak self, weak sv] in
                guard let self = self else { return }
                self.pinning = false
                guard let sv = sv, self.stickToBottom, !self.userInteracting else { return }
                let maxOffset = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
                guard maxOffset > 0 else { return }
                guard abs(sv.contentOffset.y - maxOffset) > 0.5 else { return }   // 已到底，不重复设
                sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: maxOffset), animated: false)
            }
        }

        /// 防 pinToBottom 重入（async 排程期间又来一次 contentSize 变更）
        private var pinning = false

        private func detach() {
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
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
            boundsObs = nil
            scrollView = nil
            pinning = false
        }

        deinit { detach() }
    }
}
