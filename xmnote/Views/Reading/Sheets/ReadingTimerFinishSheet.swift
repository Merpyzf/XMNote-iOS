import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖应用级 ReadingTimerCoordinator 提供本次计时与保存状态，依赖 BookPickerView 选择目标书籍，依赖 ReadingTimerFinishDraft 输出结束确认字段
 * [OUTPUT]: 对外提供 ReadingTimerFinishSheet 与 ReadingTimerFinishDraft，承接停止后的保存确认交互
 * [POS]: Reading/Sheets 业务弹层，负责阅读计时结束后的书籍、时间、位置、感悟、读完状态与继续计时闭环
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 结束确认 Sheet 输出草稿，供父级在长时长确认后提交给 Coordinator。
struct ReadingTimerFinishDraft {
    let targetBookId: Int64
    let startAt: Date
    let endAt: Date
    let didEditTimeRange: Bool
    let position: Double?
    let insight: String
    let markReadDone: Bool
}

/// 阅读计时结束确认弹层，保持保存前的必要字段补充，不把表单堆回主计时页。
struct ReadingTimerFinishSheet: View {
    @Bindable var coordinator: ReadingTimerCoordinator
    let onSave: (ReadingTimerFinishDraft) -> Void
    let onDiscard: () -> Void
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var positionText = ""
    @State private var insight = ""
    @State private var markReadDone = false
    @State private var pendingLongDurationDraft: ReadingTimerFinishDraft?
    @State private var selectedBook: BookPickerBook?
    @State private var startAt = Date()
    @State private var endAt = Date()
    @State private var originalStartAt = Date()
    @State private var originalEndAt = Date()
    @State private var shouldPresentBookPicker = false

    private var book: ReadingTimerBookContext? {
        coordinator.bookContext
    }

    private var targetBookId: Int64? {
        selectedBook?.id ?? book?.id
    }

    private var didEditTimeRange: Bool {
        abs(startAt.timeIntervalSince(originalStartAt)) >= 1
            || abs(endAt.timeIntervalSince(originalEndAt)) >= 1
    }

    private var effectiveElapsedSeconds: Int64 {
        if didEditTimeRange {
            return max(0, Int64(endAt.timeIntervalSince(startAt)))
        }
        return coordinator.elapsedSeconds
    }

    private var isTimeRangeValid: Bool {
        endAt > startAt && endAt <= Date()
    }

    private var canContinue: Bool {
        guard let session = coordinator.activeSession,
              session.status == .stoppedPendingSave else { return false }
        return session.countdownSeconds == 0 || session.elapsedSeconds < session.countdownSeconds
    }

