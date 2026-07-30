import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 ReadingTimerViewModel 提供本次计时、书籍与保存状态，依赖 ReadingTimerFinishDraft 输出结束确认字段
 * [OUTPUT]: 对外提供 ReadingTimerFinishSheet 与 ReadingTimerFinishDraft，承接停止后的保存确认交互
 * [POS]: Reading/Sheets 业务弹层，负责阅读计时结束后的时长确认、位置、感悟与读完状态补充
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 结束确认 Sheet 输出草稿，供父级在长时长确认后提交给 ViewModel。
struct ReadingTimerFinishDraft {
    let position: Double?
    let insight: String
    let markReadDone: Bool
}

/// 阅读计时结束确认弹层，保持保存前的必要字段补充，不把表单堆回主计时页。
struct ReadingTimerFinishSheet: View {
    @Bindable var viewModel: ReadingTimerViewModel
    let onSave: (ReadingTimerFinishDraft) -> Void
    let onDiscard: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var positionText = ""
    @State private var insight = ""
    @State private var markReadDone = false
    @State private var pendingLongDurationDraft: ReadingTimerFinishDraft?

    private var book: ReadingTimerBookContext? {
        viewModel.bookContext
    }

    private var positionValue: Double? {
        let trimmed = positionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Text(ReadDurationFormatter.format(seconds: viewModel.elapsedSeconds))
                            .font(AppTypography.title3Semibold)
                            .foregroundStyle(Color.textPrimary)
                            .contentTransition(.numericText())

                        if let book {
                            Text(book.name)
                                .font(AppTypography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                        }

                        if let session = viewModel.activeSession {
                            Text(timeRangeText(for: session))
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                    .padding(.vertical, Spacing.micro)
                }

                Section("阅读位置") {
                    TextField(positionPlaceholder, text: $positionText)
                        .keyboardType(positionKeyboardType)
                }

                Section("本次感悟") {
                    insightEditor
                }

                Section {
                    Toggle("标记为读完", isOn: $markReadDone)
                }

                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(AppTypography.footnote)
                            .foregroundStyle(Color.feedbackError)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                finishActionBar
            }
            .navigationTitle("保存阅读记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.surfacePage)
        .xmSystemAlert(
            isPresented: Binding(
                get: { pendingLongDurationDraft != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    pendingLongDurationDraft = nil
                }
            ),
            descriptor: longDurationDescriptor
        )
        .onAppear {
            if positionText.isEmpty, let position = book?.readPosition, position > 0 {
                positionText = formattedPosition(position)
            }
        }
    }

    private var finishActionBar: some View {
        VStack(spacing: Spacing.cozy) {
            Button {
                submit()
            } label: {
                HStack(spacing: Spacing.cozy) {
                    Spacer(minLength: 0)
                    if viewModel.isWriting {
                        LoadingStateView(style: .inline)
                            .controlSize(.small)
                    } else {
                        Text("保存记录")
                            .font(AppTypography.bodyMedium)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Spacing.actionReserved)
                .foregroundStyle(.white)
                .background(
                    Capsule()
                        .fill(Color.brand)
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isWriting)

            Button(role: .destructive) {
                onDiscard()
            } label: {
                Text("放弃本次")
                    .font(AppTypography.bodyMedium)
                    .frame(maxWidth: .infinity, minHeight: Spacing.actionReserved)
                    .foregroundStyle(Color.feedbackError)
                    .background(
                        Capsule()
                            .fill(Color.surfaceCard)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isWriting)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.cozy)
        .background(Color.surfacePage)
    }

    private var positionPlaceholder: String {
        guard let book else { return "输入阅读位置" }
        switch book.resolvedPositionUnit {
        case .progress:
            return "输入 0 - 100"
        case .position:
            return "输入位置"
        case .pagination:
            return "输入页码"
        }
    }

    private var positionKeyboardType: UIKeyboardType {
        guard let book else { return .decimalPad }
        return book.resolvedPositionUnit == .progress ? .decimalPad : .numberPad
    }

    private var insightEditor: some View {
        ZStack(alignment: .topLeading) {
            if insight.isEmpty {
                Text("写一点这次阅读后的想法")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textHint)
                    .padding(.horizontal, Spacing.micro)
                    .padding(.vertical, Spacing.tiny)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $insight)
                .font(AppTypography.body)
                .frame(minHeight: 96)
                .scrollContentBackground(.hidden)
        }
    }

    private func submit() {
        if !positionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           positionValue == nil {
            viewModel.errorMessage = "阅读位置格式不正确"
            return
        }
        let draft = ReadingTimerFinishDraft(
            position: positionValue,
            insight: insight,
            markReadDone: markReadDone
        )
        if viewModel.needsLongDurationConfirmation {
            pendingLongDurationDraft = draft
        } else {
            onSave(draft)
        }
    }

    private var longDurationDescriptor: XMSystemAlertDescriptor? {
        guard let pendingLongDurationDraft else { return nil }
        return XMSystemAlertDescriptor(
            title: "确认保存长时长记录",
            message: "这次阅读记录为 \(ReadDurationFormatter.format(seconds: viewModel.elapsedSeconds))，是否保存？",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) {
                    self.pendingLongDurationDraft = nil
                },
                XMSystemAlertAction(title: "保存") {
                    let draft = pendingLongDurationDraft
                    self.pendingLongDurationDraft = nil
                    onSave(draft)
                }
            ]
        )
    }

    private func timeRangeText(for session: ReadingTimerSession) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        guard let start = session.startTime else { return "待保存" }
        let startText = formatter.string(from: start)
        let endText = session.endTime.map { formatter.string(from: $0) } ?? "现在"
        return "\(startText) - \(endText)"
    }

    private func formattedPosition(_ position: Double) -> String {
        if position.rounded() == position {
            return String(Int64(position))
        }
        return String(position)
    }
}
