import SwiftUI
import UIKit

/// v4.4.21：可划词选择的只读富文本视图——用 UITextView 原生长按选字/拖手柄划词/复制菜单。
/// iOS 15 的 SwiftUI `textSelection(.enabled)` 长按只能直接全选、没有划词手柄，无法选词/选句；
/// UITextView 是 UIKit 原生文本选择，任意 iOS 版本都稳定支持长按放大镜定位 + 拖手柄划词 + 复制/朗读。
///
/// 2026-11-02：新增自定义长按菜单项（「复制全文」）——用户反馈长按弹窗里只有系统的「拷贝/共享…」，
/// 想要能一键复制整条消息。系统菜单由 iOS 托管，SwiftUI Text 无法注入自定义项，因此这里用 UITextView：
///   · iOS 16+：走 UITextViewDelegate 的 editMenuForTextIn(suggestedActions:)，在系统菜单后追加 UIAction；
///   · iOS 15 ：UIMenuController.menuItems 注入 UIMenuItem，配合 canPerformAction 放行。
/// 关键：不能用 SwiftUI 的 .contextMenu 实现——它会抢占长按手势，导致划词选字彻底失效
/// （上游 v4.4.13 就是为此删掉了整条消息的 contextMenu，本次不能走回头路）。
struct SelectableText: UIViewRepresentable {
    let attributed: NSAttributedString
    var textColor: UIColor = .label
    var fontSize: CGFloat = 17
    /// 自定义菜单项标题（nil / 空串 = 不注入自定义项，保持系统默认菜单）
    var copyAllTitle: String? = nil
    /// 点自定义菜单项的回调
    var onCopyAll: (() -> Void)? = nil
    /// 2026-11-05 fix-jump：是否允许划词选择。**这是「滚动降级」的新落点**。
    ///
    /// 老做法（fastScrolling）是在滚动期间把正文整个换成 SwiftUI 的 `Text`，
    /// 停手 0.3 秒再换回本控件。后果是每停一次滑，整屏气泡一起换控件：
    ///   · `Text` 走 SwiftUI/CoreText 排版，UITextView 走 TextKit，
    ///     两者换行点与行高本来就不完全一致（中文混排、行内代码等更明显）；
    ///   · 换完 contentSize 突变 → LazyVStack 重新排布 → 用户看到「每滑一次停一下就跳一下」。
    ///
    /// 现在改成**不换控件、只关掉选择**：控件类型/字体/宽度全不变，
    /// 度量必然一致，高度一个点都不会变，所以绝不可能再跳。
    /// 省下的开销是 UITextInteraction（长按放大镜、拖动手柄、选择菜单）不挂载 ——
    /// 这正是 UITextView 重建里最重的那一块，且滚动时用户不会去选字，功能零损失。
    var isSelectable: Bool = true

    /// 菜单注入统一由 CopyableUITextView 自己处理（editMenu(for:suggestedActions:) / UIMenuController），
    /// Coordinator 只保留配置转发的职责，避免两处都注册造成菜单项重复。
    /// 说明：曾尝试用 UITextViewDelegate 的 editMenuForTextIn(suggestedActions:) 注入，
    /// 但自建子类 + 自任 delegate 容易踩空（协议方法不被调用），改用重写自身方法最稳。
    final class Coordinator: NSObject {
        var copyAllTitle: String?
        var onCopyAll: (() -> Void)?
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.copyAllTitle = copyAllTitle
        c.onCopyAll = onCopyAll
        return c
    }

    func makeUIView(context: Context) -> CopyableUITextView {
        let tv = CopyableUITextView()
        tv.isEditable = false
        tv.isScrollEnabled = false
        tv.isSelectable = isSelectable
        tv.backgroundColor = .clear
        tv.textColor = textColor
        tv.font = .systemFont(ofSize: fontSize)
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.textContainer.lineFragmentPadding = 0
        // 允许文字区仍可长按选择，但不让滚动
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultHigh, for: .vertical)
        tv.copyAllTitle = copyAllTitle ?? ""
        tv.onCopyAll = onCopyAll
        return tv
    }

    func updateUIView(_ tv: CopyableUITextView, context: Context) {
        context.coordinator.copyAllTitle = copyAllTitle
        context.coordinator.onCopyAll = onCopyAll
        tv.copyAllTitle = copyAllTitle ?? ""
        tv.onCopyAll = onCopyAll
        // 2026-11-05 fix-jump：这三项都只在**真的变了**的时候才写。
        // 同值重复赋值本身不改排版，但每次 updateUIView 都写一遍 font/textColor 会让
        // UITextView 走一次 setNeedsLayout，滚动期间高频调用时纯属浪费。
        if tv.textColor != textColor { tv.textColor = textColor }
        let newFont = UIFont.systemFont(ofSize: fontSize)
        if tv.font != newFont { tv.font = newFont }
        // 只改 isSelectable，不动 attributedText —— 文字内容才是影响排版的量。
        if tv.isSelectable != isSelectable {
            tv.isSelectable = isSelectable
        }
        // 用 string 比较而不是 attributedText 比较：UITextView 会内部规范化 attributedText，
        // 拿它跟传进来的对象做 == 常永远为 false（或永远为 true），会导致文字该更新时不更新。
        if tv.text != attributed.string || tv.attributedText.length != attributed.length {
            tv.attributedText = attributed
            tv.invalidateIntrinsicContentSize()
        }
    }

    // v4.5.0：sizeThatFits(proposal:) 是 iOS16+ 的 UIViewRepresentable 协议方法，
    // iOS15 编译会报 ProposedViewSize unavailable —— 用 @available 限定，
    // iOS15 靠 UITextView intrinsicContentSize（updateUIView 已 invalidate）自适应高度
    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CopyableUITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? (UIScreen.main.bounds.width - 40)
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: size.height)
    }
}

