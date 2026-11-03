import SwiftUI

// MARK: - 密码输入框（小眼睛 + 确定/取消 + 结果反馈）
//
// 2026-11-03 新增。用户两次点名要求（原话）：
//   「这个界面之前我就和你说过，密码后面要有小眼睛，还有输入完密码要有，
//     确定和取消，点击确定要有提示登录成功还是失败的样式」
//
// 之前两处（中转站后台 / 路由器）用的是裸 `SecureField`：
//   · 没有小眼睛 —— 打错了看不见，只能全删重打
//   · 输完没有确定/取消 —— 不知道该干嘛，也不知道点哪生效
//   · 点完没有任何样式反馈 —— 成功失败都静默，用户只能猜
//
// 这里把三件事一起解决，并且做成共用组件，两个页面长相一致。
//
// 兼容性：项目最低支持到 iOS 15（见 RelayAdminView 里关于 ToolbarContentBuilder
// 不支持 `if` 的注释），所以这里不用 iOS 16+ 的 API（如 `.scrollDismissesKeyboard`、
// `ContentUnavailableView` 等），全部走 iOS 15 可用的写法。

/// 密码输入框：右侧一个小眼睛，点一下在「明文/圆点」之间切换。
///
/// 2026-11-03 实现说明（第一版踩过坑，这里记下来）：
/// 最初用 ZStack 把 TextField 和 SecureField 叠在一起，只切 opacity。
/// 问题是不可见的那层**仍然参与布局和命中测试**，而且切层后输入焦点丢失、
/// 键盘会直接收起来——用户点一下小眼睛就得重新点输入框，很难用。
/// 现在改成按状态**只渲染一层**：切换时会重建控件（键盘可能闪一下），
/// 但换来的是「点了就能继续打字」，这才是正常手感。
struct SecretInputField: View {
    @Binding var text: String
    @Binding var revealed: Bool
    var placeholder: String = ""

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)

            // 小眼睛：无内容时也显示（灰一点），避免用户以为这里没功能
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(revealed ? .blue : .secondary)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(revealed ? "隐藏密码" : "显示密码")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 确定 / 取消 两个按钮。
///
/// 取消的语义按场景不同（清空输入 / 关闭页面），所以由调用方传闭包，
/// 这里只管长相和禁用逻辑。
struct ConfirmCancelRow: View {
    var confirmTitle: String = "确定"
    var cancelTitle: String = "取消"
    var canConfirm: Bool
    var busy: Bool = false
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Text(cancelTitle)
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundColor(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(busy)

            Button(action: onConfirm) {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView()
                            .scaleEffect(0.75)
                            .tint(.white)
                    }
                    Text(confirmTitle)
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(canConfirm && !busy ? Color.blue : Color.secondary.opacity(0.25))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canConfirm || busy)
        }
    }
}

/// 一行「成功 / 失败」的样式化反馈。
///
/// 用户原话「点击确定要有提示登录成功还是失败的样式」——
/// 所以要的不只是一句话，是**一眼能分辨的样式**：绿勾/红叉 + 色块底。
struct InlineResultBanner: View {
    enum Kind { case success, failure, info }
    var kind: Kind
    var text: String

    private var tint: Color {
        switch kind {
        case .success: return .green
        case .failure: return .red
        case .info:    return .blue
        }
    }

    private var icon: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info:    return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tint)
                .padding(.top, 1)
            Text(text)
                .font(.footnote)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
