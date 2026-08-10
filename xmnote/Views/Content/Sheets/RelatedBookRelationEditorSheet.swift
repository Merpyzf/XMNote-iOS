/**
 * [INPUT]: 依赖 RelatedBookRelationDraft、BookPickerView、XMBookCover 与外部异步保存闭包
 * [OUTPUT]: 对外提供 RelatedBookRelationEditorSheet，编辑相关书籍关系且保存前仅修改本地草稿
 * [POS]: Content/Sheets 的业务 Sheet，被阅读日历与单书工作台共同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 相关书籍关系编辑面板；分类固定遵循 Android 的“书籍”语义，选书确认前不写入数据库。
struct RelatedBookRelationEditorSheet: View {
    let isSaving: Bool
    let onSave: (RelatedBookRelationDraft) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RelatedBookRelationDraft
    @State private var isBookPickerPresented = false
    @State private var errorMessage: String?

    /// 以现有关系恢复本地编辑草稿，保存前不修改 Repository 数据。
    init(
        draft: RelatedBookRelationDraft,
        isSaving: Bool,
        onSave: @escaping (RelatedBookRelationDraft) async throws -> Void
    ) {
        self.isSaving = isSaving
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("关联书籍") {
                    Button {
                        isBookPickerPresented = true
                    } label: {
                        HStack(spacing: Spacing.base) {
                            XMBookCover.fixedWidth(
                                42,
                                urlString: draft.contentBook.coverURL,
                                border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                            )
                            VStack(alignment: .leading, spacing: Spacing.compact) {
                                Text(draft.contentBook.title)
                                    .font(AppTypography.subheadlineMedium)
                                    .foregroundStyle(Color.textPrimary)
                                if !draft.contentBook.author.isEmpty {
                                    Text(draft.contentBook.author)
                                        .font(AppTypography.caption)
                                        .foregroundStyle(Color.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(AppTypography.captionMedium)
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.feedbackError)
                }
            }
            .navigationTitle("编辑关联书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .sheet(isPresented: $isBookPickerPresented) {
            BookPickerView(
                configuration: BookPickerConfiguration(
                    title: "选择关联书籍",
                    scope: .local,
                    selectionMode: .single,
                    preselectedBooks: [draft.contentBook]
                )
            ) { result in
                if case .single(.local(let book)) = result {
                    draft.contentBook = book
                }
                isBookPickerPresented = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 在主 Actor 上提交草稿；异步失败保留 Sheet 现场并展示原因。
    private func save() async {
        do {
            try await onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
