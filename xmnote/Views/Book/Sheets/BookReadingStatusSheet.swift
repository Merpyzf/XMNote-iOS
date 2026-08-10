/**
 * [INPUT]: 依赖 BookReadingDetailBook/状态领域模型、XMRatingBar、XMSystemAlert 与状态保存/删除异步闭包
 * [OUTPUT]: 对外提供 BookReadingStatusSheet，完成阅读状态新增、精确编辑、读完评分/次数及确认删除
 * [POS]: Views/Book/Sheets 阅读详情业务 Sheet，数据库事务与庆祝判定由 ViewModel/Repository 承担
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 阅读状态业务 Sheet；新增态不预选，编辑态只编辑用户点选的真实历史记录。
struct BookReadingStatusSheet: View {
    let isSaving: Bool
    let onSave: (BookReadingStatusInput) async throws -> Void
    let onDelete: ((Int64) async throws -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedStatusID: Int64?
    @State private var changedAt: Date
    @State private var ratingValue: Double
    @State private var errorMessage: String?
    @State private var isDeleteConfirmationPresented = false
    private let options: [BookReadingStatusOption]
    private let editingItem: BookReadingStatusHistoryItem?
    private let readDoneCount: Int

    /// 注入新增或编辑上下文；状态日期统一显示并提交到分钟精度。
    init(
        book: BookReadingDetailBook,
        options: [BookReadingStatusOption],
        editingItem: BookReadingStatusHistoryItem?,
        isSaving: Bool,
        onSave: @escaping (BookReadingStatusInput) async throws -> Void,
        onDelete: ((Int64) async throws -> Void)? = nil
    ) {
        self.options = options
        self.editingItem = editingItem
        self.readDoneCount = book.readDoneCount
        self.isSaving = isSaving
        self.onSave = onSave
        self.onDelete = onDelete
        _selectedStatusID = State(initialValue: editingItem?.statusID)
        let initialDate = editingItem.map { Date(timeIntervalSince1970: Double($0.changedAt) / 1_000) } ?? Date()
        _changedAt = State(initialValue: initialDate)
        _ratingValue = State(initialValue: Double(book.score) / 10)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读状态") {
                    ForEach(options) { option in
                        Button {
                            selectedStatusID = selectedStatusID == option.id ? nil : option.id
                        } label: {
                            HStack {
                                Label(option.title, systemImage: statusSymbol(option.id))
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                if selectedStatusID == option.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(statusColor(option.id))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if selectedStatusID != nil {
                    if selectedStatusID == 3 {
                        Section("读完") {
                            LabeledContent("评分") {
                                XMRatingBar(value: $ratingValue, preset: .form)
                            }
                            LabeledContent("读完次数") {
                                Text(readDoneCountLabel)
                                    .font(AppTypography.subheadlineMedium)
                                    .padding(.horizontal, Spacing.cozy)
                                    .padding(.vertical, Spacing.compact)
                                    .background(Color.surfaceNested, in: Capsule())
                            }
                        }
                    }

                    Section("状态时间") {
                        DatePicker(
                            "变更时间",
                            selection: $changedAt,
                            in: ...Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(AppTypography.footnote)
                            .foregroundStyle(Color.feedbackError)
                    }
                }

                if editingItem?.recordID != nil, onDelete != nil {
                    Section {
                        Button("删除这条状态", role: .destructive) {
                            isDeleteConfirmationPresented = true
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .navigationTitle(editingItem == nil ? "新增阅读状态" : "编辑阅读状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await save() }
                    }
                    .disabled(selectedStatusID == nil || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(isSaving)
        .xmSystemAlert(
            isPresented: $isDeleteConfirmationPresented,
            descriptor: deleteConfirmationDescriptor
        )
    }

    private var readDoneCountLabel: String {
        let count = editingItem?.statusID == 3 ? readDoneCount : readDoneCount + 1
        return count <= 1 ? "第一次读完" : "第 \(count) 次读完"
    }

    private var deleteConfirmationDescriptor: XMSystemAlertDescriptor? {
        guard let recordID = editingItem?.recordID, onDelete != nil else { return nil }
        return XMSystemAlertDescriptor(
            title: "删除阅读状态？",
            message: "这条状态会从阅读历程和统计中移除。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    Task { await delete(recordID: recordID) }
                }
            ]
        )
    }

    /// 提交状态；父级 ViewModel 负责串行状态事务、独立评分和新增读完庆祝判定。
    private func save() async {
        guard let selectedStatusID else {
            errorMessage = "请选择阅读状态"
            return
        }
        do {
            errorMessage = nil
            try await onSave(
                BookReadingStatusInput(
                    recordID: editingItem?.recordID,
                    statusID: selectedStatusID,
                    changedAt: changedAt,
                    ratingScore: Int64((ratingValue * 10).rounded())
                )
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 删除状态；失败留在 Sheet 内解释，成功后关闭并由观察流刷新页面。
    private func delete(recordID: Int64) async {
        guard let onDelete else { return }
        do {
            errorMessage = nil
            try await onDelete(recordID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func statusSymbol(_ id: Int64) -> String {
        switch id {
        case 1: "heart"
        case 2: "book"
        case 3: "checkmark.circle"
        case 5: "shippingbox"
        default: "xmark.circle"
        }
    }

    private func statusColor(_ id: Int64) -> Color {
        switch id {
        case 1: .statusWish
        case 2: .statusReading
        case 3: .statusDone
        case 5: .statusOnHold
        default: .statusAbandoned
        }
    }
}
