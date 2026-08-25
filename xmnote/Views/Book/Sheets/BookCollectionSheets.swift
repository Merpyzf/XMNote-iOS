/**
 * [INPUT]: 依赖 BookCollectionDetail、BookCollectionFormPresentation、BookCollectionRecommendEdit、BookCollectionBookMetadataEdit 与 relation 文本展示语义承载书单详情、书单编辑、书籍元信息编辑和关系备注编辑上下文
 * [OUTPUT]: 对外提供 BookCollectionSummarySheet、BookCollectionFormSheet、BookCollectionBookMetadataEditSheet 与 BookCollectionRecommendSheet，承载书单简介查看、创建/编辑、书籍元信息和收藏理由/年度点评编辑的任务面板
 * [POS]: Book 模块业务 Sheet，替代书单文本输入类中心弹窗
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import PhotosUI
import SwiftUI

/// 书单完整简介面板，在详情 Header 截断时承载完整标题、简介与阅读进度。
struct BookCollectionSummarySheet: View {
    @Environment(\.dismiss) private var dismiss

    let detail: BookCollectionDetail

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: "书单简介",
            subtitle: kindSubtitle,
            onClose: { dismiss() },
            leadingAction: {
                Color.clear
                    .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
            },
            trailingAction: {
                BookCollectionSheetTopTextButton(
                    title: "完成",
                    foregroundColor: .brand.opacity(0.82),
                    action: { dismiss() }
                )
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                summaryCard
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            fieldGroup(title: "标题") {
                Text(displayTitle)
                    .font(AppTypography.title3Semibold)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .overlay(Color.surfaceBorderSubtle)

            fieldGroup(title: "简介") {
                Text(displayDescription)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .overlay(Color.surfaceBorderSubtle)

            BookCollectionProgressSummary(
                kind: detail.kind,
                bookCount: detail.bookCount,
                finishedCount: detail.finishedCount,
                targetReadCount: detail.targetReadCount
            )
        }
        .padding(Spacing.contentEdge)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .contain)
    }

    private var displayTitle: String {
        if detail.kind == .annual, let year = detail.year, detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(year) 年阅读"
        }
        let title = detail.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "未命名书单" : title
    }

    private var displayDescription: String {
        let description = detail.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }
        switch detail.kind {
        case .manual:
            return detail.bookCount == 0 ? "从书架里挑选几本书，给这个主题一个开始" : "按你的阅读主题整理出的书籍集合"
        case .annual:
            return "随读完记录自动同步，保留这一年的阅读轨迹"
        }
    }

    private var kindSubtitle: String {
        switch detail.kind {
        case .manual:
            return "手动书单"
        case .annual:
            if let year = detail.year {
                return "\(year) 年度书单"
            }
            return "年度书单"
        }
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

/// 书单内 relation 文本编辑面板，保留书籍上下文并按书单类型切换收藏理由或年度点评文案。
struct BookCollectionRecommendSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var recommend: String

    let edit: BookCollectionRecommendEdit
    let isSaving: Bool
    let presentation: BookCollectionRelationNotePresentation
    let onSave: (String) -> Void

    /// 以当前 relation 文本初始化草稿，保存后由 ViewModel 写回。
    init(
        edit: BookCollectionRecommendEdit,
        isSaving: Bool,
        presentation: BookCollectionRelationNotePresentation,
        onSave: @escaping (String) -> Void
    ) {
        self.edit = edit
        self.isSaving = isSaving
        self.presentation = presentation
        self.onSave = onSave
        self._recommend = State(initialValue: edit.item.recommend)
    }

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: presentation.editActionTitle(hasText: !edit.item.recommend.isEmpty),
            subtitle: presentation.title,
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
                        Text(presentation.placeholder)
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

                Text(presentation.clearHint)
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

/// 书单内书籍元信息编辑面板，补齐占位书恢复前的标题、作者、出版社、出版日期、封面与推荐语编辑。
struct BookCollectionBookMetadataEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String
    @State private var press: String
    @State private var pubDate: String
    @State private var coverURL: String
    @State private var recommend: String
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var selectedCover: BookCollectionBookCoverSelection?
    @State private var coverSelectionMessage: String?
    @State private var coverSelectionError: String?
    @State private var showsCoverSearch = false

    let edit: BookCollectionBookMetadataEdit
    let isSaving: Bool
    let presentation: BookCollectionRelationNotePresentation
    let onSave: (BookCollectionBookMetadataEditDraft) -> Void

    /// 以当前书籍与 relation 字段初始化草稿，保存前不改动数据库。
    init(
        edit: BookCollectionBookMetadataEdit,
        isSaving: Bool,
        presentation: BookCollectionRelationNotePresentation,
        onSave: @escaping (BookCollectionBookMetadataEditDraft) -> Void
    ) {
        self.edit = edit
        self.isSaving = isSaving
        self.presentation = presentation
        self.onSave = onSave
        self._title = State(initialValue: edit.item.book.title)
        self._author = State(initialValue: edit.item.book.author)
        self._press = State(initialValue: edit.item.book.press)
        self._pubDate = State(initialValue: edit.item.book.pubDateText)
        self._coverURL = State(initialValue: edit.item.book.cover)
        self._recommend = State(initialValue: edit.item.recommend)
    }

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: "编辑书籍信息",
            subtitle: edit.item.isPlaceholder ? "未加入书架" : "书单内书籍",
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
                    isDisabled: !canSave || isSaving,
                    action: submit
                )
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    coverSection
                    metadataFields
                    relationNoteSection
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.bottom, Spacing.contentEdge)
            }
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showsCoverSearch) {
            BookCollectionCoverSearchSheet(
                initialTitle: trimmedTitle,
                currentCoverURL: trimmedCoverURL
            ) { selectedURL in
                coverURL = selectedURL
                selectedCover = nil
                coverSelectionMessage = "已选择在线封面链接"
                coverSelectionError = nil
            }
        }
        .onChange(of: selectedCoverItem) { _, item in
            guard let item else { return }
            Task {
                await consumeCoverItem(item)
            }
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text("封面")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            HStack(alignment: .top, spacing: Spacing.base) {
                XMBookCover.fixedWidth(
                    76,
                    urlString: trimmedCoverURL,
                    cornerRadius: CornerRadius.inlaySmall,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: .small,
                    surfaceStyle: .spine
                )
                .shadow(
                    color: Color.bookCoverDropShadow.opacity(0.14),
                    radius: 7,
                    x: Spacing.none,
                    y: 4
                )

                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    TextField("封面链接", text: $coverURL, axis: .vertical)
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2, reservesSpace: true)
                        .padding(.horizontal, Spacing.base)
                        .frame(minHeight: 52)
                        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                        }

                    HStack(spacing: Spacing.cozy) {
                        Button {
                            showsCoverSearch = true
                        } label: {
                            Label("在线匹配", systemImage: "magnifyingglass")
                                .font(AppTypography.subheadlineMedium)
                                .foregroundStyle(Color.brand.opacity(0.86))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)

                        PhotosPicker(
                            selection: $selectedCoverItem,
                            matching: .images
                        ) {
                            Label("选择封面", systemImage: "photo")
                                .font(AppTypography.subheadlineMedium)
                                .foregroundStyle(Color.brand.opacity(0.86))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }

                    coverSelectionStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }

    private var metadataFields: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            textFieldGroup(title: "标题") {
                TextField("书名", text: $title)
                    .textInputAutocapitalization(.sentences)
            }

            textFieldGroup(title: "作者") {
                TextField("作者", text: $author)
                    .textInputAutocapitalization(.words)
            }

            textFieldGroup(title: "出版社") {
                TextField("出版社", text: $press)
                    .textInputAutocapitalization(.words)
            }

            textFieldGroup(title: "出版日期") {
                TextField("出版日期", text: $pubDate)
                    .textInputAutocapitalization(.never)
            }
        }
    }

    private var relationNoteSection: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(presentation.title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $recommend)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Spacing.cozy)
                    .padding(.vertical, Spacing.half)
                    .frame(minHeight: 150)

                if trimmedRecommend.isEmpty {
                    Text(presentation.placeholder)
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
    }

    @ViewBuilder
    private var coverSelectionStatus: some View {
        if let coverSelectionMessage {
            Text(coverSelectionMessage)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if let coverSelectionError {
            Text(coverSelectionError)
                .font(AppTypography.caption)
                .foregroundStyle(Color.feedbackWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCoverURL: String {
        coverURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedRecommend: String {
        recommend.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty
    }

    private func textFieldGroup<Content: View>(
        title: String,
        @ViewBuilder field: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            field()
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Spacing.base)
                .frame(minHeight: 52)
                .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                }
        }
    }

    private func submit() {
        guard canSave, !isSaving else { return }
        onSave(
            BookCollectionBookMetadataEditDraft(
                title: trimmedTitle,
                author: author.trimmingCharacters(in: .whitespacesAndNewlines),
                press: press.trimmingCharacters(in: .whitespacesAndNewlines),
                pubDate: pubDate.trimmingCharacters(in: .whitespacesAndNewlines),
                coverURL: trimmedCoverURL,
                recommend: trimmedRecommend,
                selectedCover: selectedCover
            )
        )
    }

    @MainActor
    private func consumeCoverItem(_ item: PhotosPickerItem) async {
        defer {
            selectedCoverItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                coverSelectionMessage = nil
                coverSelectionError = "未能读取封面图片"
                selectedCover = nil
                return
            }
            let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            selectedCover = BookCollectionBookCoverSelection(data: data, fileExtension: fileExtension)
            coverSelectionMessage = "已选择本地封面，保存时上传"
            coverSelectionError = nil
        } catch {
            coverSelectionMessage = nil
            coverSelectionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            selectedCover = nil
        }
    }
}

/// 年度书单本体说明编辑面板，只编辑年度说明，不暴露标题、年份和成员管理。
struct BookCollectionAnnualDescriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var description: String

    let edit: BookCollectionAnnualDescriptionEdit
    let isSaving: Bool
    let onSave: (String) -> Void

    init(
        edit: BookCollectionAnnualDescriptionEdit,
        isSaving: Bool,
        onSave: @escaping (String) -> Void
    ) {
        self.edit = edit
        self.isSaving = isSaving
        self.onSave = onSave
        self._description = State(initialValue: edit.detail.description)
    }

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: "编辑年度说明",
            subtitle: subtitle,
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
                Text("写下这一年的阅读主题、收获或给自己的提醒。单本书的记录仍放在年度点评里。")
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $description)
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.half)
                        .frame(minHeight: 180)

                    if trimmedDescription.isEmpty {
                        Text("年度说明（可选）")
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

                Spacer(minLength: Spacing.none)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    private var subtitle: String {
        if let year = edit.detail.year {
            return "\(year) 年度书单"
        }
        return "年度书单"
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !isSaving else { return }
        onSave(trimmedDescription)
    }
}

/// 微信读书书单链接输入面板，解析成功前不写入数据库。
struct BookCollectionWereadImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link: String = ""

    let isLoading: Bool
    let errorMessage: String?
    let onParse: (String) -> Void

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: "导入微信读书书单",
            subtitle: "粘贴链接",
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
                    title: "解析",
                    foregroundColor: .brand.opacity(0.82),
                    isDisabled: trimmedLink.isEmpty || isLoading,
                    action: submit
                )
            }
        ) {
            VStack(alignment: .leading, spacing: Spacing.section) {
                Text("从微信读书分享书单后，把链接粘贴到这里。解析完成后会先展示预览，由你确认是否导入。")
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("https://weread.qq.com/...", text: $link, axis: .vertical)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(3, reservesSpace: true)
                    .padding(Spacing.base)
                    .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                            .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                    }

                if let errorMessage {
                    BookCollectionWereadImportErrorMessage(message: errorMessage)
                }

                if isLoading {
                    HStack(spacing: Spacing.tight) {
                        LoadingStateView(nil, style: .inline)
                        Text("正在解析页面…")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
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

    private var trimmedLink: String {
        link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedLink.isEmpty, !isLoading else { return }
        onParse(trimmedLink)
    }
}

/// 微信读书导入预览面板，确认后才保存为 XMNote 书单。
struct BookCollectionWereadImportPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let preview: BookCollectionImportPreview
    let isSaving: Bool
    let errorMessage: String?
    let onConfirm: (BookCollectionImportPreview) -> Void

    var body: some View {
        BookshelfDisplaySettingPageScaffold(
            title: "确认导入",
            subtitle: "\(preview.books.count) 本书",
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
                    title: "导入",
                    foregroundColor: .brand.opacity(0.82),
                    isDisabled: isSaving,
                    action: submit
                )
            }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    previewHeader

                    if let errorMessage {
                        BookCollectionWereadImportErrorMessage(message: errorMessage)
                    }

                    VStack(spacing: Spacing.tight) {
                        ForEach(preview.books.prefix(12)) { book in
                            previewBookRow(book)
                        }

                        if preview.books.count > 12 {
                            Text("另有 \(preview.books.count - 12) 本书将在导入时一并保存")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, Spacing.compact)
                        }
                    }
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.bottom, Spacing.contentEdge)
            }
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }

    private var previewHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(preview.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "微信读书书单" : preview.title)
                .font(AppTypography.title3Semibold)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !preview.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(preview.description)
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("导入后会创建为我的书单，书籍先以“未加入书架”的占位状态保存")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
    }

    private func previewBookRow(_ book: BookCollectionImportPreviewBook) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                44,
                urlString: book.coverURL,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(book.title.isEmpty ? "未命名书籍" : book.title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(book.author)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }

                if !book.recommend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(book.recommend)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle.opacity(0.62), lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .combine)
    }

    private func submit() {
        guard !isSaving else { return }
        onConfirm(preview)
    }
}

private struct BookCollectionWereadImportErrorMessage: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.tight) {
            Image(systemName: "exclamationmark.triangle")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.feedbackWarning)

            Text(message.isEmpty ? "导入失败，请稍后重试" : message)
                .font(AppTypography.caption)
                .foregroundStyle(Color.feedbackWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.tight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.feedbackWarning.opacity(0.08), in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("导入失败，\(message.isEmpty ? "请稍后重试" : message)")
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
