/**
 * [INPUT]: 依赖 SourceManagementViewModel 提供名称编辑状态与提交动作，依赖 DesignTokens、xmSheetContentPanel 与 LoadingStateView 渲染来源轻编辑表单
 * [OUTPUT]: 对外提供 SourceNameEditSheet，承接来源新增与重命名的输入、校验和写入反馈
 * [POS]: Views/Personal/Sheets 的书籍来源管理业务 Sheet，被 SourceManagementView 通过 sheet(item:) 呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 来源名称编辑 Sheet，提供比中心弹窗更完整的字数校验和写入反馈。
struct SourceNameEditSheet: View {
    private static let maximumNameLength = 100

    @Bindable var viewModel: SourceManagementViewModel
    let edit: SourceManagementNameEdit
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
            onClose: close,
            isConfirmationDisabled: !viewModel.canSubmitNameEdit,
            isConfirming: isWriting,
            confirmationAction: submit
        ) {
            VStack(spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    CardContainer(shape: ConcentricRectangle.xmSheetContentPanel, showsBorder: false) {
                        VStack(alignment: .leading, spacing: Spacing.base) {
                            TextField("请输入来源名称", text: nameBinding)
                                .font(AppTypography.body)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($isNameFocused)
                                .disabled(isWriting)
                                .submitLabel(.done)
                                .onSubmit(submit)
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
                    Text("将同步更新 \(edit.associatedBookCount) 本书籍中的来源名称")
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
        .scrollDismissesKeyboard(.interactively)
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

    private func close() {
        isNameFocused = false
        viewModel.dismissNameEdit()
    }

    private func submit() {
        guard viewModel.canSubmitNameEdit else { return }
        isNameFocused = false
        viewModel.submitNameEdit()
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
