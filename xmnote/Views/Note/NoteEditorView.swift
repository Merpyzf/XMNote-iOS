/**
 * [INPUT]: 依赖 RepositoryContainer 注入 NoteRepository，依赖 NoteEditorViewModel 驱动完整书摘编辑状态，依赖 NoteTextComposerView 承接全屏富文本输入
 * [OUTPUT]: 对外提供 NoteEditorView，承载书摘新建/编辑、草稿恢复、附图、章节/标签与保存动作
 * [POS]: Note 模块书摘编辑页壳层，对齐 Android 编辑流程并采用 iOS 原生页面组织
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import PhotosUI
import SwiftUI
import UIKit

/// 书摘编辑页入口，支持新建与编辑两种模式。
struct NoteEditorView: View {
    let mode: NoteEditorMode
    let seed: NoteEditorSeed?

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: NoteEditorViewModel?
    @State private var editorSettings = NoteEditorSettings()
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var showsDiscardDialog = false
    @State private var activeComposer: NoteEditorComposerTarget?
    @State private var activeSheet: NoteEditorSheet?
    @State private var activeEditorTarget: NoteEditorComposerTarget?
    @State private var isContentFocused = false
    @State private var isIdeaFocused = false
    @State private var contentOrnamentController = RichTextOrnamentController()
    @State private var ideaOrnamentController = RichTextOrnamentController()
    @State private var showsOCRChooser = false
    @State private var showsPhotoOCRFlow = false
    @State private var toolbarPromptMessage: String?
    @State private var attachmentPhotoItems: [PhotosPickerItem] = []
    @State private var showsAttachmentPicker = false
    @State private var measuredHeights: [NoteEditorMeasuredPart: CGFloat] = [:]
    @State private var keyboardHeight: CGFloat = 0
    @State private var lastClosedComposerTarget: NoteEditorComposerTarget?
    @State private var baselineIdleTimerDisabled: Bool?
    @State private var baselineScreenBrightness: CGFloat?
    @State private var autoDimTask: Task<Void, Never>?
    @State private var lastInteractionDate = Date.distantPast

    init(mode: NoteEditorMode, seed: NoteEditorSeed? = nil) {
        self.mode = mode
        self.seed = seed
    }

    var body: some View {
        ZStack {
            if let viewModel {
                editorContent(viewModel)
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在准备书摘编辑页…", style: .card)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = NoteEditorViewModel(
                mode: mode,
                seed: seed,
                repository: repositories.noteRepository
            )
            viewModel = newViewModel
            bootstrapLoadingGate.update(intent: .none)
            await newViewModel.loadIfNeeded()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

private extension NoteEditorView {
    var layoutMode: NoteEditorLayoutMode {
        NoteEditorLayoutMode(rawValue: editorSettings.layoutModeRawValue) ?? .classic
    }

    var activeOrnamentController: RichTextOrnamentController? {
        switch activeEditorTarget {
        case .content:
            return contentOrnamentController
        case .idea:
            return ideaOrnamentController
        case nil:
            return nil
        }
    }

    var supportsPhotoOCR: Bool { true }
    var usesSplitOCREntryButtons: Bool { editorSettings.ocrEntryMode == .splitButtons }

    func editorContent(_ viewModel: NoteEditorViewModel) -> some View {
        GeometryReader { geometry in
            let heights = editorHeights(
                for: geometry.size.height,
                bookSectionHeight: measuredHeights[.book] ?? 0,
                tailSectionHeight: measuredHeights[.tail] ?? 0
            )
            let scrollBottomPadding = max(Spacing.section, (measuredHeights[.toolbar] ?? 0) + Spacing.base)

            ZStack {
                Color.surfacePage.ignoresSafeArea()

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Spacing.base) {
                            bookCard(viewModel)
                                .noteEditorReportHeight(.book)

                            richTextEditorCard(
                                target: .content,
                                text: viewModel.binding(for: .content),
                                hint: "摘录",
                                controller: contentOrnamentController,
                                isFocused: isContentFocused,
                                height: heights.content,
                                showsInlineOCRButton: usesSplitOCREntryButtons,
                                onInlineOCR: { triggerInlineOCR(for: .content) }
                            )
                            .id(NoteEditorComposerTarget.content.scrollAnchorID)

                            if layoutMode == .focusExcerpt {
                                focusIdeaRow(viewModel, height: heights.idea)
                                    .id(NoteEditorComposerTarget.idea.scrollAnchorID)
                            } else {
                                richTextEditorCard(
                                    target: .idea,
                                    text: viewModel.binding(for: .idea),
                                    hint: "想法",
                                    controller: ideaOrnamentController,
                                    isFocused: isIdeaFocused,
                                    height: heights.idea,
                                    showsInlineOCRButton: usesSplitOCREntryButtons,
                                    onInlineOCR: { triggerInlineOCR(for: .idea) }
                                )
                                .id(NoteEditorComposerTarget.idea.scrollAnchorID)
                            }

                            VStack(alignment: .leading, spacing: Spacing.base) {
                                if let autoSaveDescription = viewModel.autoSaveDescription {
                                    autoSaveCard(autoSaveDescription)
                                }

                                imageSection(viewModel)
                                metadataSection(viewModel)

                                if let prompt = toolbarPromptMessage, !prompt.isEmpty {
                                    errorCard(prompt)
                                }
                                if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                                    errorCard(errorMessage)
                                }
                            }
                            .noteEditorReportHeight(.tail)
                        }
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Spacing.base)
                        .padding(.bottom, scrollBottomPadding)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: activeEditorTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.snappy) {
                            scrollProxy.scrollTo(target.scrollAnchorID, anchor: .center)
                        }
                    }
                }
                if viewModel.isSaving {
                    Color.overlay.ignoresSafeArea()
                    LoadingStateView("正在保存书摘…", style: .card)
                }
            }
        }
        .navigationTitle(viewModel.navigationTitle)
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
                Button {
                    handleDismissAttempt(using: viewModel)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeSheet = .settings
                    registerEditorInteraction(force: true)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑设置")
            }
        }
        .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
            editorToolbar(viewModel)
                .noteEditorReportHeight(.toolbar)
        }
        .sheet(item: $activeComposer, onDismiss: {
            restoreEditorFocusAfterComposerDismiss()
        }) { target in
            NavigationStack {
                NoteTextComposerView(
                    composerTarget: target,
                    title: target.title,
                    text: viewModel.binding(for: target),
                    ocrRepository: repositories.ocrRepository
                )
            }
        }
        .photosPicker(
            isPresented: $showsAttachmentPicker,
            selection: $attachmentPhotoItems,
            maxSelectionCount: 9,
            matching: .images
        )
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .book:
                NoteEditorBookPickerSheet(
                    books: viewModel.availableBooks,
                    onSelect: { book in
                        viewModel.selectBook(book)
                        activeSheet = nil
                    }
                )
            case .chapter:
                NoteEditorChapterPickerSheet(
                    chapters: viewModel.availableChapters,
                    selectedChapterID: viewModel.selectedChapterID,
                    onSelect: { chapter in
                        viewModel.selectChapter(chapter)
                        activeSheet = nil
                    }
                )
            case .tags:
                NoteEditorTagPickerSheet(
                    availableTags: viewModel.availableTags,
                    selectedTags: viewModel.selectedTags,
                    onToggle: { tag in
                        viewModel.toggleTag(tag)
                    },
                    onCreate: { name in
                        await viewModel.createTag(named: name)
                    }
                )
            case .createdDate:
                NoteEditorDateSheet(
                    selectedDate: Binding(
                        get: {
                            Date(timeIntervalSince1970: Double(viewModel.createdDate) / 1000)
                        },
                        set: { newValue in
                            viewModel.createdDate = Int64(newValue.timeIntervalSince1970 * 1000)
                        }
                    )
                )
            case .settings:
                NoteEditorSettingsSheet(settings: editorSettings)
            }
        }
        .confirmationDialog("选择 OCR 方式", isPresented: $showsOCRChooser) {
            if activeOrnamentController?.canCaptureTextFromCamera == true {
                Button("系统取词") {
                    activeOrnamentController?.send(.cameraTextCapture)
                }
            }
            if supportsPhotoOCR {
                Button("拍照 OCR") {
                    showsPhotoOCRFlow = true
                }
            }
            Button("取消", role: .cancel) { }
        }
        .fullScreenCover(isPresented: $showsPhotoOCRFlow) {
            let target = activeEditorTarget ?? .content
            NotePhotoOCRFlowView(
                target: target,
                repository: repositories.ocrRepository
            ) { payload in
                let text = payload.summary.combinedText
                if let activeOrnamentController {
                    activeOrnamentController.send(.insertText(text))
                } else {
                    viewModel.fallbackAppendRecognizedText(text, to: target)
                }
            }
        }
        .confirmationDialog("放弃未保存的更改？", isPresented: $showsDiscardDialog) {
            Button("放弃更改", role: .destructive) {
                dismiss()
            }
            Button("继续编辑", role: .cancel) { }
        }
        .alert(
            "发现自动保存草稿",
            isPresented: Binding(
                get: { viewModel.pendingRecoveredDraft != nil },
                set: { isPresented in
                    if !isPresented, viewModel.pendingRecoveredDraft != nil {
                        viewModel.discardRecoveredDraft()
                    }
                }
            )
        ) {
            Button("恢复") {
                viewModel.restoreRecoveredDraft()
            }
            Button("丢弃", role: .destructive) {
                viewModel.discardRecoveredDraft()
            }
        } message: {
            Text("检测到这条书摘有未提交的自动保存内容，是否恢复继续编辑？")
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    registerEditorInteraction()
                }
        )
        .task(id: attachmentPhotoItems) {
            guard !attachmentPhotoItems.isEmpty else { return }
            await consumeAttachmentPhotoItems(attachmentPhotoItems, viewModel: viewModel)
            attachmentPhotoItems = []
        }
        .onPreferenceChange(NoteEditorMeasuredHeightsPreferenceKey.self) { values in
            measuredHeights = values
        }
        .onAppear {
            handleLayoutModeStateChange(animated: false)
            captureScreenBehaviorBaselineIfNeeded()
            applyScreenBehavior()
            registerEditorInteraction(force: true)
        }
        .onDisappear {
            releaseScreenBehavior()
        }
        .onChange(of: editorSettings.layoutModeRawValue) { _, _ in
            handleLayoutModeStateChange(animated: false)
        }
        .onChange(of: viewModel.didSave) { _, didSave in
            guard didSave else { return }
            if shouldContinueEditingAfterSave {
                Task {
                    await continueEditingAfterSave(using: viewModel)
                }
                return
            }
            dismiss()
        }
        .onChange(of: editorSettings.keepScreenOnEnabled) { _, _ in
            applyScreenBehavior()
        }
        .onChange(of: editorSettings.autoDimSeconds) { _, _ in
            registerEditorInteraction(force: true)
        }
        .onChange(of: editorSettings.autoDimBrightness) { _, _ in
            if editorSettings.autoDimSeconds > 0 {
                registerEditorInteraction(force: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                return
            }
            let screenHeight = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
                .max() ?? endFrame.maxY
            let keyboardVisibleHeight = max(0, screenHeight - endFrame.minY)
            keyboardHeight = keyboardVisibleHeight
        }
    }

    func bookCard(_ viewModel: NoteEditorViewModel) -> some View {
        Button {
            activeSheet = .book
        } label: {
            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                HStack(spacing: Spacing.base) {
                    if let selectedBook = viewModel.selectedBook {
                        XMBookCover.fixedWidth(
                            34,
                            urlString: selectedBook.coverURL,
                            cornerRadius: CornerRadius.inlayHairline,
                            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                            placeholderIconSize: .small,
                            surfaceStyle: .spine
                        )
                    } else {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayHairline, style: .continuous)
                            .fill(Color.surfaceNested)
                            .frame(width: 34, height: 49)
                            .overlay {
                                Image(systemName: "book.closed")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Color.textHint)
                            }
                    }

                    Text(viewModel.selectedBook?.title ?? "选择书籍")
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textHint)
                }
                .padding(Spacing.contentEdge)
            }
        }
        .buttonStyle(.plain)
    }

    func richTextEditorCard(
        target: NoteEditorComposerTarget,
        text: Binding<NSAttributedString>,
        hint: String,
        controller: RichTextOrnamentController,
        isFocused: Bool,
        height: CGFloat,
        showsInlineOCRButton: Bool,
        onInlineOCR: @escaping () -> Void
    ) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            ZStack(alignment: .topLeading) {
                RichTextEditor(
                    attributedText: text,
                    activeFormats: .constant(Set<RichTextFormat>()),
                    placeholder: hint,
                    isEditable: true,
                    allowsCameraTextCapture: true,
                    toolbarPresentation: .ornament(controller),
                    onFocusChange: { hasFocus in
                        handleEditorFocusChange(target: target, hasFocus: hasFocus)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)

                if text.wrappedValue.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isFocused {
                    Text(hint)
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textHint)
                        .padding(.horizontal, Spacing.base)
                        .padding(.vertical, Spacing.base)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsInlineOCRButton {
                    inlineOCRButton(action: onInlineOCR)
                        .padding(.top, Spacing.half)
                        .padding(.trailing, Spacing.half)
                }
            }
            .frame(height: height)
        }
    }

    func focusIdeaRow(_ viewModel: NoteEditorViewModel, height: CGFloat) -> some View {
        Button {
            openIdeaComposerFromFocusRow()
        } label: {
            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                HStack(spacing: Spacing.base) {
                    Text(focusIdeaRowText(viewModel))
                        .font(AppTypography.body)
                        .foregroundStyle(hasIdeaContent(viewModel) ? Color.textPrimary : Color.textHint)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.base)
                .frame(height: height)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("想法")
        .accessibilityHint("点击全屏编辑")
    }

    func focusIdeaRowText(_ viewModel: NoteEditorViewModel) -> String {
        let preview = viewModel.ideaText.string
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return preview.isEmpty ? "想法" : preview
    }

    func inlineOCRButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 30, height: 30)
                .background(Color.controlFillSecondary, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("OCR")
    }

    func autoSaveCard(_ description: String) -> some View {
        CardContainer(cornerRadius: CornerRadius.blockLarge, showsBorder: false) {
            HStack(spacing: Spacing.cozy) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.brand)
                Text(description)
                    .font(AppTypography.semantic(.footnote, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.base)
        }
    }

    func imageSection(_ viewModel: NoteEditorViewModel) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack {
                    Text("附图")
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    PhotosPicker(
                        selection: $attachmentPhotoItems,
                        maxSelectionCount: 9,
                        matching: .images
                    ) {
                        HStack(spacing: Spacing.half) {
                            Image(systemName: "plus")
                            Text("添加图片")
                        }
                        .font(AppTypography.semantic(.footnote, weight: .medium))
                        .foregroundStyle(Color.brand)
                    }
                    .disabled(viewModel.isSaving)
                }

                if viewModel.imageItems.isEmpty {
                    Text("暂无附图")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textHint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Spacing.cozy)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.base) {
                            ForEach(viewModel.imageItems) { item in
                                NoteEditorImageCell(item: item) {
                                    Task { await viewModel.removeImage(item) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    func metadataSection(_ viewModel: NoteEditorViewModel) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("书摘信息")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                VStack(spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Text(viewModel.positionTitle)
                            .font(AppTypography.semantic(.footnote, weight: .medium))
                            .foregroundStyle(Color.textSecondary)

                        TextField(viewModel.positionPlaceholder, text: Binding(
                            get: { viewModel.positionText },
                            set: { viewModel.positionText = $0 }
                        ))
                        .font(AppTypography.body)
                        .keyboardType(viewModel.positionUnit == 2 ? .decimalPad : .numberPad)
                        .padding(.horizontal, Spacing.base)
                        .frame(height: 44)
                        .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                    }

                    metadataButtonRow(title: "章节", value: viewModel.selectedChapterDisplayTitle) {
                        activeSheet = .chapter
                    }

                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        metadataButtonRow(title: "标签", value: viewModel.selectedTags.isEmpty ? "添加标签" : "已选 \(viewModel.selectedTags.count) 个") {
                            activeSheet = .tags
                        }

                        if !viewModel.selectedTags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Spacing.cozy) {
                                    ForEach(viewModel.selectedTags) { tag in
                                        Text(tag.title)
                                            .font(AppTypography.semantic(.footnote, weight: .medium))
                                            .foregroundStyle(Color.brand)
                                            .padding(.horizontal, Spacing.cozy)
                                            .padding(.vertical, Spacing.tiny)
                                            .background(Color.brand.opacity(0.12), in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    metadataButtonRow(title: "创建时间", value: viewModel.createdDateDescription) {
                        activeSheet = .createdDate
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    func metadataButtonRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.semantic(.footnote, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                Text(value)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textHint)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 44)
            .background(Color.surfaceNested, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    func errorCard(_ message: String) -> some View {
        CardContainer(cornerRadius: CornerRadius.blockLarge, showsBorder: false) {
            Text(message)
                .font(AppTypography.footnote)
                .foregroundStyle(Color.feedbackError)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.contentEdge)
        }
    }

    func editorToolbar(_ viewModel: NoteEditorViewModel) -> some View {
        let controller = activeOrnamentController
        return NoteEditorFloatingToolbar(
            activeFormats: controller?.activeFormats ?? [],
            canEdit: activeEditorTarget != nil,
            canUndo: controller?.canUndo ?? false,
            canRedo: controller?.canRedo ?? false,
            canCaptureTextFromCamera: controller?.canCaptureTextFromCamera ?? false,
            canSave: !viewModel.isSaving,
            showsOCRButton: !usesSplitOCREntryButtons,
            onUndo: { sendToolbarCommand(.undo) },
            onRedo: { sendToolbarCommand(.redo) },
            onMoveCursorLeft: { sendToolbarCommand(.moveCursorLeft) },
            onMoveCursorRight: { sendToolbarCommand(.moveCursorRight) },
            onToggleFormat: { format in
                sendToolbarCommand(.toggleFormat(format))
            },
            onIndent: { sendToolbarCommand(.indent) },
            onClearFormats: { sendToolbarCommand(.clearFormats) },
            onOCR: {
                registerEditorInteraction(force: true)
                guard activeEditorTarget != nil else {
                    toolbarPromptMessage = "请先点选“摘录”或“想法”输入框"
                    return
                }
                guard (activeOrnamentController?.canCaptureTextFromCamera == true) || supportsPhotoOCR else {
                    toolbarPromptMessage = "当前设备不支持 OCR"
                    return
                }
                showsOCRChooser = true
            },
            onFullscreen: {
                registerEditorInteraction(force: true)
                guard let target = activeEditorTarget else {
                    toolbarPromptMessage = "请先点选“摘录”或“想法”输入框"
                    return
                }
                lastClosedComposerTarget = target
                activeComposer = target
            },
            onChooseImage: {
                registerEditorInteraction(force: true)
                toolbarPromptMessage = nil
                showsAttachmentPicker = true
            },
            onSave: {
                registerEditorInteraction(force: true)
                toolbarPromptMessage = nil
                Task { _ = await viewModel.save() }
            }
        )
    }

    func sendToolbarCommand(_ command: RichTextToolbarCommand) {
        registerEditorInteraction()
        guard let controller = activeOrnamentController else {
            toolbarPromptMessage = "请先点选“摘录”或“想法”输入框"
            return
        }
        toolbarPromptMessage = nil
        controller.send(command)
    }

    func handleLayoutModeStateChange(animated _: Bool) {
        guard layoutMode == .focusExcerpt else { return }
        clearIdeaInlineEditingStateForFocusLayout()
    }

    func clearIdeaInlineEditingStateForFocusLayout() {
        if activeEditorTarget == .idea || isIdeaFocused {
            ideaOrnamentController.send(.dismissKeyboard)
            if activeEditorTarget == .idea {
                activeEditorTarget = nil
            }
            isIdeaFocused = false
        }
    }

    func hasIdeaContent(_ viewModel: NoteEditorViewModel) -> Bool {
        !viewModel.ideaText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func handleEditorFocusChange(
        target: NoteEditorComposerTarget,
        hasFocus: Bool
    ) {
        registerEditorInteraction()
        toolbarPromptMessage = nil

        switch target {
        case .content:
            isContentFocused = hasFocus
            if hasFocus {
                activeEditorTarget = .content
            } else if activeEditorTarget == .content {
                activeEditorTarget = nil
            }
        case .idea:
            isIdeaFocused = hasFocus
            if hasFocus {
                activeEditorTarget = .idea
            } else {
                if activeEditorTarget == .idea {
                    activeEditorTarget = nil
                }
            }
        }
    }

    var shouldContinueEditingAfterSave: Bool {
        guard editorSettings.continueEditEnabled else { return false }
        if case .create = mode {
            return true
        }
        return false
    }

    func continueEditingAfterSave(using viewModel: NoteEditorViewModel) async {
        await viewModel.prepareForContinuousEditing(preferredBookID: viewModel.selectedBook?.id)
        toolbarPromptMessage = nil
        activeEditorTarget = .content
        lastClosedComposerTarget = nil
        handleLayoutModeStateChange(animated: false)
        DispatchQueue.main.async {
            contentOrnamentController.send(.focus)
            contentOrnamentController.send(.moveCursorToEnd)
        }
    }

    func triggerInlineOCR(for target: NoteEditorComposerTarget) {
        registerEditorInteraction(force: true)
        toolbarPromptMessage = nil
        activeEditorTarget = target
        let controller = ornamentController(for: target)
        controller.send(.focus)

        guard controller.canCaptureTextFromCamera || supportsPhotoOCR else {
            toolbarPromptMessage = "当前设备不支持 OCR"
            return
        }
        showsOCRChooser = true
    }

    func openIdeaComposerFromFocusRow() {
        registerEditorInteraction(force: true)
        toolbarPromptMessage = nil
        contentOrnamentController.send(.dismissKeyboard)
        if activeEditorTarget == .content {
            activeEditorTarget = nil
        }
        isContentFocused = false
        clearIdeaInlineEditingStateForFocusLayout()
        lastClosedComposerTarget = .idea
        activeComposer = .idea
    }

    func ornamentController(for target: NoteEditorComposerTarget) -> RichTextOrnamentController {
        switch target {
        case .content:
            return contentOrnamentController
        case .idea:
            return ideaOrnamentController
        }
    }

    func captureScreenBehaviorBaselineIfNeeded() {
        if baselineIdleTimerDisabled == nil {
            baselineIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        if baselineScreenBrightness == nil {
            baselineScreenBrightness = activeWindowScreen()?.brightness
        }
    }

    func applyScreenBehavior() {
        guard let baselineIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = baselineIdleTimerDisabled || editorSettings.keepScreenOnEnabled
    }

    func restoreScreenBrightness() {
        guard let baselineScreenBrightness else { return }
        activeWindowScreen()?.brightness = baselineScreenBrightness
    }

    func registerEditorInteraction(force: Bool = false) {
        guard scenePhase == .active else { return }
        if !force {
            let now = Date()
            guard now.timeIntervalSince(lastInteractionDate) >= 0.15 else { return }
            lastInteractionDate = now
        } else {
            lastInteractionDate = Date()
        }

        autoDimTask?.cancel()
        autoDimTask = nil
        restoreScreenBrightness()

        guard editorSettings.autoDimSeconds > 0 else { return }
        let dimDelay = editorSettings.autoDimSeconds
        let targetBrightness = CGFloat(editorSettings.autoDimBrightness)
        autoDimTask = Task {
            try? await Task.sleep(for: .seconds(Double(dimDelay)))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                activeWindowScreen()?.brightness = targetBrightness
            }
        }
    }

    func activeWindowScreen() -> UIScreen? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?.screen
            ?? scenes.first?.screen
    }

    func releaseScreenBehavior() {
        autoDimTask?.cancel()
        autoDimTask = nil
        restoreScreenBrightness()
        if let baselineIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = baselineIdleTimerDisabled
        }
        baselineIdleTimerDisabled = nil
        baselineScreenBrightness = nil
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            captureScreenBehaviorBaselineIfNeeded()
            applyScreenBehavior()
            registerEditorInteraction(force: true)
        case .inactive, .background:
            autoDimTask?.cancel()
            autoDimTask = nil
            restoreScreenBrightness()
            if let baselineIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = baselineIdleTimerDisabled
            }
        @unknown default:
            break
        }
    }

    func editorHeights(
        for viewportHeight: CGFloat,
        bookSectionHeight: CGFloat,
        tailSectionHeight: CGFloat
    ) -> (content: CGFloat, idea: CGFloat) {
        let defaultEditorHeight: CGFloat = 180
        let collapsedIdeaHeight: CGFloat = 48
        let stackOuterPadding = Spacing.base + max(Spacing.section, (measuredHeights[.toolbar] ?? 0) + Spacing.base)
        let sectionGaps = Spacing.base * 3
        let fixedElementsHeight = bookSectionHeight + tailSectionHeight + stackOuterPadding + sectionGaps
        let availableForEditors = max(viewportHeight - fixedElementsHeight, 0)
        let isKeyboardVisible = keyboardHeight > 0

        switch layoutMode {
        case .classic:
            return (defaultEditorHeight, defaultEditorHeight)
        case .focusExcerpt:
            let contentAvailable = availableForEditors - collapsedIdeaHeight
            let contentHeight: CGFloat
            if isKeyboardVisible {
                contentHeight = max(contentAvailable, 0)
            } else if contentAvailable >= defaultEditorHeight {
                contentHeight = contentAvailable
            } else {
                let fallbackFullViewport = max(viewportHeight - collapsedIdeaHeight - Spacing.base, 0)
                contentHeight = max(fallbackFullViewport, defaultEditorHeight)
            }
            return (contentHeight, collapsedIdeaHeight)
        }
    }

    func restoreEditorFocusAfterComposerDismiss() {
        let target = lastClosedComposerTarget ?? activeEditorTarget ?? .content
        lastClosedComposerTarget = nil

        if target == .idea, layoutMode == .focusExcerpt {
            contentOrnamentController.send(.dismissKeyboard)
            ideaOrnamentController.send(.dismissKeyboard)
            activeEditorTarget = nil
            isContentFocused = false
            isIdeaFocused = false
            return
        }

        activeEditorTarget = target
        let controller = (target == .content) ? contentOrnamentController : ideaOrnamentController
        DispatchQueue.main.async {
            controller.send(.focus)
            controller.send(.moveCursorToEnd)
        }
    }

    func handleDismissAttempt(using viewModel: NoteEditorViewModel) {
        guard !viewModel.isSaving else { return }
        if viewModel.hasUnsavedChanges {
            showsDiscardDialog = true
        } else {
            dismiss()
        }
    }

    func consumeAttachmentPhotoItems(_ items: [PhotosPickerItem], viewModel: NoteEditorViewModel) async {
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                await viewModel.stageImage(data: data, fileExtension: fileExtension)
            } catch {
                viewModel.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

enum NoteEditorLayoutMode: Int, CaseIterable, Identifiable {
    case classic = 0
    case focusExcerpt = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .classic:
            return "经典布局"
        case .focusExcerpt:
            return "专注书摘"
        }
    }
}

private extension NoteEditorComposerTarget {
    var scrollAnchorID: String {
        switch self {
        case .content:
            return "note_editor_content_anchor"
        case .idea:
            return "note_editor_idea_anchor"
        }
    }
}

private struct NoteEditorFloatingToolbar: View {
    let activeFormats: Set<RichTextFormat>
    let canEdit: Bool
    let canUndo: Bool
    let canRedo: Bool
    let canCaptureTextFromCamera: Bool
    let canSave: Bool
    let showsOCRButton: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onMoveCursorLeft: () -> Void
    let onMoveCursorRight: () -> Void
    let onToggleFormat: (RichTextFormat) -> Void
    let onIndent: () -> Void
    let onClearFormats: () -> Void
    let onOCR: () -> Void
    let onFullscreen: () -> Void
    let onChooseImage: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: Spacing.tight) {
                HStack(spacing: Spacing.tight) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.tight) {
                            toolbarIconButton("arrow.uturn.backward", enabled: canEdit && canUndo, action: onUndo)
                            toolbarIconButton("arrow.uturn.forward", enabled: canEdit && canRedo, action: onRedo)
                            toolbarIconButton("arrow.left", enabled: canEdit, action: onMoveCursorLeft)
                            toolbarIconButton("arrow.right", enabled: canEdit, action: onMoveCursorRight)

                            toolbarDivider
                            formatButton(.bold, icon: "bold")
                            formatButton(.italic, icon: "italic")
                            formatButton(.underline, icon: "underline")
                            formatButton(.strikethrough, icon: "strikethrough")
                            formatButton(.highlight, icon: "highlighter")
                            toolbarIconButton("increase.indent", enabled: canEdit, action: onIndent)

                            toolbarDivider
                            toolbarIconButton("textformat", enabled: canEdit, action: onClearFormats)

                            if showsOCRButton {
                                toolbarDivider
                                toolbarIconButton("text.viewfinder", enabled: canEdit || canCaptureTextFromCamera, action: onOCR)
                            }
                            toolbarDivider
                            toolbarIconButton("photo.on.rectangle.angled", enabled: true, action: onChooseImage)
                            toolbarIconButton("arrow.up.left.and.arrow.down.right", enabled: canEdit, action: onFullscreen)
                        }
                    }
                    .frame(maxWidth: 500)

                    toolbarDivider
                    toolbarTextButton("保存", enabled: canSave, action: onSave)
                }
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.cozy)
            }
            .glassEffect(.regular, in: .capsule)
            .allowsHitTesting(true)
            .padding(.bottom, Spacing.cozy)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .allowsHitTesting(false)
        .background(Color.clear)
    }

    var toolbarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 1, height: 18)
    }

    func formatButton(_ format: RichTextFormat, icon: String, enabled: Bool? = nil) -> some View {
        let isEnabled: Bool
        if let enabled {
            isEnabled = enabled
        } else {
            isEnabled = canEdit
        }
        return toolbarIconButton(
            icon,
            enabled: isEnabled,
            isActive: activeFormats.contains(format),
            action: { onToggleFormat(format) }
        )
    }

    func toolbarIconButton(
        _ icon: String,
        enabled: Bool,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Color.textPrimary : Color.textHint)
                .frame(width: 34, height: 34)
                .background(
                    isActive ? Color.brand.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    func toolbarTextButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.semantic(.footnote, weight: .semibold))
                .foregroundStyle(enabled ? Color.textPrimary : Color.textHint)
                .padding(.horizontal, Spacing.base)
                .frame(height: 34)
                .background(
                    enabled ? Color.brand.opacity(0.16) : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private enum NoteEditorSheet: String, Identifiable {
    case book
    case chapter
    case tags
    case createdDate
    case settings

    var id: String { rawValue }
}

private struct NoteEditorImageCell: View {
    let item: NoteEditorImageItem
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let localFilePath = item.localFilePath,
                   let image = UIImage(contentsOfFile: localFilePath) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if let remoteURL = item.remoteURL, !remoteURL.isEmpty {
                    XMRemoteImage(urlString: remoteURL) {
                        RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                            .fill(Color.surfaceNested)
                    }
                    .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .fill(Color.surfaceNested)
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.65), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(Spacing.compact)
        }
    }
}

private struct NoteEditorBookPickerSheet: View {
    let books: [NoteEditorBookOption]
    let onSelect: (NoteEditorBookOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var filteredBooks: [NoteEditorBookOption] {
        guard !searchText.isEmpty else { return books }
        return books.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.author.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            List(filteredBooks) { book in
                Button {
                    onSelect(book)
                } label: {
                    HStack(spacing: Spacing.base) {
                        XMBookCover.fixedWidth(
                            44,
                            urlString: book.coverURL,
                            cornerRadius: CornerRadius.inlayHairline,
                            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                            placeholderIconSize: .small,
                            surfaceStyle: .spine
                        )

                        Text(book.title)
                            .font(AppTypography.subheadlineSemibold)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)

                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("选择书籍")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索书名或作者")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TopBarGlassBackButton {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct NoteEditorChapterPickerSheet: View {
    let chapters: [NoteEditorChapterOption]
    let selectedChapterID: Int64
    let onSelect: (NoteEditorChapterOption?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                } label: {
                    HStack {
                        Text("不设置章节")
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        if selectedChapterID == 0 {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.brand)
                        }
                    }
                }
                .buttonStyle(.plain)

                ForEach(chapters) { chapter in
                    Button {
                        onSelect(chapter)
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            if selectedChapterID == chapter.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.brand)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("章节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TopBarGlassBackButton {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct NoteEditorTagPickerSheet: View {
    let availableTags: [NoteEditorTagOption]
    let selectedTags: [NoteEditorTagOption]
    let onToggle: (NoteEditorTagOption) -> Void
    let onCreate: @MainActor @Sendable (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var inputText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("已选标签") {
                    if selectedTags.isEmpty {
                        Text("暂未选择标签")
                            .foregroundStyle(Color.textHint)
                    } else {
                        ForEach(selectedTags) { tag in
                            Text(tag.title)
                                .foregroundStyle(Color.textPrimary)
                        }
                    }
                }

                Section("全部标签") {
                    ForEach(availableTags) { tag in
                        Button {
                            onToggle(tag)
                        } label: {
                            HStack {
                                Text(tag.title)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                if selectedTags.contains(where: { $0.id == tag.id }) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.brand)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("新增标签") {
                    TextField("输入后创建并选中", text: $inputText)
                    Button("创建标签") {
                        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        Task {
                            await onCreate(text)
                            inputText = ""
                        }
                    }
                }
            }
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TopBarGlassBackButton {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct NoteEditorDateSheet: View {
    @Binding var selectedDate: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.base) {
                DatePicker(
                    "创建时间",
                    selection: $selectedDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)

                Spacer(minLength: 0)
            }
            .padding(Spacing.screenEdge)
            .navigationTitle("创建时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TopBarGlassBackButton {
                        dismiss()
                    }
                }
            }
        }
    }
}

private enum NoteEditorMeasuredPart: Hashable {
    case toolbar
    case book
    case tail
}

private struct NoteEditorMeasuredHeightsPreferenceKey: PreferenceKey {
    static var defaultValue: [NoteEditorMeasuredPart: CGFloat] = [:]

    static func reduce(value: inout [NoteEditorMeasuredPart: CGFloat], nextValue: () -> [NoteEditorMeasuredPart: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func noteEditorReportHeight(_ part: NoteEditorMeasuredPart) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: NoteEditorMeasuredHeightsPreferenceKey.self,
                    value: [part: proxy.size.height]
                )
            }
        )
    }
}