/// 2026-11-02：支持自定义长按菜单项的 UITextView 子类。
/// 两条系统路径各自处理，互不干扰：
///   · iOS 16+：重写 editMenu(for:suggestedActions:)，在系统给出的菜单里追加「复制全文」。
///     不用 delegate 的 editMenuForTextIn——那要求 delegate 被系统识别，自己写的子类容易踩空；
///     重写自身方法最稳，且系统自带的拷贝/查询/翻译全部保留。
///   · iOS 15 ：UIMenuController.menuItems + canPerformAction 放行（旧机制）。
final class CopyableUITextView: UITextView {
    var copyAllTitle: String = ""
    var onCopyAll: (() -> Void)?

    private static let copyAllSelector = #selector(CopyableUITextView.performCopyAll)

    private var hasCustomItem: Bool {
        !copyAllTitle.isEmpty && onCopyAll != nil
    }

    // MARK: - iOS 16+：往系统编辑菜单追加一项

    /// 正确签名（编译器提示 expected 'for:suggestedActions:' 得出）：
    ///   `func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu?`
    /// 三个易错点（都实际踩过）：
    ///   · 方法名参数标签错（写成 for:in:）→ "method does not override any method from its superclass"
    ///   · 第二参类型错（CGRect vs [UIMenuElement]）→ 不能把 rect 传进来
    ///   · super 的返回值是 **UIMenu?**，必须解包才能调 replacingChildren / children
    @available(iOS 16.0, *)
    override func editMenu(for textRange: UITextRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let base = super.editMenu(for: textRange, suggestedActions: suggestedActions)
        guard hasCustomItem, let handler = onCopyAll else { return base }
        let title = copyAllTitle
        let copyAll = UIAction(title: title, image: UIImage(systemName: "doc.on.doc")) { _ in
            handler()
        }
        // 系统菜单为 nil（无可选内容）时，用 suggestedActions 兜底，仍能给出「复制全文」
        guard let baseMenu = base else {
            return UIMenu(children: suggestedActions + [copyAll])
        }
        // 系统菜单项全部保留（拷贝/查询/翻译），只在末尾追加「复制全文」
        return baseMenu.replacingChildren(baseMenu.children + [copyAll])
    }

    // MARK: - iOS 15：旧菜单机制

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        syncMenuItems()
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if #available(iOS 16, *) {
            // iOS16+ 走 editMenu(for:suggestedActions:)，无需处理全局 menuItems
        } else {
            UIMenuController.shared.menuItems = nil
        }
        return ok
    }

    /// iOS 15 路径：把「复制全文」注册进系统菜单。自定义项只在使用期间挂着，避免影响其它输入框。
    private func syncMenuItems() {
        if #available(iOS 16, *) {
            UIMenuController.shared.menuItems = nil
        } else if hasCustomItem {
            UIMenuController.shared.menuItems = [
                UIMenuItem(title: copyAllTitle, action: Self.copyAllSelector)
            ]
        } else {
            UIMenuController.shared.menuItems = nil
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == Self.copyAllSelector { return hasCustomItem }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func performCopyAll() {
        onCopyAll?()
    }
}

/// 2026-11-02：纯文本包装——长按可拖选划词，菜单里多一项「复制全文」。
/// 用于聊天气泡正文，替代原来只有系统菜单的 SwiftUI Text。
struct CopyableMessageText: View {
    let text: String
    var fontSize: CGFloat = 17
    var foreground: UIColor = .label
    var copyAllTitle: String
    var onCopyAll: () -> Void

    var body: some View {
        SelectableText(
            attributed: NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.systemFont(ofSize: fontSize),
                    .foregroundColor: foreground
                ]
            ),
            textColor: foreground,
            fontSize: fontSize,
            copyAllTitle: copyAllTitle,
            onCopyAll: onCopyAll
        )
    }
}
