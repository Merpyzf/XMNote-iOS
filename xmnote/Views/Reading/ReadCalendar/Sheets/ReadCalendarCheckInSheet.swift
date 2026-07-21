/**
 * [INPUT]: 依赖 BookPickerView 选择有效本地书籍，依赖 CheckInAmountLevel 与写入回调
 * [OUTPUT]: 对外提供 ReadCalendarCheckInSheet，承接当日打卡的书籍与阅读量选择
 * [POS]: ReadCalendar 业务 Sheet，仅组织输入与即时写入反馈
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 当日打卡输入页；保存期间即时禁用入口，失败由页面保留现场并展示错误。
struct ReadCalendarCheckInSheet: View {
    let date: Date
    let recordID: Int64?
    let initialBook: ReadCalendarDayBook?
    let isSaving: Bool
    let onSave: (Int64, Int) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedBook: BookPickerBook?
    @State private var amount = 1
    @State private var isBookPickerPresented = false
    @State private var errorMessage: String?

    /// 注入新增或编辑上下文；recordID 为空表示新增/同日覆盖。
    init(
        date: Date,
        recordID: Int64? = nil,
        initialBook: ReadCalendarDayBook?,
        initialAmount: Int = 1,
        isSaving: Bool,
        onSave: @escaping (Int64, Int) async throws -> Void
    ) {
        self.date = date
        self.recordID = recordID
        self.initialBook = initialBook
        self.isSaving = isSaving
        self.onSave = onSave
        _amount = State(initialValue: initialAmount)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("书籍") {
                    Button {
                        isBookPickerPresented = true
                    } label: {
                        HStack(spacing: Spacing.base) {
                            if let selectedBook {
                                XMBookCover.fixedWidth(
                                    34,
                                    urlString: selectedBook.coverURL,
                                    border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                                )
                                VStack(alignment: .leading, spacing: Spacing.tiny) {
                                    Text(selectedBook.title)
                                        .font(AppTypography.body)
                                        .foregroundStyle(Color.textPrimary)
                                    if !selectedBook.author.isEmpty {
                                        Text(selectedBook.author)
                                            .font(AppTypography.caption)
                                            .foregroundStyle(Color.textSecondary)
                                    }
                                }
                            } else {
                                Label("选择书籍", systemImage: "books.vertical")
                                    .foregroundStyle(Color.textPrimary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    Picker("阅读量", selection: $amount) {
                        ForEach(1...4, id: \.self) { value in
                            Text(CheckInAmountLevel(amount: Int64(value)).label).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("阅读量")
                } footer: {
                    Text(Self.dateFormatter.string(from: date))
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(AppTypography.footnote)
                            .foregroundStyle(Color.feedbackError)
                    }
                }
            }
            .navigationTitle(recordID == nil ? "阅读打卡" : "编辑打卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                    }
                    .disabled(selectedBook == nil || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $isBookPickerPresented) {
            BookPickerView(
                configuration: BookPickerConfiguration(
                    title: "选择打卡书籍",
                    scope: .local,
                    selectionMode: .single,
                    allowsCreationFlow: false,
                    preselectedBooks: selectedBook.map { [$0] } ?? []
                )
            ) { result in
                if case .single(.local(let book)) = result {
                    selectedBook = book
                }
                isBookPickerPresented = false
            }
        }
        .onAppear {
            guard selectedBook == nil, let initialBook else { return }
            selectedBook = BookPickerBook(
                id: initialBook.id,
                title: initialBook.name,
                author: "",
                coverURL: initialBook.coverURL
            )
        }
    }

    /// 在结构化任务中执行写入；失败保留 Sheet 现场，成功由父页刷新后关闭。
    private func save() {
        guard let selectedBook else { return }
        errorMessage = nil
        Task {
            do {
                try await onSave(selectedBook.id, amount)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}
