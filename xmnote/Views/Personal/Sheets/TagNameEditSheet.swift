/**
 * [INPUT]: 依赖 TagManagementViewModel 提供名称编辑状态与提交动作，依赖 DesignTokens/LoadingStateView 渲染标签轻编辑表单
 * [OUTPUT]: 对外提供 TagNameEditSheet，承接标签新增与重命名的输入、校验和写入反馈
 * [POS]: Views/Personal/Sheets 的标签管理业务 Sheet，被 TagManagementView 通过 sheet(item:) 呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 标签名称编辑 Sheet，提供比中心弹窗更完整的字数校验和写入反馈。
struct TagNameEditSheet: View {
    private static let maximumNameLength = 100

    @Bindable var viewModel: TagManagementViewModel
    let edit: TagManagementNameEdit
    @FocusState private var isNameFocused: Bool
    @State private var hasEditedName = false

    private var isWriting: Bool {
        switch viewModel.activeWriteAction {
        case .create, .rename:
            return true
        case .delete, .reorder, nil:
            return false
        }
    }

    var body: some View {
        XMSheetScaffold(
            title: edit.title,
            onClose: { viewModel.dismissNameEdit() },
            leadingAction: {
                Button("取消") { viewModel.dismissNameEdit() }
                    .disabled(isWriting)
            },
            trailingAction: {
                Button("保存") { viewModel.submitNameEdit() }
                    .disabled(!viewModel.canSubmitNameEdit || isWriting)
            }
        ) {
            VStack(spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                        VStack(alignment: .leading, spacing: Spacing.base) {
                            TextField("请输入标签名称", text: nameBinding)
                                .font(AppTypography.body)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($isNameFocused)
                                .disabled(isWriting)
                                .submitLabel(.done)
                                .onSubmit {
                                    viewModel.submitNameEdit()
                                }
                                .onChange(of: viewModel.nameEditText) {
                                    hasEditedName = true
                                }

                            Divider()

                            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                                Spacer(minLength: Spacing.base)
                                Text("\(characterCount)/\(Self.maximumNameLength)")
                                    .font(AppTypography.caption2Medium)
                                    .foregroundStyle(isCharacterLimitExceeded ? Color.feedbackError : Color.textHint)
                                    .monospacedDigit()
                                    .accessibilityLabel("已输入 \(characterCount) 个字符，最多 \(Self.maximumNameLength) 个字符")
                            }
                        }
                        .padding(Spacing.contentEdge)
                    }

                    if let validationText {
                        Text(validationText)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.feedbackError)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, Spacing.contentEdge)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !edit.isCreating {
                    Text("将同步更新 \(edit.associatedCount) 条\(edit.scope.associatedItemTitle)关联中的标签名称")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isWriting {
                    LoadingStateView("正在保存…", style: .inline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .interactiveDismissDisabled(isWriting)
        .onAppear { isNameFocused = true }
        .presentationDetents([.height(300), .medium])
        .presentationDragIndicator(.visible)
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { viewModel.nameEditText },
            set: { viewModel.updateNameEditText($0) }
        )
    }

    private var validationText: String? {
        if let message = viewModel.writeError {
            return message
        }
        if hasEditedName, let message = viewModel.nameEditValidationMessage {
            return message
        }
        return nil
    }

    private var characterCount: Int {
        viewModel.normalizedNameEditText.count
    }

    private var isCharacterLimitExceeded: Bool {
        characterCount > Self.maximumNameLength
    }
}
