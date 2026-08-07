/**
 * [INPUT]: 依赖 XMRatingBar、LoadingStateView、XMSystemAlert 与 DesignTokens，接收单本书名、当前评分和异步提交闭包
 * [OUTPUT]: 对外提供 XMBookRatingSheet，以单一评分焦点统一承接书评与书籍详情的 0...50 半星交互、即时写入门闩和失败反馈
 * [POS]: UIComponents/Foundation 的跨模块单本评分 Sheet，被 Note 与 Book 生产页面复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 单本书评分 Sheet，以五颗星展示 0...50 业务分值，并在数据库确认写入后自行关闭。
struct XMBookRatingSheet: View {
    let bookTitle: String
    let initialScore: Int64
    let onSubmit: @MainActor (Int64) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var ratingValue: Double
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var submitTask: Task<Void, Never>?

    /// 以 Android 0...50 分值初始化半星选择，越界历史值仅在界面层安全收敛。
    init(
        bookTitle: String,
        initialScore: Int64,
        onSubmit: @escaping @MainActor (Int64) async throws -> Void
    ) {
        self.bookTitle = bookTitle
        self.initialScore = min(max(initialScore, 0), 50)
        self.onSubmit = onSubmit
        _ratingValue = State(initialValue: Double(min(max(initialScore, 0), 50)) / 10.0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.section) {
                    Text(bookTitle)
                        .font(AppTypography.headline)
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .frame(maxWidth: .infinity)

                    ratingControl

                    if ratingValue > 0 {
                        Button("清除评分") {
                            ratingValue = 0
                        }
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .buttonStyle(.plain)
                        .frame(minHeight: Spacing.actionReserved)
                        .disabled(isSubmitting)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .move(edge: .top))
                        )
                    }

                    Text("支持半星评分")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if isSubmitting {
                        LoadingStateView("正在保存评分…", style: .inline)
                            .frame(maxWidth: .infinity)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.section)
            }
            .background(Color.surfaceSheet.ignoresSafeArea())
            .navigationTitle("书籍评分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        submitRating()
                    }
                    .disabled(!hasChanges || isSubmitting)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.18),
                value: ratingValue > 0
            )
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.24),
                value: isSubmitting
            )
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        .xmSystemAlert(
            isPresented: errorIsPresented,
            descriptor: errorDescriptor
        )
        .onDisappear {
            submitTask?.cancel()
            submitTask = nil
        }
    }

    private var normalizedScore: Int64 {
        min(max(Int64((ratingValue * 10).rounded()), 0), 50)
    }

    @ViewBuilder
    private var ratingControl: some View {
        VStack(spacing: Spacing.base) {
            ratingBar
            ratingValueLabel
        }
        .frame(maxWidth: .infinity)
    }

    private var ratingBar: some View {
        XMRatingBar(
            value: $ratingValue,
            preset: dynamicTypeSize.isAccessibilitySize ? .form : .dialog,
            step: .half,
            isIndicator: false
        )
        .disabled(isSubmitting)
    }

    private var ratingValueLabel: some View {
        Text(ratingTitle)
            .font(AppTypography.bodyMedium)
            .foregroundStyle(ratingValue > 0 ? Color.textPrimary : Color.textSecondary)
            .contentTransition(.numericText())
    }

    private var hasChanges: Bool {
        normalizedScore != initialScore
    }

    private var ratingTitle: String {
        guard ratingValue > 0 else { return "未评分" }
        let value = ratingValue.formatted(
            .number.precision(.fractionLength(1))
        )
        return "\(value) 星"
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                guard !isPresented else { return }
                errorMessage = nil
            }
        )
    }

    private var errorDescriptor: XMSystemAlertDescriptor? {
        guard let errorMessage else { return nil }
        return XMSystemAlertDescriptor(
            title: "评分未保存",
            message: errorMessage,
            actions: [
                XMSystemAlertAction(title: "好") {
                    self.errorMessage = nil
                }
            ]
        )
    }

    /// 在主线程建立一次可取消写入任务；重复点击由 isSubmitting 门闩阻断，取消时不展示错误。
    private func submitRating() {
        guard hasChanges, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        let score = normalizedScore
        submitTask = Task { @MainActor in
            defer {
                isSubmitting = false
                submitTask = nil
            }
            do {
                try await onSubmit(score)
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    XMBookRatingSheet(bookTitle: "示例书籍", initialScore: 35) { _ in }
}
