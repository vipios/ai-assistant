// MessageNavigator.swift
// 2026-11-02：消息导航条（用户指定）——右侧屏幕边缘一条细竖条，每根横线代表一条
// **用户自己说过的话**；点击竖条从右侧弹出半透明抽屉，列出全部发言，可上下滚动，
// 点击任意一条直接跳回当时的对话位置。
//
// 设计约束（用户原话）：
//   「点击一下横条就能侧弹窗出来我所有说过的话可以进行上下滚动查看，点击一下直接跳到当时的对话」
//
// 实现要点：
//  1) 竖条不抢聊天区手势：只占右侧 14pt，且用 contentShape 收紧命中区域；
//  2) 抽屉用 overlay 而非 sheet——sheet 会盖住全屏且动画从底部上来，与「侧弹窗」不符；
//  3) 跳转通过闭包把 message id 交回 ChatView，由其中的 ScrollViewProxy 执行 scrollTo；
//  4) 当前屏幕所在的消息在列表里高亮 + 最右侧黑条标记（对齐用户给的参考图）。

import SwiftUI

/// 右侧边缘的消息导航条 + 侧滑抽屉
struct MessageNavigator: View {
    /// 全部消息（内部只挑用户发言）
    let messages: [ChatMessage]
    /// 点击某条用户消息 → 回调其 id，由外层 ScrollViewProxy 跳转
    let onJump: (UUID) -> Void

    @State private var showPanel = false
    /// 抽屉内当前高亮的条目（进入时定位到最近一条）
    @State private var highlightId: UUID?

    /// 用户发言列表（保持时间顺序）
    private var userMessages: [ChatMessage] {
        messages.filter { !$0.isTool && $0.role == .user }
    }

    var body: some View {
        // 消息太少（<=1 条）时不显示，避免空导航干扰
        if userMessages.count >= 2 {
            edgeBar
                .overlay(alignment: .trailing) {
                    if showPanel {
                        panelLayer
                    }
                }
        }
    }

    // MARK: - 边缘竖条

    private var edgeBar: some View {
        // 竖条高度自适应：每条发言一根短线，间距 6pt，最多显示 26 根（超出不画，避免溢出屏幕）
        let maxBars = 26
        let bars = Array(userMessages.suffix(maxBars))
        let barH: CGFloat = 2
        let gap: CGFloat = 7

        return Button {
            withAnimation(.easeOut(duration: 0.22)) { showPanel = true }
            // 打开时把高亮定位到最后一条（= 当前所在位置附近）
            highlightId = userMessages.last?.id
        } label: {
            VStack(spacing: gap) {
                ForEach(bars) { m in
                    // 越靠后（越新）越深，形成「进度感」；最后一根最长且最黑（对齐参考图）
                    let isLast = m.id == bars.last?.id
                    Capsule()
                        .fill(Color.primary.opacity(isLast ? 0.85 : 0.28))
                        .frame(width: isLast ? 14 : 11, height: barH)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 3)
            // 命中区域收紧到竖条本身，绝不吃掉聊天区滑动
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .frame(width: 20)
        .opacity(showPanel ? 0 : 1)
    }

    // MARK: - 侧弹抽屉

    private var panelLayer: some View {
        ZStack(alignment: .trailing) {
            // 半透明遮罩：点空白处关闭（参考图里遮罩很淡，不压暗聊天内容）
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { close() }

            panel
                .frame(width: panelWidth)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        .ignoresSafeArea()
    }

    private var panelWidth: CGFloat {
        min(300, UIScreen.main.bounds.width * 0.72)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            // 顶部：条数 + 关闭
            HStack(spacing: 6) {
                Text("\(userMessages.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("条发言")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider().opacity(0.5)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(userMessages) { m in
                            row(m)
                                .id(m.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear {
                    // 定位到当前（最后一轮）位置，用户不用从头滚
                    if let last = userMessages.last {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(
            // 半透明毛玻璃（参考图为浅色磨砂，不遮挡底层内容）
            VisualBlurView(style: .systemThickMaterial)
                .clipShape(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, x: -4, y: 0)
        .padding(.trailing, 8)
        .padding(.vertical, 60)
    }

    // MARK: - 单行

    private func row(_ m: ChatMessage) -> some View {
        let isOn = m.id == highlightId
        return Button {
            highlightId = m.id
            onJump(m.id)
            close()
        } label: {
            HStack(spacing: 8) {
                Text(displayText(m.content))
                    .font(.system(size: 12.5))
                    .foregroundColor(isOn ? .primary : .primary.opacity(0.72))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 当前所在位置：最右侧黑条标记（对齐参考图）
                if isOn {
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 3, height: 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                isOn ? Color.primary.opacity(0.06) : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// 单行展示文本：压平换行、去多余空白
    private func displayText(_ s: String) -> String {
        let t = s
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "(空)" : t
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.18)) { showPanel = false }
    }
}

// MARK: - 毛玻璃背景

/// 用 UIVisualEffectView 包一层：SwiftUI 的 .ultraThinMaterial 在 iOS 15 的部分
/// 场景下不生效（项目既有多处踩过），这里直接走 UIKit 保证一致。
private struct VisualBlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        let v = UIVisualEffectView(effect: UIBlurEffect(style: style))
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}
