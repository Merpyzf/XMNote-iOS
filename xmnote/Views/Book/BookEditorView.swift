/**
 * [INPUT]: 依赖 RepositoryContainer 注入录入仓储，依赖 BookEditorViewModel 驱动完整录入页状态
 * [OUTPUT]: 对外提供 BookEditorView，承载搜索结果确认与手动创建的完整录入页
 * [POS]: Book 模块录入页壳层，负责完整字段编辑、未保存拦截与保存动作
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍完整录入页入口，支持搜索结果预填与手动创建。
struct BookEditorView: View {
    let seed: BookEditorSeed?

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: BookEditorViewModel?
    @State private var showsDiscardDialog = false
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            if let viewModel {
                content(viewModel)
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在准备录入页…", style: .card)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = BookEditorViewModel(seed: seed, repository: repositories.bookEditorRepository)
            viewModel = newViewModel
            bootstrapLoadingGate.update(intent: .none)
            await newViewModel.loadIfNeeded()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }

    private func content(_ viewModel: BookEditorViewModel) -> some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            if let draft = viewModel.draft {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.base) {
                        headerSection(draft)
                        baseInfoSection(viewModel, draft: draft)
                        readingInfoSection(viewModel, draft: draft)
                        progressSection(viewModel, draft: draft)
                        relationSection(viewModel, draft: draft)
                        extraInfoSection(viewModel, draft: draft)
                    }
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.base)
                    .padding(.bottom, 120)
                }
                .scrollIndicators(.hidden)
            } else if viewModel.isLoading {
                if readLoadingGate.isVisible {
                    LoadingStateView("正在准备录入表单…")
                } else {
                    Color.clear
                }
            }

            if viewModel.isSaving {
                Color.overlay.ignoresSafeArea()
                LoadingStateView("正在保存…", style: .card)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationPopGuard(
            canPop: !viewModel.hasUnsavedChanges && !viewModel.isSaving,
            onBlockedAttempt: {
                if !viewModel.isSaving {
                    showsDiscardDialog = true
                }
            }
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarBackButton {
                    handleDismissAttempt(using: viewModel)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let draft = viewModel.draft {
                bottomBar(viewModel, draft: draft)
            }
        }
        .confirmationDialog("放弃未保存的更改？", isPresented: $showsDiscardDialog) {
            Button("放弃更改", role: .destructive) {
                dismiss()
            }
            Button("继续编辑", role: .cancel) { }
        }
        .onAppear {
            syncReadLoadingVisibility(using: viewModel)
        }
        .onChange(of: viewModel.isLoading) { _, _ in
            syncReadLoadingVisibility(using: viewModel)
        }
        .onChange(of: viewModel.draft == nil) { _, _ in
            syncReadLoadingVisibility(using: viewModel)
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
    }

    @State private var readLoadingGate = LoadingGate()

    func syncReadLoadingVisibility(using viewModel: BookEditorViewModel) {
        let intent: LoadingIntent = (viewModel.isLoading && viewModel.draft == nil) ? .read : .none
        readLoadingGate.update(intent: intent)
    }

    private func headerSection(_ draft: BookEditorDraft) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            HStack(alignment: .top, spacing: Spacing.base) {
                XMBookCover.fixedWidth(
                    92,
                    urlString: draft.coverURL,
                    cornerRadius: CornerRadius.inlayHairline,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: .medium,
                    surfaceStyle: .spine
                )

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text(draft.title.isEmpty ? "新书录入" : draft.title)
                        .font(AppTypography.brandDisplay(size: 24, relativeTo: .title3))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)

                    Text(draft.author.isEmpty ? "请完善书籍核心信息后保存" : draft.author)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)

                    if let searchSource = draft.searchSource {
                        Text("搜索来源 · \(searchSource.title)")
                            .font(AppTypography.semantic(.footnote, weight: .medium))
                            .foregroundStyle(Color.brand)
                            .padding(.horizontal, Spacing.cozy)
                            .padding(.vertical, Spacing.tiny)
                            .background(Color.brand.opacity(0.12), in: Capsule())
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var navigationTitle: String {
        if seed?.searchSource == nil {
            return "手动创建"
        }
        return "确认书籍信息"
    }

    private func handleDismissAttempt(using viewModel: BookEditorViewModel) {
        guard !viewModel.isSaving else { return }
        if viewModel.hasUnsavedChanges {
            showsDiscardDialog = true
        } else {
            dismiss()
        }
    }

    private func baseInfoSection(_ viewModel: BookEditorViewModel, draft: BookEditorDraft) -> some View {
        editorSection(title: "基础信息") {
            editorTextField("书名", text: binding(viewModel, \.title))
            editorTextField("原书名", text: binding(viewModel, \.rawTitle))
            editorTextField("作者", text: binding(viewModel, \.author))
            editorTextField("译者", text: binding(viewModel, \.translator))
            editorTextField("出版社", text: binding(viewModel, \.press))
            editorTextField("ISBN", text: binding(viewModel, \.isbn), keyboardType: .asciiCapable)
            editorTextField("出版日期", text: binding(viewModel, \.pubDate))
            editorTextEditor("作者简介", text: binding(viewModel, \.authorIntro), minHeight: 96)
            editorTextEditor("摘要", text: binding(viewModel, \.summary), minHeight: 120)
            editorTextEditor("目录", text: binding(viewModel, \.catalog), minHeight: 120)
        }
    }

    private func readingInfoSection(_ viewModel: BookEditorViewModel, draft: BookEditorDraft) -> some View {
        editorSection(title: "阅读设置") {
            optionRow(title: "书籍类型", selection: draft.bookType.title) {
                ForEach(BookEntryBookType.allCases) { item in
                    chip(item.title, isSelected: draft.bookType == item) {
                        viewModel.applyBookType(item)
                    }
                }
            }

            optionRow(title: "进度单位", selection: draft.progressUnit.title) {
                ForEach(BookEntryProgressUnit.allCases) { item in
                    chip(item.title, isSelected: draft.progressUnit == item) {
                        if var mutableDraft = viewModel.draft {
                            mutableDraft.progressUnit = item
                            viewModel.draft = mutableDraft
                        }
                    }
                }
            }

            optionRow(title: "阅读状态", selection: draft.readingStatus.title) {
                ForEach(BookEntryReadingStatus.allCases) { item in
                    chip(item.title, isSelected: draft.readingStatus == item) {
                        if var mutableDraft = viewModel.draft {
                            mutableDraft.readingStatus = item
                            viewModel.draft = mutableDraft
                        }
                    }
                }
            }

            DatePicker(
                "状态时间",
                selection: Binding(
                    get: { draft.readStatusChangedDate },
                    set: {
                        if var mutableDraft = viewModel.draft {
                            mutableDraft.readStatusChangedDate = $0
                            viewModel.draft = mutableDraft
                        }
                    }
                ),
                displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
        }
    }

    @ViewBuilder
    private func progressSection(_ viewModel: BookEditorViewModel, draft: BookEditorDraft) -> some View {
        editorSection(title: "进度信息") {
            switch draft.progressUnit {
            case .progress:
                editorTextField("当前进度（0-100）", text: binding(viewModel, \.currentProgressText), keyboardType: .decimalPad)
            case .position:
                editorTextField("当前位置", text: binding(viewModel, \.currentProgressText), keyboardType: .numberPad)
                editorTextField("总位置", text: binding(viewModel, \.totalPositionText), keyboardType: .numberPad)
            case .pagination:
                editorTextField("当前页数", text: binding(viewModel, \.currentProgressText), keyboardType: .numberPad)
                editorTextField("总页数", text: binding(viewModel, \.totalPagesText), keyboardType: .numberPad)
            }
        }
    }

    private func relationSection(_ viewModel: BookEditorViewModel, draft: BookEditorDraft) -> some View {
        editorSection(title: "分组与标签") {
            editorTextField("来源", text: binding(viewModel, \.sourceName))
            suggestionStrip(
                options: viewModel.options?.sources ?? [],
                selectedTitle: draft.sourceName,
                onTap: viewModel.selectSource(_:)
            )

            editorTextField("分组", text: binding(viewModel, \.groupName))
            suggestionStrip(
                options: viewModel.options?.groups ?? [],
                selectedTitle: draft.groupName,
                onTap: viewModel.selectGroup(_:)
            )

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("标签")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                editorTextField("输入后回车添加", text: Binding(
                    get: { viewModel.tagInput },
                    set: { viewModel.tagInput = $0 }
                ))
                .onSubmit {
                    viewModel.commitTagInput()
                }

                if !draft.tagNames.isEmpty {
                    chipWrap(draft.tagNames) { tag in
                        removableChip(tag) {
                            viewModel.removeTag(tag)
                        }
                    }
                }

                chipWrap(viewModel.options?.tags.map(\.title) ?? []) { tag in
                    chip(tag, isSelected: draft.tagNames.contains(tag)) {
                        if let option = viewModel.options?.tags.first(where: { $0.title == tag }) {
                            viewModel.toggleTag(option)
                        }
                    }
                }
            }
        }
    }

    private func extraInfoSection(_ viewModel: BookEditorViewModel, draft: BookEditorDraft) -> some View {
        editorSection(title: "其它信息") {
            editorTextField("封面链接", text: binding(viewModel, \.coverURL))
            editorTextField("价格", text: binding(viewModel, \.priceText), keyboardType: .decimalPad)

            DatePicker(
                "购买日期",
                selection: Binding(
                    get: { draft.purchaseDate ?? .now },
                    set: {
                        if var mutableDraft = viewModel.draft {
                            mutableDraft.purchaseDate = $0
                            viewModel.draft = mutableDraft
                        }
                    }
                ),
                displayedComponents: [.date]
            )
            .datePickerStyle(.compact)
        }
    }

    private func bottomBar(_ viewModel: BookEditorViewModel, draft: BookEditorDraft) -> some View {
        VStack(spacing: Spacing.cozy) {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(AppTypography.semantic(.footnote, weight: .medium))
                    .foregroundStyle(Color.feedbackError)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task {
                    let result = await viewModel.save()
                    if result != nil {
                        dismiss()
                    }
                }
            } label: {
                HStack {
                    Spacer()
                    Text(viewModel.isSaving ? "正在保存…" : "保存入库")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.vertical, Spacing.base)
                .background(Color.brand, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSaving || draft.trimmedTitle.isEmpty)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.cozy)
        .padding(.bottom, Spacing.cozy)
        .background(.ultraThinMaterial)
    }

    private func editorSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                content()
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func editorTextField(
        _ title: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)

            TextField(title, text: text)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.tight)
                .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        }
    }

    private func editorTextEditor(
        _ title: String,
        text: Binding<String>,
        minHeight: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)

            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .padding(Spacing.cozy)
                .frame(minHeight: minHeight)
                .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        }
    }

    private func optionRow<Content: View>(
        title: String,
        selection: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)

            Text(selection)
                .font(AppTypography.footnote)
                .foregroundStyle(Color.textHint)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.cozy) {
                    content()
                }
            }
        }
    }

    private func suggestionStrip(
        options: [BookEditorNamedOption],
        selectedTitle: String,
        onTap: @escaping (BookEditorNamedOption) -> Void
    ) -> some View {
        chipWrap(options) { option in
            chip(option.title, isSelected: selectedTitle == option.title) {
                onTap(option)
            }
        }
    }

    private func chipWrap<Data: RandomAccessCollection, Content: View>(
        _ data: Data,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) -> some View where Data.Element: Hashable {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.cozy) {
                ForEach(Array(data), id: \.self) { item in
                    content(item)
                }
            }
        }
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.semantic(.footnote, weight: .medium))
                .foregroundStyle(isSelected ? .white : Color.textPrimary)
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.cozy)
                .background(isSelected ? Color.brand : Color.surfaceNested, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func removableChip(_ title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: Spacing.compact) {
            Text(title)
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .font(
            AppTypography.semantic(.footnote, weight: .medium)
        )
        .foregroundStyle(Color.textPrimary)
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.cozy)
        .background(Color.surfaceNested, in: Capsule())
    }

    private func binding(_ viewModel: BookEditorViewModel, _ keyPath: WritableKeyPath<BookEditorDraft, String>) -> Binding<String> {
        Binding(
            get: { viewModel.draft?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if var draft = viewModel.draft {
                    draft[keyPath: keyPath] = newValue
                    viewModel.draft = draft
                }
            }
        )
    }
}

#Preview {
    NavigationStack {
        BookEditorView(seed: .manual)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
