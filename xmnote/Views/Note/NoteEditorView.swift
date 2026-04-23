/**
 * [INPUT]: 依赖 RepositoryContainer 注入 NoteRepository，依赖 NoteEditorViewModel 驱动完整书摘编辑状态，依赖 NoteTextComposerView 与 BookPickerView 承接富文本输入和书籍选择
 * [OUTPUT]: 对外提供 NoteEditorView，承载书摘新建/编辑、草稿恢复、附图、章节/标签与保存动作
 * [POS]: Note 模块书摘编辑页壳层，对齐 Android 编辑流程并采用 iOS 原生页面组织
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import PhotosUI
import SwiftUI
import UIKit
import os

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
    @State private var closeFlowState: NoteEditorCloseFlowState = .idle
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
    @State private var focusExcerptTransition: NoteEditorFocusExcerptTransition = .idle
    @State private var layoutFreezeContext: NoteEditorLayoutFreezeContext?
    @State private var pendingCollapseAfterKeyboardHide = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var isKeyboardAnimatingOut = false
    @State private var lastClosedComposerTarget: NoteEditorComposerTarget?
    @State private var baselineIdleTimerDisabled: Bool?
    @State private var baselineScreenBrightness: CGFloat?
    @State private var autoDimTask: Task<Void, Never>?
    @State private var lastInteractionDate = Date.distantPast
    @State private var isLayoutStateInitialized = false
    @FocusState private var isPositionFocused: Bool
#if DEBUG
    @State private var lastLoggedTextChangeContextByTarget: [String: String] = [:]
    @State private var lastObservedTextLengthByTarget: [String: Int] = [:]
    private let expandLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "NoteEditorExpand"
    )
#endif

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
    var isKeyboardVisible: Bool { keyboardHeight > 0 }
    var effectiveMeasuredHeights: [NoteEditorMeasuredPart: CGFloat] {
        if let layoutFreezeContext {
            return layoutFreezeContext.measuredHeights
        }
        return measuredHeights
    }
    var measuredHeightEpsilon: CGFloat { 0.5 }
    var effectiveKeyboardVisible: Bool {
        closeFlowState.keyboardVisibleSnapshot
            ?? layoutFreezeContext?.keyboardVisible
            ?? isKeyboardVisible
    }
    var isCloseFlowActive: Bool {
        closeFlowState.isActive
    }
    var isFocusExcerptLayoutAnimating: Bool {
        focusExcerptTransition != .idle || layoutFreezeContext?.source == .focusExcerptTransition
    }
    var discardDialogBinding: Binding<Bool> {
        Binding(
            get: { closeFlowState.isConfirmingDiscard },
            set: { isPresented in
                guard !isPresented else { return }
                guard closeFlowState.isConfirmingDiscard else { return }
                transitionCloseFlow(to: .idle, reason: "discard_dialog_closed")
            }
        )
    }
    var seededMeasuredHeights: [NoteEditorMeasuredPart: CGFloat] {
        [
            .book: 49 + Spacing.contentEdge * 2,
            .tailStable: metadataRowHeight * 4 + CardStyle.borderWidth * 3,
            .toolbar: 58
        ]
    }
    var editorContentFont: Font {
        AppTypography.fixed(
            baseSize: 16,
            relativeTo: .body,
            minimumPointSize: 16
        )
    }

    @ViewBuilder
    func noteEditorAlertPresenter(_ viewModel: NoteEditorViewModel) -> some View {
        let recoveredDraftBinding = Binding(
            get: { viewModel.pendingRecoveredDraft },
            set: { viewModel.pendingRecoveredDraft = $0 }
        )
        Color.clear
            .xmSystemAlert(
                isPresented: recoveredDraftBinding.isPresented {
                    viewModel.discardRecoveredDraft()
                },
                descriptor: XMSystemAlertDescriptor(
                    title: "发现自动保存草稿",
                    message: "检测到这条书摘有未提交的自动保存内容，是否恢复继续编辑？",
                    actions: [
                        XMSystemAlertAction(title: "恢复") {
                            viewModel.restoreRecoveredDraft()
                        },
                        XMSystemAlertAction(title: "丢弃", role: .destructive) {
                            viewModel.discardRecoveredDraft()
                        }
                    ]
                )
            )
            .xmSystemAlert(
                isPresented: discardDialogBinding,
                descriptor: XMSystemAlertDescriptor(
                    title: "提示",
                    message: "你编辑的内容尚未保存，确定要离开么？",
                    actions: [
                        XMSystemAlertAction(title: "继续编辑") { },
                        XMSystemAlertAction(title: "保存") {
                            beginSaveAndClose(using: viewModel)
                        },
                        XMSystemAlertAction(title: "离开", role: .destructive) {
                            beginDiscardAndClose(using: viewModel)
                        }
                    ]
                )
            )
    }

    func editorContent(_ viewModel: NoteEditorViewModel) -> some View {
        GeometryReader { geometry in
            let layoutInputs = makeFocusExcerptLayoutInputs(
                measuredHeights: effectiveMeasuredHeights,
                keyboardVisible: effectiveKeyboardVisible
            )
            let heightsSource = layoutInputs.measuredHeights
            let heightComputation = makeEditorHeightComputation(
                for: geometry.size.height,
                bookSectionHeight: heightsSource[.book] ?? 0,
                stableTailSectionHeight: heightsSource[.tailStable] ?? 0,
                measuredTailSectionHeight: heightsSource[.tail] ?? 0,
                toolbarHeight: heightsSource[.toolbar] ?? 0,
                ideaState: viewModel.ideaInputState,
                keyboardVisible: layoutInputs.keyboardVisible,
                usedSeededMeasurements: layoutInputs.usedSeededMeasurements
            )
            let heights = (content: heightComputation.contentHeight, idea: heightComputation.ideaHeight)
            let scrollBottomPadding = max(Spacing.section, (heightsSource[.toolbar] ?? 0) + Spacing.base)

            ZStack {
                Color.surfacePage.ignoresSafeArea()

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Spacing.base) {
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
                                onTextChange: { handleEditorTextChange(target: .content, text: viewModel.contentText) },
                                onInlineOCR: { triggerInlineOCR(for: .content) }
                            )
                            .id(NoteEditorComposerTarget.content.scrollAnchorID)

                            if layoutMode == .focusExcerpt {
                                focusIdeaInlineCard(
                                    viewModel,
                                    height: heights.idea,
                                    showsInlineOCRButton: usesSplitOCREntryButtons,
                                    onTextChange: { handleEditorTextChange(target: .idea, text: viewModel.ideaText) },
                                    onInlineOCR: { triggerInlineOCR(for: .idea) }
                                )
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
                                    onTextChange: { handleEditorTextChange(target: .idea, text: viewModel.ideaText) },
                                    onInlineOCR: { triggerInlineOCR(for: .idea) }
                                )
                                .id(NoteEditorComposerTarget.idea.scrollAnchorID)
                            }

                            VStack(alignment: .leading, spacing: Spacing.base) {
                                if let autoSaveDescription = viewModel.autoSaveDescription {
                                    autoSaveCard(autoSaveDescription)
                                }

                                if !viewModel.imageItems.isEmpty {
                                    imageSection(viewModel)
                                        .transition(.move(edge: .top).combined(with: .opacity))
                                }
                                metadataSection(viewModel)
                                    .noteEditorReportHeight(.tailStable)

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
#if DEBUG
                    .overlay {
                        heightDiagnosticsProbe(
                            viewModel: viewModel,
                            viewportHeight: geometry.size.height,
                            computation: heightComputation
                        )
                    }
#endif
                    .onChange(of: activeEditorTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.snappy) {
                            scrollProxy.scrollTo(target.scrollAnchorID, anchor: .center)
                        }
                    }
                    .onChange(of: viewModel.ideaInputState) { _, newState in
#if DEBUG
                        let branch = (newState == .collapsed) ? "collapsed_row" : "editor"
                        logExpandEvent(
                            "idea.ui.branch",
                            viewModel: viewModel,
                            extra: "branch=\(branch)"
                        )
#endif
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
            canPop: closeFlowState == .idle && !viewModel.hasUnsavedChanges && !viewModel.isSaving,
            onBlockedAttempt: {
                requestClose(using: viewModel, source: .navigationGesture)
            }
        )
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TopBarBackButton(
                    action: {
                        requestClose(using: viewModel, source: .toolbarButton)
                    },
                    foregroundColor: .textPrimary
                )
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
                BookPickerView(
                    configuration: BookPickerConfiguration(
                        scope: .local,
                        selectionMode: .single,
                        allowsCreationFlow: true,
                        creationAction: .nestedSearchPage,
                        preselectedBooks: viewModel.selectedBook.map { [$0] } ?? []
                    ),
                    onComplete: { result in
                        switch result {
                        case .cancelled:
                            break
                        case .single(let selection):
                            if case .local(let book) = selection {
                                viewModel.selectBook(book)
                            }
                        case .multiple:
                            break
                        case .addFlowRequested:
                            break
                        }
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
                            viewModel.setCreatedDateManually(newValue)
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
        .background {
            noteEditorAlertPresenter(viewModel)
        }
        .task(id: attachmentPhotoItems) {
            guard !attachmentPhotoItems.isEmpty else { return }
            await consumeAttachmentPhotoItems(attachmentPhotoItems, viewModel: viewModel)
            attachmentPhotoItems = []
        }
        .onPreferenceChange(NoteEditorMeasuredHeightsPreferenceKey.self) { values in
            mergeMeasuredHeights(values)
        }
        .onAppear {
#if DEBUG
            logExpandEvent(
                "layout.appear",
                viewModel: viewModel,
                extra: "layoutMode=\(layoutMode.rawValue) measured=[\(describeMeasuredHeights(effectiveMeasuredHeights))]"
            )
#endif
            handleLayoutModeStateChange(animated: false)
            captureScreenBehaviorBaselineIfNeeded()
            applyScreenBehavior()
            registerEditorInteraction(force: true)
            if !isLayoutStateInitialized {
                DispatchQueue.main.async {
                    isLayoutStateInitialized = true
                }
            }
        }
        .onDisappear {
            releaseScreenBehavior()
            resetFocusExcerptCoordination(reason: "view_disappear")
            clearLayoutFreezeContext(source: .closeFlow, reason: "view_disappear")
            closeFlowState = .idle
        }
        .onChange(of: editorSettings.layoutModeRawValue) { _, _ in
            handleLayoutModeStateChange(animated: isLayoutStateInitialized)
        }
        .onChange(of: viewModel.didSave) { _, didSave in
            guard didSave else { return }
            if closeFlowState.isSavingAndClosing {
                dismiss()
                return
            }
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
            isKeyboardAnimatingOut = true
            let previousHeight = keyboardHeight
            keyboardHeight = 0
#if DEBUG
            if previousHeight > measuredHeightEpsilon {
                logExpandEvent(
                    "keyboard.hide",
                    viewModel: viewModel,
                    extra: "previous=\(formatHeight(previousHeight)) next=0"
                )
            }
#endif
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardHeight = 0
            isKeyboardAnimatingOut = false
            guard pendingCollapseAfterKeyboardHide else { return }
            performIdeaCollapse(reason: "keyboard_did_hide")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                return
            }
            let screenHeight = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds.height }
                .max() ?? endFrame.maxY
            let keyboardVisibleHeight = max(0, screenHeight - endFrame.minY)
            let previousHeight = keyboardHeight
            keyboardHeight = keyboardVisibleHeight
            if keyboardVisibleHeight > measuredHeightEpsilon {
                isKeyboardAnimatingOut = false
            }
#if DEBUG
            if abs(previousHeight - keyboardVisibleHeight) > measuredHeightEpsilon {
                logExpandEvent(
                    "keyboard.frame.change",
                    viewModel: viewModel,
                    extra: "previous=\(formatHeight(previousHeight)) next=\(formatHeight(keyboardVisibleHeight)) endMinY=\(formatHeight(endFrame.minY))"
                )
            }
#endif
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
        onTextChange: @escaping () -> Void,
        onInlineOCR: @escaping () -> Void
    ) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            ZStack(alignment: .topLeading) {
                RichTextEditor(
                    attributedText: text,
                    activeFormats: .constant(Set<RichTextFormat>()),
                    placeholder: hint,
                    isEditable: true,
                    baseFont: NoteEditorViewModel.editorBaseUIFont,
                    allowsCameraTextCapture: true,
                    toolbarPresentation: .ornament(controller),
                    onTextChange: onTextChange,
                    onFocusChange: { hasFocus in
                        handleEditorFocusChange(target: target, hasFocus: hasFocus)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)

                if text.wrappedValue.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isFocused {
                    Text(hint)
                        .font(editorContentFont)
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

    func focusIdeaInlineCard(
        _ viewModel: NoteEditorViewModel,
        height: CGFloat,
        showsInlineOCRButton: Bool,
        onTextChange: @escaping () -> Void,
        onInlineOCR: @escaping () -> Void
    ) -> some View {
        let isCollapsed = viewModel.ideaInputState == .collapsed
        return CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            ZStack(alignment: .topLeading) {
                RichTextEditor(
                    attributedText: viewModel.binding(for: .idea),
                    activeFormats: .constant(Set<RichTextFormat>()),
                    placeholder: "想法",
                    isEditable: true,
                    baseFont: NoteEditorViewModel.editorBaseUIFont,
                    allowsCameraTextCapture: true,
                    toolbarPresentation: .ornament(ideaOrnamentController),
                    onTextChange: onTextChange,
                    onFocusChange: { hasFocus in
                        handleEditorFocusChange(target: .idea, hasFocus: hasFocus)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
                .allowsHitTesting(!isCollapsed)
                .opacity(isCollapsed ? 0.01 : 1)

                if viewModel.ideaText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !isIdeaFocused
                    && !isCollapsed {
                    Text("想法")
                        .font(editorContentFont)
                        .foregroundStyle(Color.textHint)
                        .padding(.horizontal, Spacing.base)
                        .padding(.vertical, Spacing.base)
                        .allowsHitTesting(false)
                }

                if isCollapsed {
                    focusIdeaCollapsedOverlay(viewModel, height: height)
                }
            }
            .overlay(alignment: .topTrailing) {
                if showsInlineOCRButton && !isCollapsed {
                    inlineOCRButton(action: onInlineOCR)
                        .padding(.top, Spacing.half)
                        .padding(.trailing, Spacing.half)
                }
            }
            .frame(height: height)
        }
    }

    func focusIdeaCollapsedOverlay(_ viewModel: NoteEditorViewModel, height: CGFloat) -> some View {
        Button {
            openIdeaComposerFromFocusRow()
        } label: {
            HStack(spacing: Spacing.cozy) {
                Text(focusIdeaRowText(viewModel))
                    .font(editorContentFont)
                    .foregroundStyle(viewModel.hasIdeaText ? Color.textPrimary : Color.textHint)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("想法")
        .accessibilityHint("点击展开编辑")
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
            XMAttachmentUploadStrip(
                items: viewModel.imageItems.map { item in
                    let uploadState: XMAttachmentUploadState
                    switch item.uploadState {
                    case .uploading:
                        uploadState = .uploading
                    case .success:
                        uploadState = .success
                    case .failed:
                        uploadState = .failed
                    }
                    return XMAttachmentUploadItem(
                        id: item.id,
                        localFilePath: item.localFilePath,
                        remoteURL: item.remoteURL,
                        uploadState: uploadState
                    )
                },
                allowsFullScreenPreview: true,
                accessibilityNamespace: "note_editor.attachment_strip",
                onMove: { sourceID, destinationID in
                    registerEditorInteraction(force: true)
                    withAnimation(.snappy(duration: 0.2)) {
                        viewModel.moveImage(sourceID: sourceID, destinationID: destinationID)
                    }
                },
                onRemove: { id in
                    registerEditorInteraction(force: true)
                    #if DEBUG
                    logExpandEvent("attach.remove.tap", viewModel: viewModel, extra: "id=\(id)")
                    #endif
                    guard let item = viewModel.imageItems.first(where: { $0.id == id }) else {
                        #if DEBUG
                        let currentIDs = viewModel.imageItems.map(\.id).joined(separator: ",")
                        logExpandEvent("attach.remove.miss", viewModel: viewModel, extra: "id=\(id) currentIDs=[\(currentIDs)]")
                        #endif
                        return
                    }
                    #if DEBUG
                    logExpandEvent("attach.remove.dispatch", viewModel: viewModel, extra: "id=\(id)")
                    #endif
                    Task { @MainActor in
                        await viewModel.removeImage(item)
                    }
                },
                onRetry: { id in
                    registerEditorInteraction(force: true)
                    guard let item = viewModel.imageItems.first(where: { $0.id == id }) else { return }
                    viewModel.retryImageUpload(item)
                },
                onTap: { _ in
                    registerEditorInteraction(force: true)
                }
            )
            .padding(Spacing.contentEdge)
        }
    }

    func metadataSection(_ viewModel: NoteEditorViewModel) -> some View {
        VStack(spacing: Spacing.none) {
            HStack(spacing: Spacing.cozy) {
                Text(viewModel.positionTitle)
                    .font(metadataTitleFont)
                    .foregroundStyle(Color.textSecondary)
                Spacer(minLength: Spacing.base)
                TextField(viewModel.positionPlaceholder, text: Binding(
                    get: { viewModel.positionText },
                    set: { viewModel.positionText = $0 }
                ))
                .focused($isPositionFocused)
                .font(metadataValueFont)
                .foregroundStyle(Color.textPrimary)
                .keyboardType(viewModel.positionUnit == 2 ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.plain)
                .frame(width: 140)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: metadataRowHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                registerEditorInteraction(force: true)
                toolbarPromptMessage = nil
                isPositionFocused = true
            }

            metadataDivider

            HStack(spacing: Spacing.cozy) {
                Text("章节")
                    .font(metadataTitleFont)
                    .foregroundStyle(Color.textSecondary)
                Spacer(minLength: Spacing.base)
                Text(viewModel.selectedChapterDisplayTitle)
                    .font(metadataValueFont)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                chapterRowAccessory(viewModel)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: metadataRowHeight)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                openMetadataSheet(.chapter)
            }

            metadataDivider

            HStack(spacing: Spacing.cozy) {
                Text("标签")
                    .font(metadataTitleFont)
                    .foregroundStyle(Color.textSecondary)

                if viewModel.selectedTags.isEmpty {
                    Text("添加标签")
                        .font(metadataValueFont)
                        .foregroundStyle(Color.textHint)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.cozy) {
                            ForEach(viewModel.selectedTags) { tag in
                                Text(tag.title)
                                    .font(AppTypography.semantic(.footnote, weight: .medium))
                                    .foregroundStyle(Color.textSecondary)
                                    .padding(.horizontal, Spacing.cozy)
                                    .padding(.vertical, Spacing.tiny)
                                    .background(Color.controlFillSecondary, in: Capsule())
                                    .lineLimit(1)
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        .frame(height: 30)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                metadataTrailingAccessoryIcon()
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: metadataRowHeight)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                openMetadataSheet(.tags)
            }
            .animation(.snappy(duration: 0.22), value: viewModel.selectedTags.map(\.id))

            metadataDivider

            Button {
                openMetadataSheet(.createdDate)
            } label: {
                HStack(spacing: Spacing.cozy) {
                    Text("创建时间")
                        .font(metadataTitleFont)
                        .foregroundStyle(Color.textSecondary)
                    Spacer(minLength: Spacing.base)
                    Text(viewModel.createdDateDescription)
                        .font(metadataValueFont)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    metadataTrailingAccessoryIcon()
                }
                .padding(.horizontal, Spacing.base)
                .frame(height: metadataRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    var metadataTitleFont: Font {
        AppTypography.fixed(
            baseSize: 14,
            relativeTo: .subheadline,
            weight: .medium,
            minimumPointSize: 14
        )
    }

    var metadataValueFont: Font { AppTypography.subheadline }

    var metadataTrailingAccessoryWidth: CGFloat { 12 }

    var metadataRowHeight: CGFloat { 54 }

    var metadataDivider: some View {
        Rectangle()
            .fill(Color.surfaceBorderSubtle)
            .frame(height: CardStyle.borderWidth)
    }

    func metadataTrailingAccessoryIcon(_ systemName: String = "chevron.right") -> some View {
        Image(systemName: systemName)
            .font(AppTypography.captionSemibold)
            .foregroundStyle(Color.textHint)
            .frame(width: metadataTrailingAccessoryWidth, alignment: .trailing)
            .contentShape(Rectangle())
    }

    func chapterRowAccessory(_ viewModel: NoteEditorViewModel) -> some View {
        Group {
            if viewModel.selectedChapterID > 0 {
                Button {
                    registerEditorInteraction(force: true)
                    toolbarPromptMessage = nil
                    withAnimation(.snappy(duration: 0.22)) {
                        viewModel.clearSelectedChapter()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.textHint)
                        .frame(width: metadataTrailingAccessoryWidth, height: metadataTrailingAccessoryWidth)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空章节")
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                metadataTrailingAccessoryIcon()
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: metadataTrailingAccessoryWidth, alignment: .trailing)
        .animation(.snappy(duration: 0.22), value: viewModel.selectedChapterID > 0)
    }

    func openMetadataSheet(_ sheet: NoteEditorSheet) {
        registerEditorInteraction(force: true)
        toolbarPromptMessage = nil
        isPositionFocused = false
        withAnimation(.snappy(duration: 0.22)) {
            activeSheet = sheet
        }
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
            toolbarMode: isPositionFocused ? .imageOnly : .editor,
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

    func requestClose(using viewModel: NoteEditorViewModel, source: DismissAttemptSource) {
        guard closeFlowState == .idle else { return }
        guard !viewModel.isSaving else { return }

        if viewModel.hasUnsavedChanges {
            transitionCloseFlow(
                to: .confirmingDiscard(keyboardVisibleSnapshot: isKeyboardVisible),
                reason: "request_\(source.rawValue)"
            )
        } else {
            dismiss()
        }
    }

    func beginSaveAndClose(using viewModel: NoteEditorViewModel) {
        transitionCloseFlow(
            to: .savingAndClosing(keyboardVisibleSnapshot: closeFlowKeyboardVisibleSnapshot),
            reason: "save_and_close"
        )
        Task {
            let noteID = await viewModel.save()
            guard noteID == nil else { return }
            await MainActor.run {
                transitionCloseFlow(to: .idle, reason: "save_and_close_failed")
            }
        }
    }

    func beginDiscardAndClose(using viewModel: NoteEditorViewModel) {
        transitionCloseFlow(
            to: .discardingAndClosing(keyboardVisibleSnapshot: closeFlowKeyboardVisibleSnapshot),
            reason: "discard_and_close"
        )
        Task {
            await viewModel.discardEditingSession()
            await MainActor.run {
                dismiss()
            }
        }
    }

    var closeFlowKeyboardVisibleSnapshot: Bool {
        closeFlowState.keyboardVisibleSnapshot ?? isKeyboardVisible
    }

    func transitionCloseFlow(to nextState: NoteEditorCloseFlowState, reason: String) {
        let previousState = closeFlowState
        guard previousState != nextState else { return }
        closeFlowState = nextState
        if nextState.isActive {
            resetFocusExcerptCoordination(reason: "close_flow_\(reason)")
            freezeLayoutContext(
                source: .closeFlow,
                reason: "close_flow_\(reason)",
                keyboardVisible: nextState.keyboardVisibleSnapshot ?? isKeyboardVisible
            )
        } else {
            clearLayoutFreezeContext(source: .closeFlow, reason: "close_flow_\(reason)")
        }
#if DEBUG
        logExpandEvent(
            "close_flow.transition",
            viewModel: viewModel,
            extra: "reason=\(reason) previous=\(previousState.debugName) next=\(nextState.debugName) keyboardSnapshot=\(nextState.keyboardVisibleSnapshot?.description ?? "nil")"
        )
#endif
    }

    func handleLayoutModeStateChange(animated: Bool) {
        guard let viewModel else { return }
        guard layoutMode == .focusExcerpt else {
            resetFocusExcerptCoordination(reason: "layout_mode_exit")
            return
        }
#if DEBUG
        logExpandEvent(
            "layout.sync.start",
            viewModel: viewModel,
            extra: "animated=\(animated)"
        )
#endif
        if animated {
            performFocusExcerptLayoutAnimation(reason: "layout_mode_change") {
                viewModel.syncIdeaInputStateForFocusLayout(isIdeaFocused: isIdeaFocused)
            }
        } else {
            resetFocusExcerptCoordination(reason: "layout_mode_sync")
            viewModel.syncIdeaInputStateForFocusLayout(isIdeaFocused: isIdeaFocused)
        }
#if DEBUG
        logExpandEvent(
            "layout.sync.end",
            viewModel: viewModel,
            extra: "animated=\(animated)"
        )
#endif
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
#if DEBUG
            logExpandEvent(
                "idea.focus.change",
                viewModel: viewModel,
                extra: "hasFocus=\(hasFocus)"
            )
#endif
            isIdeaFocused = hasFocus
            let shouldSyncIdeaLayout = !isCloseFlowActive
            if hasFocus {
                pendingCollapseAfterKeyboardHide = false
                activeEditorTarget = .idea
            } else {
                if activeEditorTarget == .idea {
                    activeEditorTarget = nil
                }
                if shouldSyncIdeaLayout,
                   layoutMode == .focusExcerpt,
                   let viewModel {
#if DEBUG
                    logExpandEvent(
                        "idea.collapse.trigger",
                        viewModel: viewModel,
                        extra: "reason=focus_lost keyboardVisible=\(isKeyboardVisible) keyboardAnimatingOut=\(isKeyboardAnimatingOut)"
                    )
#endif
                    if viewModel.hasIdeaText {
                        viewModel.syncIdeaInputStateForFocusLayout(isIdeaFocused: false)
                    } else {
                        requestIdeaCollapseAfterKeyboardHide(reason: "focus_lost")
                    }
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
        guard let viewModel else {
#if DEBUG
            logExpandEvent(
                "focus_row.tap.ignored",
                viewModel: nil,
                extra: "reason=viewModel_nil"
            )
#endif
            return
        }
#if DEBUG
        logExpandEvent(
            "focus_row.tap",
            viewModel: viewModel
        )
#endif
        registerEditorInteraction(force: true)
        toolbarPromptMessage = nil
#if DEBUG
        logExpandEvent(
            "idea.expand.request",
            viewModel: viewModel,
            extra: "phase=before"
        )
#endif
        requestIdeaExpand(source: "focus_row_tap", focusAfterAnimation: true)
#if DEBUG
        logExpandEvent(
            "idea.expand.request",
            viewModel: viewModel,
            extra: "phase=after"
        )
#endif
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

    func focusEditor(
        _ target: NoteEditorComposerTarget,
        reason: String,
        fallbackDelay: TimeInterval? = nil
    ) {
        let controller = ornamentController(for: target)
#if DEBUG
        let targetName = target.rawValue
        let handlerReady = controller.commandHandler != nil
        logExpandEvent(
            "idea.focus.send",
            viewModel: viewModel,
            extra: "reason=\(reason) target=\(targetName) handlerReady=\(handlerReady) controller=\(controllerIdentifier(controller))"
        )
#endif
        DispatchQueue.main.async {
            controller.send(.focus)
            controller.send(.moveCursorToEnd)
        }
        guard let fallbackDelay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + fallbackDelay) {
            let hasFocus = (target == .idea) ? isIdeaFocused : isContentFocused
            guard !hasFocus else { return }
#if DEBUG
            let targetName = target.rawValue
            let handlerReady = controller.commandHandler != nil
            logExpandEvent(
                "idea.focus.send.fallback",
                viewModel: viewModel,
                extra: "reason=\(reason) target=\(targetName) handlerReady=\(handlerReady) controller=\(controllerIdentifier(controller))"
            )
#endif
            controller.send(.focus)
            controller.send(.moveCursorToEnd)
        }
    }

#if DEBUG
    func logExpandEvent(_ event: String, viewModel: NoteEditorViewModel?, extra: String = "") {
        let snapshot = debugSnapshot(viewModel: viewModel)
        let normalizedExtra = extra.isEmpty ? "" : " \(extra)"
        expandLogger.debug(
            "[note.editor.expand.\(event, privacy: .public)] \(snapshot, privacy: .public)\(normalizedExtra, privacy: .public)"
        )
    }

    func debugSnapshot(viewModel: NoteEditorViewModel?) -> String {
        let ideaState = viewModel.map { ideaStateText($0.ideaInputState) } ?? "nil"
        let hasIdeaText = viewModel?.hasIdeaText ?? false
        let activeTarget = activeEditorTarget?.rawValue ?? "nil"
        return "layout=\(layoutMode.rawValue) ideaState=\(ideaState) hasIdeaText=\(hasIdeaText) isIdeaFocused=\(isIdeaFocused) isContentFocused=\(isContentFocused) activeTarget=\(activeTarget) keyboardVisible=\(isKeyboardVisible) closeFlow=\(closeFlowState.debugName)"
    }

    func ideaStateText(_ state: IdeaInputState) -> String {
        switch state {
        case .collapsed:
            return "collapsed"
        case .expanded:
            return "expanded"
        case .hasContent:
            return "hasContent"
        }
    }

    func controllerIdentifier(_ controller: RichTextOrnamentController) -> String {
        String(describing: Unmanaged.passUnretained(controller).toOpaque())
    }
#endif

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

    func makeFocusExcerptLayoutInputs(
        measuredHeights: [NoteEditorMeasuredPart: CGFloat],
        keyboardVisible: Bool
    ) -> NoteEditorFocusExcerptLayoutInputs {
        let preparedHeights = measuredHeightsForComputation(from: measuredHeights)
        return NoteEditorFocusExcerptLayoutInputs(
            measuredHeights: preparedHeights.heights,
            keyboardVisible: keyboardVisible,
            usedSeededMeasurements: preparedHeights.usedSeededHeights
        )
    }

    func requestIdeaExpand(source: String, focusAfterAnimation: Bool) {
        guard layoutMode == .focusExcerpt, let viewModel else { return }
        guard !isCloseFlowActive else { return }
        if focusExcerptTransition == .idle, isFocusExcerptLayoutAnimating {
            return
        }
        pendingCollapseAfterKeyboardHide = false

        switch focusExcerptTransition {
        case .idle:
            guard viewModel.ideaInputState == .collapsed else {
                guard focusAfterAnimation, !isIdeaFocused else { return }
                activeEditorTarget = .idea
                focusEditor(.idea, reason: source, fallbackDelay: 0.1)
                return
            }
            performFocusExcerptLayoutAnimation(
                reason: "idea_expand_\(source)",
                transition: .expanding(pendingFocus: focusAfterAnimation),
                updates: {
                    viewModel.expandIdea()
                },
                onCompletion: {
                    let shouldFocus = focusExcerptTransition.pendingFocusAfterAnimation
                    focusExcerptTransition = .idle
                    clearLayoutFreezeContext(source: .focusExcerptTransition, reason: "idea_expand_\(source)")
                    guard shouldFocus else { return }
                    activeEditorTarget = .idea
                    focusEditor(.idea, reason: source, fallbackDelay: 0.1)
                }
            )
        case .expanding(let pendingFocus):
            if focusAfterAnimation && !pendingFocus {
                focusExcerptTransition = .expanding(pendingFocus: true)
            }
        case .collapsing:
            return
        }
    }

    func requestIdeaCollapseAfterKeyboardHide(reason: String) {
        guard layoutMode == .focusExcerpt, let viewModel else { return }
        guard !isCloseFlowActive else { return }
        if focusExcerptTransition == .idle, isFocusExcerptLayoutAnimating {
            return
        }
        guard !viewModel.hasIdeaText else {
            pendingCollapseAfterKeyboardHide = false
            return
        }
        guard viewModel.ideaInputState != .collapsed else {
            pendingCollapseAfterKeyboardHide = false
            return
        }
        guard focusExcerptTransition != .collapsing else { return }
        pendingCollapseAfterKeyboardHide = true
        if !isKeyboardVisible && !isKeyboardAnimatingOut {
            performIdeaCollapse(reason: reason)
        }
    }

    func performIdeaCollapse(reason: String) {
        guard layoutMode == .focusExcerpt, let viewModel else {
            pendingCollapseAfterKeyboardHide = false
            return
        }
        guard !isCloseFlowActive else { return }
        if focusExcerptTransition == .idle, isFocusExcerptLayoutAnimating {
            return
        }
        guard !viewModel.hasIdeaText else {
            pendingCollapseAfterKeyboardHide = false
            viewModel.syncIdeaInputStateForFocusLayout(isIdeaFocused: false)
            return
        }
        guard viewModel.ideaInputState != .collapsed else {
            pendingCollapseAfterKeyboardHide = false
            return
        }
        guard focusExcerptTransition != .collapsing else { return }

        pendingCollapseAfterKeyboardHide = false
        performFocusExcerptLayoutAnimation(
            reason: "idea_collapse_\(reason)",
            transition: .collapsing,
            updates: {
                viewModel.collapseIdeaIfEmpty()
            },
            onCompletion: {
                focusExcerptTransition = .idle
                clearLayoutFreezeContext(source: .focusExcerptTransition, reason: "idea_collapse_\(reason)")
            }
        )
    }

    func performFocusExcerptLayoutAnimation(
        reason: String,
        transition: NoteEditorFocusExcerptTransition? = nil,
        updates: @escaping () -> Void,
        onCompletion: @escaping () -> Void = {}
    ) {
        guard layoutMode == .focusExcerpt else {
            updates()
            onCompletion()
            return
        }
        freezeLayoutContext(source: .focusExcerptTransition, reason: reason)
        if let transition {
            focusExcerptTransition = transition
        }
        var transaction = Transaction(animation: .snappy)
        transaction.addAnimationCompletion(criteria: .logicallyComplete) {
            onCompletion()
        }
        withTransaction(transaction) {
            updates()
        }
    }

    func freezeLayoutContext(
        source: NoteEditorLayoutFreezeSource,
        reason: String,
        keyboardVisible: Bool? = nil
    ) {
        guard layoutMode == .focusExcerpt else { return }
        layoutFreezeContext = NoteEditorLayoutFreezeContext(
            source: source,
            measuredHeights: measuredHeights,
            keyboardVisible: keyboardVisible ?? isKeyboardVisible
        )
#if DEBUG
        logExpandEvent(
            "layout.freeze.start",
            viewModel: viewModel,
            extra: "source=\(source.debugName) reason=\(reason) keyboardVisible=\((keyboardVisible ?? isKeyboardVisible).description)"
        )
#endif
    }

    func clearLayoutFreezeContext(source: NoteEditorLayoutFreezeSource, reason: String) {
        guard layoutFreezeContext?.source == source else { return }
#if DEBUG
        logExpandEvent(
            "layout.freeze.end",
            viewModel: viewModel,
            extra: "source=\(source.debugName) reason=\(reason)"
        )
#endif
        layoutFreezeContext = nil
    }

    func resetFocusExcerptCoordination(reason: String) {
        pendingCollapseAfterKeyboardHide = false
        focusExcerptTransition = .idle
        clearLayoutFreezeContext(source: .focusExcerptTransition, reason: reason)
    }

    func editorHeights(
        for viewportHeight: CGFloat,
        bookSectionHeight: CGFloat,
        stableTailSectionHeight: CGFloat,
        measuredTailSectionHeight: CGFloat,
        toolbarHeight: CGFloat,
        ideaState: IdeaInputState,
        keyboardVisible: Bool
    ) -> (content: CGFloat, idea: CGFloat) {
        let computation = makeEditorHeightComputation(
            for: viewportHeight,
            bookSectionHeight: bookSectionHeight,
            stableTailSectionHeight: stableTailSectionHeight,
            measuredTailSectionHeight: measuredTailSectionHeight,
            toolbarHeight: toolbarHeight,
            ideaState: ideaState,
            keyboardVisible: keyboardVisible
        )
        return (computation.contentHeight, computation.ideaHeight)
    }

    func makeEditorHeightComputation(
        for viewportHeight: CGFloat,
        bookSectionHeight: CGFloat,
        stableTailSectionHeight: CGFloat,
        measuredTailSectionHeight: CGFloat,
        toolbarHeight: CGFloat,
        ideaState: IdeaInputState,
        keyboardVisible: Bool,
        usedSeededMeasurements: Bool = false
    ) -> NoteEditorHeightComputation {
        let defaultEditorHeight: CGFloat = 180
        let collapsedIdeaHeight: CGFloat = 48
        let stackOuterPadding = Spacing.base + max(Spacing.section, toolbarHeight + Spacing.base)
        let sectionGaps = Spacing.base * 3
        let fixedElementsHeight = bookSectionHeight + stableTailSectionHeight + stackOuterPadding + sectionGaps
        let availableForEditors = max(viewportHeight - fixedElementsHeight, 0)
        let hasResolvedMeasurements =
            bookSectionHeight > measuredHeightEpsilon &&
            stableTailSectionHeight > measuredHeightEpsilon &&
            toolbarHeight > measuredHeightEpsilon
        switch layoutMode {
        case .classic:
            return NoteEditorHeightComputation(
                branch: "classic.fixed",
                viewportHeight: viewportHeight,
                bookSectionHeight: bookSectionHeight,
                stableTailSectionHeight: stableTailSectionHeight,
                measuredTailSectionHeight: measuredTailSectionHeight,
                toolbarHeight: toolbarHeight,
                fixedElementsHeight: fixedElementsHeight,
                availableForEditors: availableForEditors,
                hasResolvedMeasurements: hasResolvedMeasurements,
                ideaState: ideaState,
                keyboardVisible: keyboardVisible,
                usedSeededMeasurements: usedSeededMeasurements,
                contentHeight: defaultEditorHeight,
                ideaHeight: defaultEditorHeight
            )
        case .focusExcerpt:
            if ideaState == .collapsed {
                let contentAvailable = availableForEditors - collapsedIdeaHeight
                let contentHeight: CGFloat
                let branch: String
                if keyboardVisible {
                    contentHeight = max(contentAvailable, 0)
                    branch = "focus.collapsed.keyboard_visible"
                } else {
                    let fullViewportContent = max(viewportHeight - collapsedIdeaHeight - Spacing.base, 0)
                    contentHeight = max(fullViewportContent, defaultEditorHeight)
                    branch = "focus.collapsed.full_viewport_priority"
                }
                return NoteEditorHeightComputation(
                    branch: branch,
                    viewportHeight: viewportHeight,
                    bookSectionHeight: bookSectionHeight,
                    stableTailSectionHeight: stableTailSectionHeight,
                    measuredTailSectionHeight: measuredTailSectionHeight,
                    toolbarHeight: toolbarHeight,
                    fixedElementsHeight: fixedElementsHeight,
                    availableForEditors: availableForEditors,
                    hasResolvedMeasurements: hasResolvedMeasurements,
                    ideaState: ideaState,
                    keyboardVisible: keyboardVisible,
                    usedSeededMeasurements: usedSeededMeasurements,
                    contentHeight: contentHeight,
                    ideaHeight: collapsedIdeaHeight
                )
            } else {
                let halfSpace = availableForEditors / 2
                let editorHeight = max(halfSpace, defaultEditorHeight)
                return NoteEditorHeightComputation(
                    branch: "focus.expanded_or_hasContent.half_split",
                    viewportHeight: viewportHeight,
                    bookSectionHeight: bookSectionHeight,
                    stableTailSectionHeight: stableTailSectionHeight,
                    measuredTailSectionHeight: measuredTailSectionHeight,
                    toolbarHeight: toolbarHeight,
                    fixedElementsHeight: fixedElementsHeight,
                    availableForEditors: availableForEditors,
                    hasResolvedMeasurements: hasResolvedMeasurements,
                    ideaState: ideaState,
                    keyboardVisible: keyboardVisible,
                    usedSeededMeasurements: usedSeededMeasurements,
                    contentHeight: editorHeight,
                    ideaHeight: editorHeight
                )
            }
        }
    }

    func measuredHeightsForComputation(from source: [NoteEditorMeasuredPart: CGFloat]) -> (heights: [NoteEditorMeasuredPart: CGFloat], usedSeededHeights: Bool) {
        var merged = source
        var usedSeededHeights = false
        for (part, seededHeight) in seededMeasuredHeights {
            let currentHeight = merged[part] ?? 0
            if currentHeight > measuredHeightEpsilon {
                continue
            }
            merged[part] = seededHeight
            usedSeededHeights = true
        }
        return (merged, usedSeededHeights)
    }

    func restoreEditorFocusAfterComposerDismiss() {
        let target = lastClosedComposerTarget ?? activeEditorTarget ?? .content
        lastClosedComposerTarget = nil

        if target == .idea, layoutMode == .focusExcerpt {
            isContentFocused = false
            requestIdeaExpand(source: "composer_dismiss", focusAfterAnimation: true)
            return
        }
        if target == .idea {
            activeEditorTarget = .idea
            focusEditor(.idea, reason: "composer_dismiss", fallbackDelay: 0.1)
        } else {
            activeEditorTarget = target
            let controller = contentOrnamentController
            DispatchQueue.main.async {
                controller.send(.focus)
                controller.send(.moveCursorToEnd)
            }
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

    func mergeMeasuredHeights(_ incoming: [NoteEditorMeasuredPart: CGFloat]) {
        var next = measuredHeights
        var hasChange = false
#if DEBUG
        let previous = measuredHeights
        var changedParts: [String] = []
#endif
        for (part, height) in incoming {
            guard height.isFinite else { continue }
            if let previous = next[part], abs(previous - height) <= measuredHeightEpsilon {
                continue
            }
            next[part] = height
            hasChange = true
#if DEBUG
            let previousValue = previous[part] ?? 0
            changedParts.append("\(part.debugName):\(formatHeight(previousValue))->\(formatHeight(height))")
#endif
        }
        if hasChange {
            measuredHeights = next
#if DEBUG
            logExpandEvent(
                "layout.height.measure.merge",
                viewModel: viewModel,
                extra: "changes=[\(changedParts.joined(separator: ","))] previous=[\(describeMeasuredHeights(previous))] next=[\(describeMeasuredHeights(next))]"
            )
            if !hasResolvedMeasuredHeights(previous) && hasResolvedMeasuredHeights(next) {
                logExpandEvent(
                    "layout.height.measure.resolved",
                    viewModel: viewModel,
                    extra: "snapshot=[\(describeMeasuredHeights(next))]"
                )
            }
#endif
        }
    }

#if DEBUG
    @ViewBuilder
    func heightDiagnosticsProbe(
        viewModel: NoteEditorViewModel,
        viewportHeight: CGFloat,
        computation: NoteEditorHeightComputation
    ) -> some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                logHeightComputation(viewModel: viewModel, viewportHeight: viewportHeight, computation: computation)
            }
            .onChange(of: heightComputationSignature(viewModel: viewModel, viewportHeight: viewportHeight, computation: computation)) { _, _ in
                logHeightComputation(viewModel: viewModel, viewportHeight: viewportHeight, computation: computation)
            }
    }

    func logHeightComputation(
        viewModel: NoteEditorViewModel,
        viewportHeight: CGFloat,
        computation: NoteEditorHeightComputation
    ) {
        logExpandEvent(
            "layout.height.compute",
            viewModel: viewModel,
            extra: "branch=\(computation.branch) viewport=\(formatHeight(viewportHeight)) measured=[\(describeMeasuredHeights(effectiveMeasuredHeights))] stableTail=\(formatHeight(computation.stableTailSectionHeight)) tail=\(formatHeight(computation.measuredTailSectionHeight)) fixed=\(formatHeight(computation.fixedElementsHeight)) available=\(formatHeight(computation.availableForEditors)) resolved=\(computation.hasResolvedMeasurements) keyboardVisible=\(computation.keyboardVisible) seeded=\(computation.usedSeededMeasurements) content=\(formatHeight(computation.contentHeight)) idea=\(formatHeight(computation.ideaHeight))"
        )
    }

    func heightComputationSignature(
        viewModel: NoteEditorViewModel,
        viewportHeight: CGFloat,
        computation: NoteEditorHeightComputation
    ) -> String {
        [
            computation.branch,
            formatHeight(viewportHeight),
            formatHeight(computation.bookSectionHeight),
            formatHeight(computation.stableTailSectionHeight),
            formatHeight(computation.measuredTailSectionHeight),
            formatHeight(computation.toolbarHeight),
            formatHeight(computation.fixedElementsHeight),
            formatHeight(computation.availableForEditors),
            computation.hasResolvedMeasurements.description,
            computation.keyboardVisible.description,
            computation.usedSeededMeasurements.description,
            ideaStateText(computation.ideaState),
            formatHeight(computation.contentHeight),
            formatHeight(computation.ideaHeight),
            viewModel.hasIdeaText.description,
            activeEditorTarget?.rawValue ?? "nil"
        ].joined(separator: "|")
    }

    func handleEditorTextChange(target: NoteEditorComposerTarget, text: NSAttributedString) {
        let targetKey = target.rawValue
        let currentLength = text.string.count
        let previousLength = lastObservedTextLengthByTarget[targetKey] ?? 0
        lastObservedTextLengthByTarget[targetKey] = currentLength

        let context = [
            "measured=[\(describeMeasuredHeights(effectiveMeasuredHeights))]",
            "keyboard=\(formatHeight(keyboardHeight))",
            "layoutMode=\(layoutMode.rawValue)",
            "activeTarget=\(activeEditorTarget?.rawValue ?? "nil")",
            "ideaState=\(viewModel.map { ideaStateText($0.ideaInputState) } ?? "nil")"
        ].joined(separator: " ")
        let previousContext = lastLoggedTextChangeContextByTarget[targetKey]
        let shouldLog = previousLength == 0 || previousContext != context
        if shouldLog {
            logExpandEvent(
                "editor.text.change",
                viewModel: viewModel,
                extra: "target=\(target.rawValue) previousLength=\(previousLength) currentLength=\(currentLength) \(context)"
            )
            lastLoggedTextChangeContextByTarget[targetKey] = context
        }
    }

    func describeMeasuredHeights(_ heights: [NoteEditorMeasuredPart: CGFloat]) -> String {
        NoteEditorMeasuredPart.allCases
            .map { part in
                "\(part.debugName)=\(formatHeight(heights[part] ?? 0))"
            }
            .joined(separator: ",")
    }

    func hasResolvedMeasuredHeights(_ heights: [NoteEditorMeasuredPart: CGFloat]) -> Bool {
        [NoteEditorMeasuredPart.toolbar, .book, .tailStable].allSatisfy { part in
            (heights[part] ?? 0) > measuredHeightEpsilon
        }
    }

    func formatHeight(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
#endif
}

private enum DismissAttemptSource: String {
    case toolbarButton = "toolbar_button"
    case navigationGesture = "navigation_gesture"
}

private enum NoteEditorCloseFlowState: Equatable {
    case idle
    case confirmingDiscard(keyboardVisibleSnapshot: Bool)
    case savingAndClosing(keyboardVisibleSnapshot: Bool)
    case discardingAndClosing(keyboardVisibleSnapshot: Bool)

    var keyboardVisibleSnapshot: Bool? {
        switch self {
        case .idle:
            return nil
        case .confirmingDiscard(let snapshot),
             .savingAndClosing(let snapshot),
             .discardingAndClosing(let snapshot):
            return snapshot
        }
    }

    var isActive: Bool {
        self != .idle
    }

    var isConfirmingDiscard: Bool {
        if case .confirmingDiscard = self {
            return true
        }
        return false
    }

    var isSavingAndClosing: Bool {
        if case .savingAndClosing = self {
            return true
        }
        return false
    }

    var debugName: String {
        switch self {
        case .idle:
            return "idle"
        case .confirmingDiscard:
            return "confirmingDiscard"
        case .savingAndClosing:
            return "savingAndClosing"
        case .discardingAndClosing:
            return "discardingAndClosing"
        }
    }
}

private enum NoteEditorFocusExcerptTransition: Equatable {
    case idle
    case expanding(pendingFocus: Bool)
    case collapsing

    var pendingFocusAfterAnimation: Bool {
        if case .expanding(let pendingFocus) = self {
            return pendingFocus
        }
        return false
    }
}

private enum NoteEditorLayoutFreezeSource: Equatable {
    case focusExcerptTransition
    case closeFlow

#if DEBUG
    var debugName: String {
        switch self {
        case .focusExcerptTransition:
            return "focusExcerptTransition"
        case .closeFlow:
            return "closeFlow"
        }
    }
#endif
}

private struct NoteEditorLayoutFreezeContext: Equatable {
    let source: NoteEditorLayoutFreezeSource
    let measuredHeights: [NoteEditorMeasuredPart: CGFloat]
    let keyboardVisible: Bool
}

private struct NoteEditorFocusExcerptLayoutInputs {
    let measuredHeights: [NoteEditorMeasuredPart: CGFloat]
    let keyboardVisible: Bool
    let usedSeededMeasurements: Bool
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
            return "聚焦摘录"
        }
    }

    var subtitle: String {
        switch self {
        case .classic:
            return "摘录和想法都常驻，边摘边写更顺手"
        case .focusExcerpt:
            return "想法先收起，先把摘录记下来，需要时再展开补充"
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
    enum ToolbarMode {
        case editor
        case imageOnly
    }

    let activeFormats: Set<RichTextFormat>
    let canEdit: Bool
    let canUndo: Bool
    let canRedo: Bool
    let canCaptureTextFromCamera: Bool
    let canSave: Bool
    let showsOCRButton: Bool
    let toolbarMode: ToolbarMode
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
                        NoteToolbarIconStrip(actions: iconActions, dividerOpacity: 0.16)
                            .padding(.horizontal, Spacing.base)
                            .padding(.vertical, Spacing.cozy)
                    }
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)

                    toolbarDivider
                    toolbarTextButton("保存", enabled: canSave, action: onSave)
                }
                .padding(.trailing, Spacing.base)
            }
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.bottom, Spacing.cozy)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .background(Color.clear)
        .animation(.snappy(duration: 0.22), value: toolbarMode)
    }

    var toolbarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(width: 1, height: 18)
    }

    var orderedIconActionIDs: [NoteToolbarActionID] {
        switch toolbarMode {
        case .editor:
            return NoteToolbarActionID.androidPriorityOrder.filter { actionID in
                if actionID == .ocr {
                    return showsOCRButton
                }
                return true
            }
        case .imageOnly:
            return [.choiceImage]
        }
    }

    var iconActions: [NoteToolbarIconAction] {
        orderedIconActionIDs.map { actionID in
            NoteToolbarIconAction(
                id: actionID,
                isEnabled: isActionEnabled(actionID),
                isActive: isActionActive(actionID),
                handler: { handleIconAction(actionID) }
            )
        }
    }

    func isActionEnabled(_ actionID: NoteToolbarActionID) -> Bool {
        switch actionID {
        case .undo:
            return canEdit && canUndo
        case .redo:
            return canEdit && canRedo
        case .cursorLeft, .cursorRight, .fullScreen, .indent, .bold, .highlight, .underlined, .italic, .strikeThrough, .formatClear:
            return canEdit
        case .ocr:
            return canEdit || canCaptureTextFromCamera
        case .choiceImage:
            return true
        }
    }

    func isActionActive(_ actionID: NoteToolbarActionID) -> Bool {
        guard let format = actionID.format else { return false }
        return activeFormats.contains(format)
    }

    func handleIconAction(_ actionID: NoteToolbarActionID) {
        switch actionID {
        case .undo:
            onUndo()
        case .redo:
            onRedo()
        case .cursorLeft:
            onMoveCursorLeft()
        case .cursorRight:
            onMoveCursorRight()
        case .fullScreen:
            onFullscreen()
        case .ocr:
            onOCR()
        case .choiceImage:
            onChooseImage()
        case .indent:
            onIndent()
        case .bold:
            onToggleFormat(.bold)
        case .highlight:
            onToggleFormat(.highlight)
        case .underlined:
            onToggleFormat(.underline)
        case .italic:
            onToggleFormat(.italic)
        case .strikeThrough:
            onToggleFormat(.strikethrough)
        case .formatClear:
            onClearFormats()
        }
    }

    func toolbarTextButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.semantic(.footnote, weight: .semibold))
                .foregroundStyle(Color.white.opacity(enabled ? 1 : 0.86))
                .padding(.horizontal, Spacing.base)
                .frame(height: 34)
                .background(
                    enabled ? Color.brand : Color.buttonDisabled,
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
                    TopBarBackButton {
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
                    TopBarBackButton {
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
                    TopBarBackButton {
                        dismiss()
                    }
                }
            }
        }
    }
}

private enum NoteEditorMeasuredPart: Hashable, CaseIterable {
    case toolbar
    case book
    case tailStable
    case tail

#if DEBUG
    var debugName: String {
        switch self {
        case .toolbar:
            return "toolbar"
        case .book:
            return "book"
        case .tailStable:
            return "tailStable"
        case .tail:
            return "tail"
        }
    }
#endif
}

private struct NoteEditorHeightComputation {
    let branch: String
    let viewportHeight: CGFloat
    let bookSectionHeight: CGFloat
    let stableTailSectionHeight: CGFloat
    let measuredTailSectionHeight: CGFloat
    let toolbarHeight: CGFloat
    let fixedElementsHeight: CGFloat
    let availableForEditors: CGFloat
    let hasResolvedMeasurements: Bool
    let ideaState: IdeaInputState
    let keyboardVisible: Bool
    let usedSeededMeasurements: Bool
    let contentHeight: CGFloat
    let ideaHeight: CGFloat
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
