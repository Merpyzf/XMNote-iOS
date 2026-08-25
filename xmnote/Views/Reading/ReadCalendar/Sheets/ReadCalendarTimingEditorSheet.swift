/**
 * [INPUT]: 依赖 TimelineReadTimingEvent、ReadCalendarTimingDraft、BookPickerView 与异步保存回调
 * [OUTPUT]: 对外提供 ReadCalendarTimingEditorSheet，编辑精确/模糊阅读时间、进度、感想与读完状态
 * [POS]: ReadCalendar 业务 Sheet，对齐 Android 已完成计时记录编辑能力
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 已完成计时记录编辑页；超过八小时会二次确认，保存期间禁止重复提交与交互关闭。
struct ReadCalendarTimingEditorSheet: View {
    let recordID: Int64
    let initialBook: ReadCalendarDayBook
    let event: TimelineReadTimingEvent
    let isSaving: Bool
    let onSave: (ReadCalendarTimingDraft) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedBook: BookPickerBook
    @State private var kind: ReadCalendarTimingKind
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var fuzzyDate: Date
    @State private var fuzzyMinutes: Int
    @State private var positionText: String
    @State private var insight: String
    @State private var shouldMarkReadDone = false
    @State private var isBookPickerPresented = false
    @State private var errorMessage: String?
    @State private var showLongDurationConfirmation = false

    /// 从时间线原始记录恢复编辑现场，跨日精确记录不会被当日切片值覆盖。
    init(
        recordID: Int64,
        initialBook: ReadCalendarDayBook,
        event: TimelineReadTimingEvent,
        isSaving: Bool,
        onSave: @escaping (ReadCalendarTimingDraft) async throws -> Void
    ) {
        self.recordID = recordID
        self.initialBook = initialBook
        self.event = event
        self.isSaving = isSaving
        self.onSave = onSave

        let now = Date()
        let resolvedStart = event.startTime > 0
            ? Date(timeIntervalSince1970: Double(event.startTime) / 1_000)
            : now.addingTimeInterval(-Double(max(60, event.elapsedSeconds)))
        let resolvedEnd = event.endTime > event.startTime
            ? Date(timeIntervalSince1970: Double(event.endTime) / 1_000)
            : resolvedStart.addingTimeInterval(Double(max(60, event.elapsedSeconds)))
        let resolvedFuzzy = event.fuzzyReadDate > 0
            ? Date(timeIntervalSince1970: Double(event.fuzzyReadDate) / 1_000)
            : resolvedStart

        _selectedBook = State(initialValue: BookPickerBook(
            id: initialBook.id,
            title: initialBook.name,
            author: "",
            coverURL: initialBook.coverURL
        ))
        _kind = State(initialValue: event.fuzzyReadDate == 0 ? .accurate : .fuzzy)
        _startDate = State(initialValue: resolvedStart)
        _endDate = State(initialValue: resolvedEnd)
        _fuzzyDate = State(initialValue: resolvedFuzzy)
        _fuzzyMinutes = State(initialValue: max(1, Int((event.elapsedSeconds + 59) / 60)))
        _positionText = State(initialValue: event.position > 0 ? Self.positionFormatter.string(from: NSNumber(value: event.position)) ?? "" : "")
        _insight = State(initialValue: event.insight)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("书籍") {
                    Button {
                        isBookPickerPresented = true
                    } label: {
                        HStack(spacing: Spacing.base) {
                            XMBookCover.fixedWidth(
                                34,
                                urlString: selectedBook.coverURL,
                                border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                            )
                            Text(selectedBook.title)
                                .font(AppTypography.body)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section("时间类型") {
                    Picker("时间类型", selection: $kind) {
                        Text("精确时间").tag(ReadCalendarTimingKind.accurate)
                        Text("模糊时间").tag(ReadCalendarTimingKind.fuzzy)
                    }
                    .pickerStyle(.segmented)
                }

                if kind == .accurate {
                    Section("阅读时间") {
                        DatePicker("开始", selection: $startDate, in: ...Date())
                        DatePicker("结束", selection: $endDate, in: ...Date())
                    }
                } else {
                    Section("阅读时间") {
                        DatePicker("日期", selection: $fuzzyDate, in: ...Date(), displayedComponents: .date)
                        Stepper("时长 \(ReadDurationFormatter.format(seconds: Int64(fuzzyMinutes * 60)))", value: $fuzzyMinutes, in: 1...1_440)
                    }
                }

                Section("阅读进度") {
                    TextField("可选", text: $positionText)
                        .keyboardType(.decimalPad)
                }

                Section("阅读感想") {
                    TextEditor(text: $insight)
                        .frame(minHeight: 96)
                }

                Section {
                    Toggle("同时标记为读完", isOn: $shouldMarkReadDone)
                } footer: {
                    Text("关闭此开关不会删除已有的读完记录")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(AppTypography.footnote)
                            .foregroundStyle(Color.feedbackError)
                    }
                }
            }
            .navigationTitle("编辑阅读时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { validateAndSave() }
                        .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $isBookPickerPresented) {
            BookPickerView(
                configuration: BookPickerConfiguration(
                    title: "选择阅读书籍",
                    scope: .local,
                    selectionMode: .single,
                    allowsCreationFlow: false,
                    preselectedBooks: [selectedBook]
                )
            ) { result in
                if case .single(.local(let book)) = result {
                    selectedBook = book
                }
                isBookPickerPresented = false
            }
        }
        .xmSystemAlert(
            isPresented: $showLongDurationConfirmation,
            descriptor: XMSystemAlertDescriptor(
                title: "确认阅读时长",
                message: "这条记录超过 8 小时，请确认时间范围无误。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "继续保存") { performSave() }
                ]
            )
        )
    }

    /// 校验本地可判断的时间范围；长时记录在系统弹窗确认后再提交 Repository。
    private func validateAndSave() {
        errorMessage = nil
        let seconds = kind == .accurate
            ? Int64(endDate.timeIntervalSince(startDate).rounded(.down))
            : Int64(fuzzyMinutes * 60)
        guard seconds > 0 else {
            errorMessage = "阅读开始时间必须早于结束时间，且阅读时长不能为零"
            return
        }
        if seconds > 8 * 3_600 {
            showLongDurationConfirmation = true
        } else {
            performSave()
        }
    }

    /// 组装完整草稿并执行异步写入；失败保留编辑现场。
    private func performSave() {
        let elapsed = kind == .accurate
            ? Int64(endDate.timeIntervalSince(startDate).rounded(.down))
            : Int64(fuzzyMinutes * 60)
        let draft = ReadCalendarTimingDraft(
            recordID: recordID,
            bookID: selectedBook.id,
            kind: kind,
            startDate: kind == .accurate ? startDate : nil,
            endDate: kind == .accurate ? endDate : nil,
            fuzzyDate: kind == .fuzzy ? fuzzyDate : nil,
            elapsedSeconds: elapsed,
            position: Double(positionText) ?? 0,
            recordedPositionUnit: event.recordedPositionUnit,
            insight: insight,
            shouldMarkReadDone: shouldMarkReadDone
        )
        Task {
            do {
                try await onSave(draft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static let positionFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
