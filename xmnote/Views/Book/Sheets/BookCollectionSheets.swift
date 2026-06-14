/**
 * [INPUT]: 依赖 BookCollectionFormPresentation 与 BookCollectionRecommendEdit 承载书单编辑和推荐语编辑上下文
 * [OUTPUT]: 对外提供 BookCollectionFormSheet 与 BookCollectionRecommendSheet，承载书单创建/编辑和推荐语编辑的任务面板
 * [POS]: Book 模块业务 Sheet，替代书单文本输入类中心弹窗
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书单创建/编辑任务面板，用更稳定的空间承载标题与简介输入。
struct BookCollectionFormSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var description: String

    let presentation: BookCollectionFormPresentation
    let isSaving: Bool
    let onSave: (String, String) -> Void

    /// 以表单状态初始化 Sheet 草稿，提交前不影响 ViewModel 源数据。
    init(
        presentation: BookCollectionFormPresentation,
        isSaving: Bool,
        onSave: @escaping (String, String) -> Void
    ) {
        self.presentation = presentation
        self.isSaving = isSaving
        self.onSave = onSave
        self._title = State(initialValue: presentation.initialTitle)
        self._description = State(initialValue: presentation.initialDescription)
    }

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: presentation.title,
            subtitle: "标题与简介",
            onClose: { dismiss() },
            leadingAction: {
                BookCollectionSheetTopTextButton(
                    title: "取消",
                    foregroundColor: .textSecondary,
                    action: { dismiss() }
                )
            },
            trailingAction: {
                BookCollectionSheetTopTextButton(
                    title: saveTitle,
                    foregroundColor: .brand.opacity(0.82),
                    isDisabled: !canSave || isSaving,
                    action: submit
                )
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                fieldGroup(title: "标题") {
                    TextField("书单标题", text: $title)
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textPrimary)
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .padding(.horizontal, Spacing.base)
                        .frame(minHeight: 52)
                        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                        }
                }

                fieldGroup(title: "简介") {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $description)
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, Spacing.cozy)
                            .padding(.vertical, Spacing.half)
                            .frame(minHeight: 128)

                        if trimmedDescription.isEmpty {
                            Text("简介（可选）")
                                .font(AppTypography.body)
                                .foregroundStyle(Color.textHint)
                                .padding(.horizontal, Spacing.base)
                                .padding(.vertical, Spacing.base)
                                .allowsHitTesting(false)
                        }
                    }
                    .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                            .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                    }
                }

                Spacer(minLength: Spacing.none)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
    }

    private var saveTitle: String {
        presentation.mode == .create ? "创建" : "保存"
    }

    private func submit() {
        guard canSave, !isSaving else { return }
        onSave(trimmedTitle, trimmedDescription)
    }

    private func fieldGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            content()
        }
    }
}

/// 书单内推荐语编辑面板，保留书籍上下文并给推荐语更充足的输入空间。
struct BookCollectionRecommendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recommend: String

    let edit: BookCollectionRecommendEdit
    let isSaving: Bool
    let onSave: (String) -> Void

    /// 以当前 relation 推荐语初始化草稿，保存后由 ViewModel 写回。
    init(
        edit: BookCollectionRecommendEdit,
        isSaving: Bool,
        onSave: @escaping (String) -> Void
    ) {
        self.edit = edit
        self.isSaving = isSaving
        self.onSave = onSave
        self._recommend = State(initialValue: edit.item.recommend)
    }

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: edit.item.recommend.isEmpty ? "添加推荐语" : "编辑推荐语",
            subtitle: "推荐语",
            onClose: { dismiss() },
            leadingAction: {
                BookCollectionSheetTopTextButton(
                    title: "取消",
                    foregroundColor: .textSecondary,
                    action: { dismiss() }
                )
            },
            trailingAction: {
                BookCollectionSheetTopTextButton(
                    title: "保存",
                    foregroundColor: .brand.opacity(0.82),
                    isDisabled: isSaving,
                    action: submit
                )
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                bookContext

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $recommend)
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.half)
                        .frame(minHeight: 180)

                    if trimmedRecommend.isEmpty {
                        Text("写下推荐语")
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textHint)
                            .padding(.horizontal, Spacing.base)
                            .padding(.vertical, Spacing.base)
                            .allowsHitTesting(false)
                    }
                }
                .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                }

                Text("留空保存会清除推荐语，但不会移出书单。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.none)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var bookContext: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                52,
                urlString: edit.item.book.cover,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.half) {
                Text(edit.item.book.title.isEmpty ? "未命名书籍" : edit.item.book.title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !edit.item.book.author.isEmpty {
                    Text(edit.item.book.author)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .combine)
    }

    private var trimmedRecommend: String {
        recommend.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !isSaving else { return }
        onSave(trimmedRecommend)
    }
}

/// 书单 Sheet 顶部文字按钮，复用批量面板的文字密度但保持文件私有边界。
private struct BookCollectionSheetTopTextButton: View {
    let title: String
    let foregroundColor: Color
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(isDisabled ? Color.textHint : foregroundColor)
                .frame(minWidth: Spacing.actionReserved, minHeight: Spacing.actionReserved)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