    private var positionValue: Double? {
        let trimmed = positionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    var body: some View {
        XMSheetScaffold(
            title: "保存阅读记录",
            onClose: {
                guard !coordinator.isWriting else { return }
                dismiss()
            },
            bottomBar: {
                finishActionBar
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                XMSettingsSection("本次记录") {
                    XMSettingsGroup {
                        VStack(alignment: .leading, spacing: Spacing.cozy) {
                            Text(ReadDurationFormatter.format(seconds: effectiveElapsedSeconds))
                                .font(AppTypography.title3Semibold)
                                .foregroundStyle(Color.textPrimary)
                                .contentTransition(.numericText())

                            Button {
                                shouldPresentBookPicker = true
                            } label: {
                                HStack(spacing: Spacing.cozy) {
                                    Text(selectedBook?.title ?? book?.name ?? "选择书籍")
                                        .font(AppTypography.bodyMedium)
                                        .foregroundStyle(Color.textPrimary)
                                        .lineLimit(2)
                                    Spacer(minLength: Spacing.base)
                                    Image(systemName: "chevron.right")
                                        .font(AppTypography.caption)
                                        .foregroundStyle(Color.textSecondary)
                                }
                                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if let bookErrorMessage {
                                fieldError(bookErrorMessage)
                            }
                        }
                    }
                }

                XMSettingsSection("阅读时间") {
                    XMSettingsGroup {
                        DatePicker(
                            "开始",
                            selection: $startAt,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)

                        XMSettingsDivider()

                        DatePicker(
                            "结束",
                            selection: $endAt,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)

                        if let timeErrorMessage {
                            XMSettingsDivider()
                            fieldError(timeErrorMessage)
                                .padding(.vertical, Spacing.cozy)
                        }
                    }
                }

                XMSettingsSection("阅读位置") {
                    XMSettingsGroup(presentation: positionErrorMessage == nil ? .singleItem : .grouped) {
                        TextField(positionPlaceholder, text: $positionText)
                            .font(AppTypography.body)
                            .keyboardType(positionKeyboardType)
                            .frame(minHeight: XMSettingsPageLayout.inputMinHeight)

                        if let positionErrorMessage {
                            XMSettingsDivider()
                            fieldError(positionErrorMessage)
                                .padding(.vertical, Spacing.cozy)
                        }
                    }
                }

                XMSettingsSection("本次感悟") {
                    XMSettingsGroup {
                        insightEditor
                    }
                }

                XMSettingsSection("完成状态") {
                    XMSettingsGroup(presentation: .singleItem) {
                        XMSettingsToggleRow(title: "标记为读完", isOn: $markReadDone)
                    }
                }

                if let remainingCoordinatorError {
                    XMInlineStatusBanner(remainingCoordinatorError, tone: .error)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .disabled(coordinator.isWriting)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.surfacePage)
        .interactiveDismissDisabled(coordinator.isWriting)
        .sheet(isPresented: $shouldPresentBookPicker) {
            BookPickerView(
                configuration: BookPickerConfiguration(
                    title: "选择记录书籍",
                    scope: .local,
                    selectionMode: .single,
                    allowsCreationFlow: true,
                    creationAction: .nestedSearchPage,
                    preselectedBooks: selectedBook.map { [$0] } ?? []
                )
            ) { result in
                if case .single(.local(let selected)) = result,
                   selected.id != selectedBook?.id {
                    selectedBook = selected
                    positionText = ""
                }
                shouldPresentBookPicker = false
            }
        }
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
            initializeDraftIfNeeded()
        }
        .onChange(of: selectedBook?.id) { _, _ in
            clearCoordinatorError("请选择记录书籍")
        }
        .onChange(of: startAt) { _, _ in
            clearCoordinatorError("阅读时间范围不正确")
        }
        .onChange(of: endAt) { _, _ in
            clearCoordinatorError("阅读时间范围不正确")
        }
        .onChange(of: positionText) { _, _ in
            clearCoordinatorError("阅读位置格式不正确")
        }
    }

    private var finishActionBar: some View {
        VStack(spacing: Spacing.cozy) {
            Button {
                submit()
            } label: {
                HStack(spacing: Spacing.cozy) {
                    Spacer(minLength: 0)
                    if coordinator.isWriting {
                        LoadingStateView(style: .inline)
                            .controlSize(.small)
                    } else {
                        Text("保存记录")
                            .font(AppTypography.bodyMedium)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                .foregroundStyle(.white)
                .background(
                    Capsule()
                        .fill(Color.appTint)
                )
            }
            .buttonStyle(.plain)
            .disabled(coordinator.isWriting)

            if canContinue {
                Button {
                    onContinue()
                } label: {
                    Text("继续计时")
                        .font(AppTypography.bodyMedium)
                        .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget)
                        .foregroundStyle(Color.textPrimary)
                        .background(
                            Capsule()
                                .fill(Color.surfaceCard)
                        )
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isWriting)
            }

            Button(role: .destructive) {
                onDiscard()
            } label: {
                Text("放弃本次")
                    .font(AppTypography.bodyMedium)
                    .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget)
                    .foregroundStyle(Color.feedbackError)
                    .background(
                        Capsule()
                            .fill(Color.surfaceCard)
                    )
            }
            .buttonStyle(.plain)
            .disabled(coordinator.isWriting)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.cozy)
        .background(Color.surfacePage)
    }

    private var positionPlaceholder: String {
        let positionUnit = selectedBook?.positionUnit ?? book?.positionUnit
        switch BookEntryProgressUnit(rawValue: positionUnit ?? -1) {
        case .progress?:
            return "输入 0 - 100"
        case .position?:
            return "输入位置"
        case .pagination?:
            return "输入页码"
        case nil:
            return "输入阅读位置"
        }
    }

    private var positionKeyboardType: UIKeyboardType {
        let positionUnit = selectedBook?.positionUnit ?? book?.positionUnit
        return positionUnit == BookEntryProgressUnit.progress.rawValue ? .decimalPad : .numberPad
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

    private var bookErrorMessage: String? {
        coordinator.errorMessage == "请选择记录书籍" ? coordinator.errorMessage : nil
    }

    private var timeErrorMessage: String? {
        if !isTimeRangeValid {
            return "结束时间必须晚于开始时间，且不能超过当前时间"
        }
        if coordinator.errorMessage == "阅读时间范围不正确"
            || coordinator.errorMessage == "阅读时长为 0，请继续计时或放弃本次记录" {
            return coordinator.errorMessage
        }
        return nil
    }

    private var positionErrorMessage: String? {
        let trimmed = positionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, positionValue == nil {
            return "阅读位置格式不正确"
        }
        return coordinator.errorMessage == "阅读位置格式不正确" ? coordinator.errorMessage : nil
    }

    private var remainingCoordinatorError: String? {
        guard let message = coordinator.errorMessage else { return nil }
        let fieldMessages = [bookErrorMessage, timeErrorMessage, positionErrorMessage]
        return fieldMessages.contains(message) ? nil : message
    }

    private func fieldError(_ message: String) -> some View {
        Text(message)
            .font(SettingsTypography.rowDescription)
            .foregroundStyle(Color.feedbackError)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("错误：\(message)")
    }

    private func clearCoordinatorError(_ message: String) {
        guard coordinator.errorMessage == message else { return }
        coordinator.errorMessage = nil
    }

    private func submit() {
        coordinator.errorMessage = nil
        guard let targetBookId else {
            coordinator.errorMessage = "请选择记录书籍"
            return
        }
        guard isTimeRangeValid else {
            coordinator.errorMessage = "阅读时间范围不正确"
            return
        }
        guard effectiveElapsedSeconds > 0 else {
            coordinator.errorMessage = "阅读时长为 0，请继续计时或放弃本次记录"
            return
        }
        if !positionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           positionValue == nil {
            coordinator.errorMessage = "阅读位置格式不正确"
            return
        }
        let draft = ReadingTimerFinishDraft(
            targetBookId: targetBookId,
            startAt: startAt,
            endAt: endAt,
            didEditTimeRange: didEditTimeRange,
            position: positionValue,
            insight: insight,
            markReadDone: markReadDone
        )
        if effectiveElapsedSeconds > 8 * 60 * 60 {
            pendingLongDurationDraft = draft
        } else {
            onSave(draft)
        }
    }

    private var longDurationDescriptor: XMSystemAlertDescriptor? {
        guard let pendingLongDurationDraft else { return nil }
        return XMSystemAlertDescriptor(
            title: "确认保存长时长记录",
            message: "这次阅读记录为 \(ReadDurationFormatter.format(seconds: pendingLongDurationDraft.endAt.timeIntervalSince(pendingLongDurationDraft.startAt) >= 1 && pendingLongDurationDraft.didEditTimeRange ? Int64(pendingLongDurationDraft.endAt.timeIntervalSince(pendingLongDurationDraft.startAt)) : coordinator.elapsedSeconds))，是否保存？",
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

    private func formattedPosition(_ position: Double) -> String {
        if position.rounded() == position {
            return String(Int64(position))
        }
        return String(position)
    }

    /// 从当前待保存会话初始化书籍与时间，避免 Sheet 重绘覆盖用户已经编辑的草稿。
    private func initializeDraftIfNeeded() {
        guard selectedBook == nil, let session = coordinator.activeSession else { return }
        let initialStart = session.startTime ?? Date().addingTimeInterval(-Double(session.elapsedSeconds))
        let initialEnd = session.endTime ?? Date()
        startAt = initialStart
        endAt = initialEnd
        originalStartAt = initialStart
        originalEndAt = initialEnd
        selectedBook = BookPickerBook(
            id: session.book.id,
            title: session.book.name,
            author: session.book.author,
            coverURL: session.book.coverURL,
            positionUnit: session.book.positionUnit,
            totalPosition: session.book.totalPosition,
            totalPagination: session.book.totalPagination
        )
        if positionText.isEmpty, session.book.readPosition > 0 {
            positionText = formattedPosition(session.book.readPosition)
        }
    }
}
