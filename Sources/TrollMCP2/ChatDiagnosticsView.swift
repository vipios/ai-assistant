import SwiftUI
// UIDevice（报告里带机型/iOS 版本）在 UIKit；显式引入，理由同 RouterControlView
import UIKit

// MARK: - 聊天诊断页
//
// 2026-11-03 新增。用户原话：
//   「探针已经加上了，那就让探针自动获取出问题了他就自动返回日志让你查看，
//     这样，就能精确锁定位置，而不是在这猜」
//
// 这个页面就是那个「让你查看」的出口。它不要求用户懂技术，
// 只回答三个问题：
//   ① 最近这些请求，哪些正常结束了、哪些中途没了
//   ② 每次「没了」的时候，系统当时认为是什么原因
//   ③ 崩溃前最后在做哪一步（面包屑）
//
// 全部中文，没有裸英文错误码堆砌。
struct ChatDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var diag = ChatDiagnostics.shared
    @State private var tab = 0
    @State private var breadcrumb = ""
    @State private var showClearConfirm = false
    @State private var copied = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        CompatNav {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                VStack(spacing: 0) {
                    // 分段器：请求列表 / 崩溃现场
                    Picker("", selection: $tab) {
                        Text("请求记录").tag(0)
                        Text("崩溃现场").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                    if tab == 0 {
                        requestList
                    } else {
                        crashView
                    }
                }
            }
            .navigationTitle("聊天诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }.font(.footnote)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        // 一键复制全部 —— 用户要把日志发给我时不用手抄
                        UIPasteboard.general.string = fullReport()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .onAppear {
                breadcrumb = CrashBreadcrumb.shared.read()
            }
            .confirmationDialog("清空诊断记录？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    diag.clear()
                    CrashBreadcrumb.shared.clear()
                    breadcrumb = ""
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删本地记录，不影响聊天内容。")
            }
        }
    }

    // MARK: 请求记录

    private var requestList: some View {
        Group {
            if diag.records.isEmpty {
                emptyState
            } else {
                List {
                    if diag.abnormalCount > 0 {
                        Section {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(.orange)
                                Text("最近 50 次里有 \(diag.abnormalCount) 次是「没正常结束」的，已经在下面标出来了。")
                                    .font(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    Section(header: Text("最近 \(min(diag.records.count, 50)) 次请求")) {
                        ForEach(diag.recent(50)) { r in
                            row(r)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    private func row(_ r: ChatTurnRecord) -> some View {
        let o = r.outcomeEnum
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                // 状态点：绿色正常、橙色异常、灰色手动停
                Circle()
                    .fill(dotColor(o))
                    .frame(width: 7, height: 7)
                Text(o.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(o.isAbnormal ? .primary : .secondary)
                Spacer(minLength: 0)
                Text(Self.timeFormatter.string(from: r.at))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if !r.modelName.isEmpty {
                Text(r.modelName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if !r.reason.isEmpty {
                Text(r.reason)
                    .font(.footnote)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !r.detail.isEmpty {
                Text(r.detail)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
    }

    private func dotColor(_ o: ChatTurnOutcome) -> Color {
        switch o {
        case .success: return .green
        case .stopped: return .secondary
        default:       return .orange
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.6))
            Text("还没有记录")
                .font(.headline)
            Text("每次聊天结束都会自动记一条。\n如果 AI 中途停下，这里会写明原因。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 崩溃现场

    private var crashView: some View {
        Group {
            if breadcrumb.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("还没有现场记录")
                        .font(.headline)
                    Text("App 会在关键步骤自动留痕。\n万一闪退，下次打开这里就能看到崩之前最后在做什么。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        InlineResultBanner(
                            kind: .info,
                            text: "下面是 App 自动留下的时间线（最新的在最下面）。最后几行就是出问题前正在做的事。")

                        Text(breadcrumb)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    // MARK: 汇总文本（复制给我用）

    private func fullReport() -> String {
        let info = Bundle.main.infoDictionary
        var out = "# 聊天诊断报告\n"
        out += "版本: \(info?["CFBundleShortVersionString"] as? String ?? "?")(\(info?["CFBundleVersion"] as? String ?? "?"))\n"
        out += "设备: \(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)\n"
        out += "时间: \(Self.timeFormatter.string(from: Date()))\n\n"

        out += "## 请求记录（最近 50）\n"
        for r in diag.recent(50) {
            out += "[\(Self.timeFormatter.string(from: r.at))] \(r.modelName) | \(r.outcomeEnum.label)"
            if !r.reason.isEmpty { out += " | \(r.reason)" }
            if !r.detail.isEmpty { out += " | \(r.detail)" }
            out += "\n"
        }
        out += "\n## 崩溃现场时间线\n"
        out += breadcrumb.isEmpty ? "(空)\n" : breadcrumb
        return out
    }
}
