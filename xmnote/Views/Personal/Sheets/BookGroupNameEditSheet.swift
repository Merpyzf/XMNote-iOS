/**
 * [INPUT]: 依赖 BookGroupManagementViewModel 提供名称编辑状态与提交动作，依赖 DesignTokens/LoadingStateView 渲染分组轻编辑表单
 * [OUTPUT]: 对外提供 BookGroupNameEditSheet，承接书籍分组新增与重命名的输入、校验和写入反馈
 * [POS]: Views/Personal/Sheets 的书籍分组管理业务 Sheet，被 BookGroupManagementView 通过 sheet(item:) 呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍分组名称编辑 Sheet，提供字数校验与写入反馈。
struct BookGroupNameEditSheet: View {
    @Bindable var viewModel: BookGroupManagementViewModel
    let edit: BookGroupManagementNameEdit
    @FocusState private var isNameFocused: Bool

    private var isWriting: Bool {
        switch viewModel.activeWriteAction {
        case .create, .rename:
            return true
        case .delete, .reorder, nil:
            return false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.section) {
                CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        TextField("请输入分组名称", text: nameBinding)
                            .font(AppTypography.body)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($isNameFocused)
                            .disabled(isWriting)
                            .submitLabel(.done)
                            .onSubmit {
                                viewModel.submitNameEdit()
                            }

                        Divider()

                        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                            Text(validationText)
                                .font(AppTypography.caption)
                                .foregroundStyle(validationColor)
                                .lineLimit(2)
                            Spacer(minLength: Spacing.base)
                            Text("\(viewModel.normalizedNameEditText.count)/100")
                                .font(AppTypography.caption2Medium)
                                .foregroundStyle(Color.textHint)
                        }
                    }
                    .padding(Spacing.contentEdge)
                }

                if !edit.isCreating {
                    Text("当前分组包含 \(edit.bookCount) 本书。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isWriting {
                    LoadingStateView("正在保存…", style: .inline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: Spacing.none)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.section)
            .background(Color.surfaceSheet.ignoresSafeArea())
            .navigationTitle(edit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        viewModel.dismissNameEdit()
                    }
                    .disabled(isWriting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        viewModel.submitNameEdit()
                    }
                    .disabled(!viewModel.canSubmitNameEdit || isWriting)
                }
            }
            .interactiveDismissDisabled(isWriting)
            .onAppear {
                isNameFocused = true
            }
        }
        .presentationDetents([.height(300), .medium])
        .presentationDragIndicator(.visible)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { viewModel.nameEditText },
            set: { viewModel.updateNameEditText($0) }
        )
    }

    private var validationText: String {
        if let message = viewModel.writeError {
            return message
        }
        if let message = viewModel.nameEditValidationMessage {
            return message
        }
        return "最多 100 个字符"
    }

    private var validationColor: Color {
        if viewModel.writeError != nil || viewModel.nameEditValidationMessage != nil {
            return Color.feedbackError
        }
        return Color.textSecondary
    }
}
