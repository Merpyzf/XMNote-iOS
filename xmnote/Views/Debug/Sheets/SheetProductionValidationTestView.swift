#if DEBUG
/**
 * [INPUT]: 依赖生产 Sheet、隔离 RepositoryContainer、SheetCatalogTarget、生产快照与安全外部替身
 * [OUTPUT]: 对外提供 SheetProductionValidationTestView 与 SheetProductionTargetPreviewHost，按 113 个生产目标直接实例化真实生产 View
 * [POS]: Views/Debug/Sheets 的生产 Sheet 渲染层；业务写入只进入本次工作副本，外部副作用由安全替身承接
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

struct SheetProductionValidationTestView: View {
    let repositories: RepositoryContainer
    let target: SheetCatalogTarget?
    let snapshot: SheetPreviewSnapshot?
    let previewUserDefaults: UserDefaults

    private let validationAIRepository: SheetValidationAIRepository
    private let validationBookSearchRepository: BookSelectionFixtureRepository

    @State private var presentation = FixturePresentation()
    @State private var selectedDate = Date()
    @State private var composerText = NSAttributedString(
        string: "设计不是装饰，而是帮助人清楚地理解并完成任务。"
    )
    @State private var editorSettings = NoteEditorSettings(
        defaults: UserDefaults(suiteName: "sheet-production-validation") ?? .standard
    )
    @State private var bookshelfDisplaySetting = BookshelfDisplaySetting.defaultValue
    @State private var collectionDisplaySetting = BookCollectionDisplaySetting.defaultValue
    @State private var readingGoalValue = "60"
    @State private var aiConfigurationViewModel: AIConfigurationViewModel
    @State private var apiIntegrationViewModel: ApiIntegrationViewModel
    @State private var dataBackupViewModel: DataBackupViewModel
    @State private var webDAVServerViewModel: WebDAVServerViewModel
    @State private var bookGroupViewModel: BookGroupManagementViewModel
    @State private var sourceViewModel: SourceManagementViewModel
    @State private var tagViewModel: TagManagementViewModel
    @State private var readCalendarSettings: ReadCalendarSettings
    @State private var chapterBatchViewModel: ChapterBatchImportViewModel
    @State private var chapterRemoteViewModel: ChapterRemoteSyncViewModel
    @State private var noteReviewViewModel: NoteReviewViewModel
    @State private var noteMergeViewModel: NoteMergeViewModel
    @State private var readingTimerCoordinator: ReadingTimerCoordinator

    static func supportsProductionTarget(_ target: SheetCatalogTarget) -> Bool {
        Fixture.productionFixture(for: target.owner) != nil
    }

    init(
        repositories: RepositoryContainer,
        target: SheetCatalogTarget? = nil,
        snapshot: SheetPreviewSnapshot? = nil,
        previewUserDefaults: UserDefaults? = nil
    ) {
        self.repositories = repositories
        self.target = target
        self.snapshot = snapshot
        let resolvedPreviewUserDefaults = previewUserDefaults
            ?? UserDefaults(suiteName: "sheet-production-validation")
            ?? .standard
        self.previewUserDefaults = resolvedPreviewUserDefaults

        let aiRepository = SheetValidationAIRepository()
        self.validationAIRepository = aiRepository
        self.validationBookSearchRepository = BookSelectionFixtureRepository(fixture: .standard)

        let aiConfigurationViewModel = AIConfigurationViewModel(repository: aiRepository)
        _aiConfigurationViewModel = State(initialValue: aiConfigurationViewModel)

        let apiIntegrationViewModel = ApiIntegrationViewModel(
            repository: repositories.externalAppIntegrationRepository
        )
        apiIntegrationViewModel.load()
        _apiIntegrationViewModel = State(initialValue: apiIntegrationViewModel)

        let dataBackupViewModel = DataBackupViewModel(
            backupRepository: repositories.backupRepository
        )
        dataBackupViewModel.backupList = Self.safeBackupHistory
        dataBackupViewModel.restoreTarget = Self.safeRestoreTarget
        _dataBackupViewModel = State(initialValue: dataBackupViewModel)

        let webDAVServerViewModel = WebDAVServerViewModel(
            repository: SheetValidationBackupServerRepository()
        )
        webDAVServerViewModel.formTitle = "校准服务器"
        webDAVServerViewModel.formAddress = "https://example.invalid/dav/"
        webDAVServerViewModel.formAccount = "preview@example.invalid"
        webDAVServerViewModel.formPassword = "preview-only"
        _webDAVServerViewModel = State(initialValue: webDAVServerViewModel)

        let bookGroupViewModel = BookGroupManagementViewModel(
            repository: repositories.bookGroupManagementRepository
        )
        bookGroupViewModel.presentCreateSheet()
        _bookGroupViewModel = State(initialValue: bookGroupViewModel)

        let sourceViewModel = SourceManagementViewModel(
            repository: repositories.sourceManagementRepository
        )
        sourceViewModel.presentCreateSheet()
        _sourceViewModel = State(initialValue: sourceViewModel)

        let tagViewModel = TagManagementViewModel(
            repository: repositories.tagManagementRepository
        )
        tagViewModel.presentCreateSheet()
        _tagViewModel = State(initialValue: tagViewModel)

        _readCalendarSettings = State(
            initialValue: ReadCalendarSettings(
                sheetPreviewUserDefaults: resolvedPreviewUserDefaults
            )
        )

        let previewBookID = snapshot?.representativeBooks.first?.id ?? Self.fixtureBook.id
        let previewBooks = snapshot?.representativeBooks.isEmpty == false
            ? snapshot?.representativeBooks ?? Self.pickerBooks
            : Self.pickerBooks
        let previewTags = Self.tagOptions(from: snapshot)
        let previewChapters = Self.chapterOptions(from: snapshot)
        _composerText = State(
            initialValue: NSAttributedString(
                string: snapshot?.representativeNoteText ?? "设计不是装饰，而是帮助人清楚地理解并完成任务。"
            )
        )

        let chapterBatchViewModel = ChapterBatchImportViewModel(
            bookID: previewBookID,
            chapterRepository: repositories.chapterManagementRepository,
            ocrRepository: repositories.ocrRepository
        )
        chapterBatchViewModel.replaceText(
            "第一章 设计作为秩序\n  1.1 留白与层级\n  1.2 反馈与动效\n第二章 可访问性"
        )
        _chapterBatchViewModel = State(initialValue: chapterBatchViewModel)

        let chapterRemoteViewModel = ChapterRemoteSyncViewModel(
            bookID: previewBookID,
            repository: repositories.chapterManagementRepository
        )
        chapterRemoteViewModel.discovery = Self.remoteDiscovery
        chapterRemoteViewModel.configurationState = .available
        chapterRemoteViewModel.selectedCandidate = Self.remoteDiscovery.candidates.first
        chapterRemoteViewModel.catalogItems = Self.remoteCatalogItems
        chapterRemoteViewModel.selectedItemIDs = Set(Self.remoteCatalogItems.prefix(3).map(\.id))
        chapterRemoteViewModel.phase = .catalog
        _chapterRemoteViewModel = State(initialValue: chapterRemoteViewModel)

        let noteReviewViewModel = NoteReviewViewModel(
            validationSettings: Self.reviewSettings,
            tagOptions: Self.reviewTagOptions,
            selectedBooks: Array(previewBooks.prefix(2)),
            repository: repositories.noteRepository,
            externalAppIntegrationRepository: repositories.externalAppIntegrationRepository,
            aiRepository: aiRepository
        )
        _noteReviewViewModel = State(initialValue: noteReviewViewModel)

        let noteMergeViewModel = NoteMergeViewModel(
            validationDraft: Self.noteMergeDraft,
            availableTags: previewTags,
            chapterOptions: previewChapters,
            repository: repositories.noteRepository,
            quotaRepository: repositories.noteImageUploadQuotaRepository,
            isPremium: true
        )
        _noteMergeViewModel = State(initialValue: noteMergeViewModel)

        let readingTimerCoordinator = ReadingTimerCoordinator(
            repository: repositories.readingTimerRepository,
            userDefaults: UserDefaults(suiteName: "sheet-production-validation-timer") ?? .standard
        )
        readingTimerCoordinator.bookContext = Self.timerBookContext
        readingTimerCoordinator.activeSession = Self.timerSession
        readingTimerCoordinator.elapsedSeconds = Self.timerSession.elapsedSeconds
        readingTimerCoordinator.status = .stoppedPendingSave
        _readingTimerCoordinator = State(initialValue: readingTimerCoordinator)
    }

    @ViewBuilder
    var body: some View {
        @Bindable var presentation = presentation

        if let target {
            if let fixture = Fixture.productionFixture(for: target.owner) {
                fixtureSheet(fixture)
                    .environment(repositories)
            } else {
                XMContentStateView(
                    role: .failure,
                    title: "生产目标尚未接通",
                    message: "\(target.owner) 缺少 renderer。完整性检查应在交付前阻止此状态。"
                )
                .padding(Spacing.screenEdge)
            }
        } else {
            List {
                Section {
                    Text("兼容入口：生产目标请从 Sheet 样式校准目录逐项打开；每次使用独立数据库副本。")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                }

                ForEach(Fixture.allCases) { fixture in
                    Button {
                        presentation.present(fixture)
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text(fixture.title)
                                .font(AppTypography.bodyMedium)
                                .foregroundStyle(Color.textPrimary)
                            Text(fixture.subtitle)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sheet.production.fixture.\(fixture.rawValue)")
                }
            }
            .navigationTitle("生产 Sheet 验收")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $presentation.isPresented, onDismiss: {
                presentation.dismiss()
            }) {
                fixtureSheet(presentation.fixture)
                    .environment(repositories)
            }
        }
    }

    @ViewBuilder
    private func fixtureSheet(_ fixture: Fixture) -> some View {
        switch fixture {
        case .contentTags:
            ContentViewerTagSheet(
                tags: ["设计系统", "用户体验", "交互设计", "知识管理"],
                onDismiss: { presentation.dismiss() }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .noteChapterPicker:
            NoteEditorChapterPickerSheet(
                chapters: previewChapterOptions,
                selectedChapterID: 2,
                onSelect: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .noteTagPicker:
            NoteEditorTagPickerSheet(
                availableTags: previewTagOptions,
                selectedTags: Array(previewTagOptions.prefix(2)),
                onCreate: { name in NoteEditorTagOption(id: 99, title: name) },
                onTagCatalogMutation: { _ in },
                onSave: { _ in true }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .noteDate:
            NoteEditorDateSheet(selectedDate: $selectedDate)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)

        case .noteSettings:
            NoteEditorSettingsSheet(settings: editorSettings)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)

        case .noteComposer:
            NavigationStack {
                NoteTextComposerView(
                    composerTarget: .content,
                    title: "编辑书摘",
                    text: $composerText,
                    onRequestPhotoOCR: { }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)

        case .batchChapter:
            NoteChapterSelectionSheet(
                title: "移动到章节",
                allowsRootSelection: true,
                options: previewChapterOptions,
                onSelect: { _ in },
                onCreate: { parentID, name in
                    NoteEditorChapterOption(id: 99, title: name, parentID: parentID)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .batchTags:
            NoteTagSelectionSheet(
                title: "设置标签",
                contextText: "应用到 3 条书摘",
                options: previewTagOptions,
                initialIDs: [1, 3],
                onCreate: { name in NoteEditorTagOption(id: 99, title: name) },
                onTagCatalogMutation: { _ in },
                onSave: { _ in true }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .bookPlaceholder:
            BookRelatedPlaceholderSheet(
                item: Self.placeholderBook,
                onEdit: { },
                onRestore: {
                    // 预留足够的人工验收窗口，便于检查确认位 loading、关闭锁定与下滑锁定。
                    try await Task.sleep(for: .seconds(30))
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)

        case .bookshelfMoveGroup:
            BookshelfMoveGroupSheet(
                options: Self.batchMoveGroups,
                selectedCount: 3,
                isLoading: false,
                errorMessage: nil,
                onCreate: { name in
                    BookEditorNamedOption(id: 99, title: name)
                },
                onConfirm: { _ in }
            )

        case .bookshelfCollection:
            BookshelfBookCollectionSheet(
                options: Self.batchCollections,
                selectedCount: 3,
                isLoading: false,
                errorMessage: nil,
                onCreate: { name in
                    BookCollectionSummary(
                        id: 99,
                        title: name,
                        description: "",
                        bookCount: 0,
                        representativeCovers: []
                    )
                },
                onConfirm: { _ in }
            )

        case .bookshelfSource:
            BookshelfBatchSourceSheet(
                options: Self.batchSources,
                selectedCount: 3,
                initialSelectedID: 1,
                onCreate: { name in
                    BookshelfSourceOption(id: 99, title: name, category: .mine)
                },
                onConfirm: { _ in }
            )

        case .relatedBook:
            RelatedBookRelationEditorSheet(
                draft: RelatedBookRelationDraft(
                    id: 1,
                    sourceBookID: 2,
                    contentBook: Self.pickerBooks[0]
                ),
                isSaving: false,
                onSave: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .dailyBookFilter:
            DailyReadingBookFilterSheet(
                books: Self.dailyBooks,
                selectedBookID: 1,
                onSelectBook: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .timerStart:
            ReadingTimerStartSheet(onStart: { _ in })

        case .selectedBooks:
            BookPickerSelectedBooksValidationHost(
                viewModel: BookPickerViewModel(
                    configuration: BookPickerConfiguration(
                        title: "选择书籍",
                        scope: .local,
                        selectionMode: .multiple,
                        preselectedBooks: previewBooks
                    ),
                    bookRepository: repositories.bookRepository,
                    searchRepository: repositories.bookSearchRepository
                )
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .readingTiming:
            ReadCalendarTimingEditorSheet(
                recordID: 1,
                initialBook: Self.calendarBooks[0],
                event: Self.timingEvent,
                isSaving: false,
                onSave: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .collectionSummary:
            BookCollectionSummarySheet(detail: Self.collectionDetail)

        case .tagEdit:
            NoteReviewTagEditSheet(
                snapshot: NoteReviewTagEditSnapshot(
                    availableTags: previewTagOptions,
                    selectedTags: Array(previewTagOptions.prefix(2))
                ),
                onCreateTag: { name in NoteEditorTagOption(id: 99, title: name) },
                onTagCatalogMutation: { _ in },
                onSave: { _ in true }
            )

        case .bookMetadata:
            BookCollectionBookMetadataEditSheet(
                edit: Self.collectionMetadataEdit,
                isSaving: false,
                presentation: .make(kind: .manual),
                onSave: { _ in }
            )

        case .wereadPreview:
            BookCollectionWereadImportPreviewSheet(
                preview: Self.collectionImportPreview,
                isSaving: false,
                errorMessage: nil,
                onConfirm: { _ in }
            )

        case .readingStatusEdit:
            BookReadingStatusSheet(
                book: Self.readingDetailBook,
                options: Self.readingStatusOptions,
                editingItem: Self.readingStatusHistory,
                isSaving: false,
                onSave: { _ in },
                onDelete: { _ in }
            )

        case .chapterMove:
            ChapterMoveSheet(
                request: ChapterMoveRequest(
                    chapterIDs: [2],
                    title: "移动章节"
                ),
                targets: Self.chapterMoveTargets,
                onSelect: { _ in }
            )

        case .chapterOrder:
            ChapterSiblingOrderSheet(
                request: ChapterSiblingOrderRequest(
                    parentID: 0,
                    title: "调整章节顺序",
                    siblings: Self.chapterManagementItems
                ),
                onSave: { _ in }
            )

        case .chapterBatch:
            ChapterBatchImportSheet(
                viewModel: chapterBatchViewModel,
                onComplete: { _ in }
            )

        case .chapterRemote:
            ChapterRemoteSyncSheet(viewModel: chapterRemoteViewModel)

        case .coverSearch:
            BookCollectionCoverSearchSheet(
                initialTitle: "",
                currentCoverURL: "",
                onSelect: { _ in }
            )

        case .readingShare:
            BookReadingDetailShareSheet(
                snapshot: Self.readingDetailSnapshot,
                theme: BookReadingDetailTheme(
                    coverColor: .pending,
                    isEnabled: false,
                    colorScheme: .light,
                    reducesTransparency: false
                ),
                setting: BookReadingDetailShareSetting(),
                expandedMonthIDs: [],
                onSettingChange: { _ in }
            )

        case .aiText:
            AITextResultSheet(
                presentation: AITextResultPresentation(
                    request: .noteExplanation(
                        noteID: 1,
                        bookTitle: "设计中的设计"
                    )
                ),
                repository: validationAIRepository
            )

        case .aiTag:
            AIAutoTagSheet(
                presentation: AIAutoTagPresentation(
                    noteID: 1,
                    bookTitle: "设计中的设计"
                ),
                repository: validationAIRepository
            )

        case .reviewSettings:
            NoteReviewSettingsSheet(viewModel: noteReviewViewModel)

        case .mergeComposer:
            NoteMergeComposerSheet(
                composer: .content,
                initialHTML: "<p>设计不是装饰，而是让秩序变得可理解。</p><p>好的交互会让下一步自然发生。</p>",
                ocrRepository: repositories.ocrRepository,
                onSave: { _ in }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)

        case .mergeImages:
            NoteMergeImageEditorSheet(
                viewModel: noteMergeViewModel,
                ocrRepository: repositories.ocrRepository
            )

        case .checkIn:
            ReadCalendarCheckInSheet(
                date: Date(),
                recordID: 1,
                initialBook: Self.calendarBooks[0],
                initialAmount: 2,
                isSaving: false,
                onSave: { _, _ in }
            )

        case .timerFinish:
            ReadingTimerFinishSheet(
                coordinator: readingTimerCoordinator,
                onSave: { _ in },
                onDiscard: { },
                onContinue: { }
            )

        case .bookPicker:
            BookPickerView(
                configuration: productionBookPickerConfiguration,
                bookRepository: repositories.bookRepository,
                searchRepository: validationBookSearchRepository,
                onComplete: { _ in }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)

        case .activityShare:
            XMActivityShareSheet(
                activityItems: ["XMNote Sheet 样式校准：\(previewBooks.first?.title ?? "阅读记录")"]
            )

        case .bookRating:
            XMBookRatingSheet(
                bookTitle: previewBooks.first?.title ?? "设计中的设计",
                initialScore: 40,
                onSubmit: { _ in
                    try await Task.sleep(for: .milliseconds(700))
                }
            )

        case .yearMonthPicker:
            XMYearMonthPickerSheet(
                availableMonths: calendarMonths,
                selectedMonth: Date(),
                currentMonth: Date(),
                calendar: .current,
                onSelectMonth: { _ in }
            )

        case .bookshelfDisplay:
            BookshelfDisplaySettingSheet(
                dimension: .default,
                setting: $bookshelfDisplaySetting
            )

        case .collectionDisplay:
            BookCollectionDisplaySettingSheet(setting: $collectionDisplaySetting)

        case .batchBookTags:
            BookshelfBatchTagsSheet(
                options: Self.bookTagOptions,
                selectedCount: 3,
                initialSelectedIDs: [1, 3],
                allowsEmptySelection: true,
                isLoading: false,
                errorMessage: nil,
                onCreate: { name in BookEditorNamedOption(id: 99, title: name) },
                onSave: { _ in true }
            )

        case .batchReadStatus:
            BookshelfBatchReadStatusSheet(
                options: Self.readStatusNamedOptions,
                selectedCount: 3,
                initialStatusID: 2,
                initialChangedAt: Date(),
                initialRatingScore: 40,
                onConfirm: { _, _, _ in }
            )

        case .readingDetailSetting:
            BookReadingDetailSettingSheet(
                setting: BookReadingDetailSetting(),
                onChange: { _ in }
            )

        case .readingCoverPreview:
            BookReadingCoverPreview(book: Self.readingDetailBook)

        case .readingProgress:
            BookReadingProgressSheet(
                book: Self.readingDetailBook,
                progress: Self.readingDetailSnapshot.analytics.progress,
                isSaving: false,
                onSave: { _, _ in
                    try await Task.sleep(for: .milliseconds(700))
                }
            )

        case .heatmapHelp:
            HeatmapHelpSheetView()

        case .readingGoal:
            ReadingGoalEditorSheet(
                item: ReadingGoalEditorSheet.Item(mode: .daily),
                value: $readingGoalValue,
                isSaving: false,
                errorMessage: nil,
                onConfirm: { },
                onCancel: { }
            )

        case .aiPrompt:
            AIConfigurationPromptEditSheet(
                kind: .noteExplanation,
                viewModel: aiConfigurationViewModel
            )

        case .apiIntegration:
            ApiIntegrationEditSheet(
                destination: .flomo,
                viewModel: apiIntegrationViewModel
            )

        case .backupHistory:
            BackupHistorySheetView(viewModel: dataBackupViewModel)

        case .backupRestore:
            BackupRestoreConfirmSheet(
                target: Self.safeRestoreTarget,
                onCancel: { },
                onConfirm: { }
            )

        case .collectionForm:
            BookCollectionFormSheet(
                presentation: productionCollectionFormPresentation,
                isSaving: false,
                onSave: { _, _ in }
            )

        case .collectionAnnualDescription:
            BookCollectionAnnualDescriptionSheet(
                edit: BookCollectionAnnualDescriptionEdit(detail: Self.annualCollectionDetail),
                isSaving: false,
                onSave: { _ in }
            )

        case .collectionRecommend:
            BookCollectionRecommendSheet(
                edit: BookCollectionRecommendEdit(item: Self.collectionMetadataEdit.item),
                isSaving: false,
                presentation: .make(kind: .manual),
                onSave: { _ in }
            )

        case .wereadImport:
            BookCollectionWereadImportSheet(
                isLoading: false,
                errorMessage: nil,
                onParse: { _ in }
            )

        case .bookGroupName:
            if let edit = bookGroupViewModel.activeNameEdit {
                BookGroupNameEditSheet(viewModel: bookGroupViewModel, edit: edit)
            }

        case .sourceName:
            if let edit = sourceViewModel.activeNameEdit {
                SourceNameEditSheet(viewModel: sourceViewModel, edit: edit)
            }

        case .tagName:
            if let edit = tagViewModel.activeNameEdit {
                TagNameEditSheet(viewModel: tagViewModel, edit: edit)
            }

        case .webDAVServer:
            WebDAVServerFormView(viewModel: webDAVServerViewModel)

        case .localExportPicker:
            SheetPreviewDocumentPicker(mode: .export(Self.safeExportURL))

        case .localImportPicker:
            SheetPreviewDocumentPicker(mode: .import)

        case .calendarMonthSummary:
            ReadCalendarMonthSummarySheet(
                sheet: calendarMonthSummary,
                availableMonths: calendarMonths,
                filterState: .none,
                onSwitchMonth: { _ in }
            )

        case .calendarYearSummary:
            ReadCalendarYearSummarySheet(
                sheet: calendarYearSummary,
                availableYears: [Calendar.current.component(.year, from: Date()) - 1, Calendar.current.component(.year, from: Date())],
                filterState: .none,
                onSwitchYear: { _ in },
                onSelectMonth: { _ in },
                onRetry: { }
            )

        case .calendarSettings:
            ReadCalendarSettingsSheet(settings: readCalendarSettings)

        case .readingYearSummary:
            ReadingYearSummarySheet(
                summary: readingYearSummary,
                onBookTap: { _ in },
                onEditGoal: { }
            )

        case .relatedCategoryNavigation:
            SheetPreviewRelatedCategoryNavigationStack()

        case .templateNavigation:
            SheetPreviewCalendarTemplateNavigationStack()

        case .excludedBooksNavigation:
            SheetPreviewExcludedBooksNavigationStack(books: previewBooks)

        case .xmTagNameCreate:
            XMTagNameSheetPreview(mode: .create)

        case .xmTagNameRename:
            XMTagNameSheetPreview(mode: .rename)
        }
    }

    private var previewBooks: [BookPickerBook] {
        guard let books = snapshot?.representativeBooks, !books.isEmpty else {
            return Self.pickerBooks
        }
        return books
    }

    private var previewTagOptions: [NoteEditorTagOption] {
        Self.tagOptions(from: snapshot)
    }

    private var previewChapterOptions: [NoteEditorChapterOption] {
        Self.chapterOptions(from: snapshot)
    }

    private var productionBookPickerConfiguration: BookPickerConfiguration {
        guard let targetID = target?.id else {
            return BookPickerConfiguration(
                scope: .local,
                selectionMode: .single,
                preselectedBooks: Array(previewBooks.prefix(1))
            )
        }

        switch targetID {
        case let id where id.hasPrefix("book.collection-detail.picker"):
            return BookPickerConfiguration(
                title: "添加书籍",
                scope: .both,
                selectionMode: .multiple,
                allowsCreationFlow: true,
                creationAction: .inlineManualEditor,
                onlineSelectionPolicy: .returnRemoteSelection,
                multipleConfirmationPolicy: .requiresSelection,
                multipleConfirmationTitle: "加入书单",
                onlineSources: BookSearchSource.productionCases,
                preferredOnlineSource: .wenqu
            )

        case let id where id.hasPrefix("content.related-book.picker"):
            return BookPickerConfiguration(
                title: "选择关联书籍",
                scope: .local,
                selectionMode: .single,
                preselectedBooks: Array(previewBooks.prefix(1))
            )

        case let id where id.hasPrefix("note.editor.destination"):
            return BookPickerConfiguration(
                scope: .local,
                selectionMode: .single,
                allowsCreationFlow: true,
                creationAction: .nestedSearchPage,
                preselectedBooks: Array(previewBooks.prefix(1))
            )

        case let id where id.hasPrefix("note.excerpt.batch"):
            return BookPickerConfiguration(
                title: "移动到书籍",
                scope: .local,
                selectionMode: .single,
                allowsCreationFlow: false
            )

        case let id where id.hasPrefix("note.review-settings.destination"):
            return BookPickerConfiguration(
                title: "选择回顾书籍",
                scope: .local,
                selectionMode: .multiple,
                allowsCreationFlow: false,
                multipleConfirmationPolicy: .allowsEmptyResult,
                multipleConfirmationTitle: "完成",
                preselectedBooks: Array(previewBooks.prefix(2))
            )

        case let id where id.hasPrefix("personal.data-import.book"):
            return BookPickerConfiguration(
                title: "映射到已有书籍",
                scope: .local,
                selectionMode: .single,
                defaultQuery: previewBooks.first?.title ?? ""
            )

        case let id where id.hasPrefix("personal.unified-import.book"):
            return BookPickerConfiguration(
                title: "映射到已有书籍",
                scope: .local,
                selectionMode: .single,
                defaultQuery: previewBooks.first?.title ?? ""
            )

        case let id where id.hasPrefix("reading.check-in.book"):
            return BookPickerConfiguration(
                title: "选择打卡书籍",
                scope: .local,
                selectionMode: .single,
                allowsCreationFlow: false,
                preselectedBooks: Array(previewBooks.prefix(1))
            )

        case let id where id.hasPrefix("reading.timing-editor.book"):
            return BookPickerConfiguration(
                title: "选择阅读书籍",
                scope: .local,
                selectionMode: .single,
                allowsCreationFlow: false,
                preselectedBooks: Array(previewBooks.prefix(1))
            )

        case let id where id.hasPrefix("reading.timer-finish.book"):
            return BookPickerConfiguration(
                title: "选择记录书籍",
                scope: .local,
                selectionMode: .single,
                allowsCreationFlow: true,
                creationAction: .nestedSearchPage,
                preselectedBooks: Array(previewBooks.prefix(1))
            )

        default:
            return BookPickerConfiguration(
                scope: .local,
                selectionMode: .single,
                preselectedBooks: Array(previewBooks.prefix(1))
            )
        }
    }

    private var calendarMonths: [Date] {
        (-11...0).compactMap { offset in
            Calendar.current.date(byAdding: .month, value: offset, to: Date())
        }
    }

    private var productionCollectionFormPresentation: BookCollectionFormPresentation {
        guard target?.id.contains("collection-detail") == true else {
            return BookCollectionFormPresentation(mode: .create)
        }
        let snapshotCollection = snapshot?.representativeCollections.first
        return BookCollectionFormPresentation(
            mode: .edit(
                BookCollectionListItem(
                    id: snapshotCollection?.id ?? Self.collectionDetail.id,
                    title: snapshotCollection?.title ?? Self.collectionDetail.title,
                    description: Self.collectionDetail.description,
                    kind: Self.collectionDetail.kind,
                    order: Self.collectionDetail.order,
                    year: Self.collectionDetail.year,
                    bookCount: Self.collectionDetail.bookCount,
                    finishedCount: Self.collectionDetail.finishedCount,
                    targetReadCount: Self.collectionDetail.targetReadCount,
                    representativeCovers: []
                )
            )
        )
    }

    private var calendarMonthSummary: ReadCalendarContentView.MonthSummarySheetData {
        let recordCount = snapshot?.counts.readingRecords ?? 0
        let topBooks = previewBooks.prefix(3).enumerated().map { index, book in
            ReadCalendarMonthlyDurationBook(
                bookId: book.id,
                name: book.title,
                coverURL: book.coverURL,
                readSeconds: max(900, (3 - index) * 1_800)
            )
        }
        return ReadCalendarContentView.MonthSummarySheetData(
            monthStart: Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date(),
            monthSummary: ReadCalendarMonthSummary(
                activeDays: min(18, max(1, recordCount)),
                totalDays: Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30,
                longestStreak: min(7, max(1, recordCount)),
                uniqueReadBookCount: max(1, topBooks.count),
                finishedBookCount: min(2, topBooks.count),
                noteCount: snapshot?.counts.notes ?? 0,
                checkInCount: recordCount,
                totalReadSeconds: topBooks.reduce(0) { $0 + $1.readSeconds },
                timeSlotReadSeconds: [.evening: 5_400],
                peakTimeSlot: .evening,
                peakTimeSlotRatio: 64
            ),
            durationTopBooks: topBooks,
            rankingBarColorsByBookId: [:],
            hasDurationRankingFallback: true,
            loadState: .loaded
        )
    }

    private var calendarYearSummary: ReadCalendarContentView.YearSummarySheetData {
        let year = Calendar.current.component(.year, from: Date())
        let topBooks = calendarMonthSummary.durationTopBooks
        return ReadCalendarContentView.YearSummarySheetData(
            year: year,
            activeDays: min(96, max(1, snapshot?.counts.readingRecords ?? 0)),
            totalReadSeconds: topBooks.reduce(0) { $0 + $1.readSeconds },
            noteCount: snapshot?.counts.notes ?? 0,
            finishedBookCount: min(previewBooks.count, 6),
            activeDaysDelta: nil,
            readSecondsDelta: nil,
            noteCountDelta: nil,
            topBooks: topBooks,
            rankingBarColorsByBookId: [:],
            monthContributions: calendarMonths.map {
                .init(monthStart: $0, activeDays: 4, totalReadSeconds: 3_600)
            },
            isLoading: false,
            errorMessage: nil
        )
    }

    private var readingYearSummary: ReadingYearSummary {
        let year = Calendar.current.component(.year, from: Date())
        let books = previewBooks.prefix(6).enumerated().map { index, book in
            ReadingYearReadBook(
                id: book.id,
                name: book.title,
                coverURL: book.coverURL,
                readStatusChangedDate: Int64(Date().timeIntervalSince1970 * 1_000),
                totalReadSeconds: (index + 1) * 2_400,
                readDoneCount: index == 0 ? 2 : 1
            )
        }
        return ReadingYearSummary(
            year: year,
            targetCount: max(12, books.count),
            readCount: books.count,
            books: books
        )
    }
}

struct SheetProductionTargetPreviewHost: View {
    let request: SheetCatalogPreviewRequest
    @Bindable var snapshotController: SheetCatalogSnapshotController

    @State private var workspace: SheetPreviewWorkspace?
    @State private var errorMessage: String?

    var body: some View {
        content
        .task(id: request.id) {
            await prepareWorkspace()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let workspace {
            SheetProductionValidationTestView(
                repositories: workspace.repositories,
                target: request.target,
                snapshot: workspace.snapshot,
                previewUserDefaults: workspace.userDefaults
            )
            .environment(workspace.repositories)
            .environment(workspace.databaseManager)
        } else if let errorMessage {
            XMContentStateView(
                role: .failure,
                title: "无法打开生产 Sheet",
                message: errorMessage,
                action: XMStateAction("重试") {
                    Task { await prepareWorkspace() }
                }
            )
            .padding(Spacing.screenEdge)
        } else {
            VStack(spacing: Spacing.base) {
                LoadingStateView(style: .inline)
                Text("正在准备隔离副本")
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                Text("生产数据库与偏好不会被修改。")
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Spacing.screenEdge)
        }
    }

    private func prepareWorkspace() async {
        errorMessage = nil
        workspace = nil
        do {
            workspace = try await snapshotController.makeWorkspace(for: request.target)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 直接进入生产书籍选择流的已选管理导航子页，避免用已下线的独立 Sheet 壳层代替真实效果。
private struct BookPickerSelectedBooksValidationHost: View {
    let viewModel: BookPickerViewModel

    @State private var isShowingSelectedBooks = false

    var body: some View {
        NavigationStack {
            Color.surfaceSheet
                .ignoresSafeArea()
                .navigationTitle("选择书籍")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(isPresented: $isShowingSelectedBooks) {
                    BookPickerSelectedBooksScreen(viewModel: viewModel)
                }
        }
        .task {
            isShowingSelectedBooks = true
        }
    }
}

/// 生产代码中的相关分类 Sheet 为宿主页内联结构；Debug 入口保持相同系统 NavigationStack、列表与顶部关闭语义。
private struct SheetPreviewRelatedCategoryNavigationStack: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(["设计", "阅读方法", "产品", "写作"], id: \.self) { title in
                Button { dismiss() } label: {
                    HStack {
                        Text(title)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Color.textHint)
                    }
                }
            }
            .navigationTitle("选择相关分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(Color.textSecondary)
                        .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 生产分享页的模板选择为内联 Sheet；此入口复用同一模板枚举和系统工具栏层级。
private struct SheetPreviewCalendarTemplateNavigationStack: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTemplate = ReadCalendarShareTemplate.allCases.first!

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: 3),
                    spacing: Spacing.base
                ) {
                    ForEach(ReadCalendarShareTemplate.allCases) { template in
                        Button {
                            selectedTemplate = template
                        } label: {
                            VStack(spacing: Spacing.half) {
                                RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                                    .fill(Color.xmHex(UInt(template.palette.backgroundARGB & 0x00FF_FFFF)))
                                    .frame(height: 72)
                                    .overlay(alignment: .topTrailing) {
                                        if !template.isFree {
                                            Image(systemName: "crown.fill")
                                                .font(AppTypography.caption2)
                                                .foregroundStyle(Color.xmHex(UInt(template.palette.accentARGB & 0x00FF_FFFF)))
                                                .padding(Spacing.half)
                                        }
                                    }
                                    .overlay {
                                        if template == selectedTemplate {
                                            RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                                                .stroke(Color.appTint, lineWidth: 2)
                                        }
                                    }
                                Text(template.title)
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Spacing.screenEdge)
            }
            .navigationTitle("卡片模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(Color.textSecondary)
                        .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// 生产分享页的书籍排除 Sheet 为内联结构；列表内容来自当前隔离快照。
private struct SheetPreviewExcludedBooksNavigationStack: View {
    let books: [BookPickerBook]

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var isSearchActive = false
    @State private var excludedBookIDs = Set<Int64>()

    private var visibleBooks: [BookPickerBook] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return books }
        return books.filter {
            [$0.title, $0.author, $0.press]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        NavigationStack {
            XMScrollEdgeChrome(
                presentation: .overlaySoft,
                edges: [.top, .bottom],
                topBar: {
                    XMSystemSearchBar(
                        text: $searchText,
                        isActive: $isSearchActive,
                        prompt: "搜索要排除的书籍",
                        accessibilityIdentifier: "sheet-preview.excluded-books.search"
                    )
                    .padding(.top, Spacing.cozy)
                    .padding(.bottom, Spacing.half)
                },
                bottomBar: {
                    Color.surfaceSheet
                        .frame(height: Spacing.half)
                        .allowsHitTesting(false)
                }
            ) {
                if visibleBooks.isEmpty {
                    XMContentStateView(
                        role: .noResults,
                        title: "没有匹配的书籍",
                        message: searchText.isEmpty ? "当前范围没有可排除的书籍" : "请更换关键词"
                    )
                } else {
                    List(visibleBooks) { book in
                        Button {
                            if excludedBookIDs.contains(book.id) {
                                excludedBookIDs.remove(book.id)
                            } else {
                                excludedBookIDs.insert(book.id)
                            }
                        } label: {
                            HStack(spacing: Spacing.base) {
                                XMBookCover.fixedWidth(
                                    34,
                                    urlString: book.coverURL,
                                    border: .init(color: .surfaceBorderDefault, width: StrokeWidth.hairline)
                                )
                                Text(book.title)
                                    .font(AppTypography.body)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                XMSelectionIndicator(
                                    style: .checkbox,
                                    isSelected: excludedBookIDs.contains(book.id),
                                    font: AppTypography.body
                                )
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.surfaceSheet.ignoresSafeArea())
            .navigationTitle("排除书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(Color.textSecondary)
                        .accessibilityLabel("关闭")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private extension SheetProductionValidationTestView {
    static func tagOptions(from snapshot: SheetPreviewSnapshot?) -> [NoteEditorTagOption] {
        guard let entities = snapshot?.representativeTags, !entities.isEmpty else {
            return tags
        }
        return entities.map { NoteEditorTagOption(id: $0.id, title: $0.title) }
    }

    static func chapterOptions(from snapshot: SheetPreviewSnapshot?) -> [NoteEditorChapterOption] {
        guard let entities = snapshot?.representativeChapters, !entities.isEmpty else {
            return chapters
        }
        return entities.enumerated().map { index, item in
            NoteEditorChapterOption(
                id: item.id,
                title: item.title,
                parentID: 0,
                level: 1,
                pathText: item.title,
                isStarred: index == 0
            )
        }
    }

    @Observable
    final class FixturePresentation {
        var fixture: Fixture = .contentTags
        var isPresented = false

        func present(_ fixture: Fixture) {
            self.fixture = fixture
            isPresented = true
        }

        func dismiss() {
            isPresented = false
        }
    }

    enum Fixture: String, CaseIterable, Identifiable {
        case contentTags
        case noteChapterPicker
        case noteTagPicker
        case noteDate
        case noteSettings
        case noteComposer
        case batchChapter
        case batchTags
        case bookPlaceholder
        case bookshelfMoveGroup
        case bookshelfCollection
        case bookshelfSource
        case relatedBook
        case dailyBookFilter
        case timerStart
        case selectedBooks
        case readingTiming
        case collectionSummary
        case tagEdit
        case bookMetadata
        case wereadPreview
        case readingStatusEdit
        case chapterMove
        case chapterOrder
        case chapterBatch
        case chapterRemote
        case coverSearch
        case readingShare
        case aiText
        case aiTag
        case reviewSettings
        case mergeComposer
        case mergeImages
        case checkIn
        case timerFinish
        case bookPicker
        case activityShare
        case bookRating
        case yearMonthPicker
        case bookshelfDisplay
        case collectionDisplay
        case batchBookTags
        case batchReadStatus
        case readingDetailSetting
        case readingCoverPreview
        case readingProgress
        case heatmapHelp
        case readingGoal
        case aiPrompt
        case apiIntegration
        case backupHistory
        case backupRestore
        case collectionForm
        case collectionAnnualDescription
        case collectionRecommend
        case wereadImport
        case bookGroupName
        case sourceName
        case tagName
        case webDAVServer
        case localExportPicker
        case localImportPicker
        case calendarMonthSummary
        case calendarYearSummary
        case calendarSettings
        case readingYearSummary
        case relatedCategoryNavigation
        case templateNavigation
        case excludedBooksNavigation
        case xmTagNameCreate
        case xmTagNameRename

        var id: String { rawValue }

        var title: String {
            switch self {
            case .contentTags: "书摘标签只读"
            case .noteChapterPicker: "编辑器章节选择"
            case .noteTagPicker: "编辑器标签选择"
            case .noteDate: "编辑器创建时间"
            case .noteSettings: "编辑器设置"
            case .noteComposer: "书摘正文编辑"
            case .batchChapter: "批量章节选择"
            case .batchTags: "批量标签选择"
            case .bookPlaceholder: "相关书籍占位"
            case .bookshelfMoveGroup: "书架批量移组"
            case .bookshelfCollection: "书架批量加入书单"
            case .bookshelfSource: "书架批量设置来源"
            case .relatedBook: "相关书籍编辑"
            case .dailyBookFilter: "每日阅读书籍筛选"
            case .timerStart: "开始阅读计时"
            case .selectedBooks: "已选书籍管理"
            case .readingTiming: "编辑阅读时间"
            case .collectionSummary: "书单简介"
            case .tagEdit: "书摘标签编辑与命名"
            case .bookMetadata: "书单书籍信息编辑"
            case .wereadPreview: "微信读书导入预览"
            case .readingStatusEdit: "编辑阅读状态"
            case .chapterMove: "移动章节"
            case .chapterOrder: "调整章节顺序"
            case .chapterBatch: "批量录入目录"
            case .chapterRemote: "远端目录同步"
            case .coverSearch: "在线匹配封面"
            case .readingShare: "阅读详情分享与选项"
            case .aiText: "AI 释义结果"
            case .aiTag: "AI 标签建议"
            case .reviewSettings: "书摘回顾设置与标签范围"
            case .mergeComposer: "合并正文编辑"
            case .mergeImages: "合并图片编辑"
            case .checkIn: "编辑阅读打卡"
            case .timerFinish: "结束阅读计时"
            case .bookPicker: "生产书籍选择"
            case .activityShare: "系统分享"
            case .bookRating: "书籍评分"
            case .yearMonthPicker: "年月选择"
            case .bookshelfDisplay: "书架显示设置"
            case .collectionDisplay: "书单显示设置"
            case .batchBookTags: "书架批量标签"
            case .batchReadStatus: "书架批量阅读状态"
            case .readingDetailSetting: "阅读详情设置"
            case .readingCoverPreview: "阅读封面预览"
            case .readingProgress: "阅读进度编辑"
            case .heatmapHelp: "热力图说明"
            case .readingGoal: "阅读目标编辑"
            case .aiPrompt: "AI Prompt 编辑"
            case .apiIntegration: "API 集成编辑"
            case .backupHistory: "备份历史"
            case .backupRestore: "备份恢复确认"
            case .collectionForm: "书单表单"
            case .collectionAnnualDescription: "年度书单说明"
            case .collectionRecommend: "书单推荐语"
            case .wereadImport: "微信读书书单导入"
            case .bookGroupName: "书籍分组名称"
            case .sourceName: "来源名称"
            case .tagName: "标签名称"
            case .webDAVServer: "WebDAV 服务器"
            case .localExportPicker: "本地备份导出"
            case .localImportPicker: "本地备份导入"
            case .calendarMonthSummary: "阅读月度总结"
            case .calendarYearSummary: "阅读年度总结"
            case .calendarSettings: "阅读日历设置"
            case .readingYearSummary: "年度已读清单"
            case .relatedCategoryNavigation: "相关分类选择"
            case .templateNavigation: "分享模板选择"
            case .excludedBooksNavigation: "分享排除书籍"
            case .xmTagNameCreate: "标签命名创建"
            case .xmTagNameRename: "标签命名重命名"
            }
        }

        var subtitle: String {
            switch self {
            case .contentTags: "ContentViewerTagSheet"
            case .noteChapterPicker: "NoteEditorChapterPickerSheet"
            case .noteTagPicker: "NoteEditorTagPickerSheet"
            case .noteDate: "NoteEditorDateSheet"
            case .noteSettings: "NoteEditorSettingsSheet"
            case .noteComposer: "NoteTextComposerView"
            case .batchChapter: "NoteChapterSelectionSheet"
            case .batchTags: "NoteTagSelectionSheet"
            case .bookPlaceholder: "BookRelatedPlaceholderSheet"
            case .bookshelfMoveGroup: "BookshelfMoveGroupSheet"
            case .bookshelfCollection: "BookshelfBookCollectionSheet"
            case .bookshelfSource: "BookshelfBatchSourceSheet"
            case .relatedBook: "RelatedBookRelationEditorSheet"
            case .dailyBookFilter: "DailyReadingBookFilterSheet"
            case .timerStart: "ReadingTimerStartSheet"
            case .selectedBooks: "BookPickerSelectedBooksScreen"
            case .readingTiming: "ReadCalendarTimingEditorSheet"
            case .collectionSummary: "BookCollectionSummarySheet"
            case .tagEdit: "NoteReviewTagEditSheet / XMTagNameSheet"
            case .bookMetadata: "BookCollectionBookMetadataEditSheet"
            case .wereadPreview: "BookCollectionWereadImportPreviewSheet"
            case .readingStatusEdit: "BookReadingStatusSheet"
            case .chapterMove: "ChapterMoveSheet"
            case .chapterOrder: "ChapterSiblingOrderSheet"
            case .chapterBatch: "ChapterBatchImportSheet"
            case .chapterRemote: "ChapterRemoteSyncSheet"
            case .coverSearch: "BookCollectionCoverSearchSheet"
            case .readingShare: "BookReadingDetailShareSheet / 分享选项"
            case .aiText: "AITextResultSheet"
            case .aiTag: "AIAutoTagSheet"
            case .reviewSettings: "NoteReviewSettingsSheet / NoteReviewTagSelectionSheet"
            case .mergeComposer: "NoteMergeComposerSheet"
            case .mergeImages: "NoteMergeImageEditorSheet"
            case .checkIn: "ReadCalendarCheckInSheet"
            case .timerFinish: "ReadingTimerFinishSheet"
            case .bookPicker: "BookPickerView"
            case .activityShare: "XMActivityShareSheet"
            case .bookRating: "XMBookRatingSheet"
            case .yearMonthPicker: "XMYearMonthPickerSheet"
            case .bookshelfDisplay: "BookshelfDisplaySettingSheet"
            case .collectionDisplay: "BookCollectionDisplaySettingSheet"
            case .batchBookTags: "BookshelfBatchTagsSheet"
            case .batchReadStatus: "BookshelfBatchReadStatusSheet"
            case .readingDetailSetting: "BookReadingDetailSettingSheet"
            case .readingCoverPreview: "BookReadingCoverPreview"
            case .readingProgress: "BookReadingProgressSheet"
            case .heatmapHelp: "HeatmapHelpSheetView"
            case .readingGoal: "ReadingGoalEditorSheet"
            case .aiPrompt: "AIConfigurationPromptEditSheet"
            case .apiIntegration: "ApiIntegrationEditSheet"
            case .backupHistory: "BackupHistorySheetView"
            case .backupRestore: "BackupRestoreConfirmSheet"
            case .collectionForm: "BookCollectionFormSheet"
            case .collectionAnnualDescription: "BookCollectionAnnualDescriptionSheet"
            case .collectionRecommend: "BookCollectionRecommendSheet"
            case .wereadImport: "BookCollectionWereadImportSheet"
            case .bookGroupName: "BookGroupNameEditSheet"
            case .sourceName: "SourceNameEditSheet"
            case .tagName: "TagNameEditSheet"
            case .webDAVServer: "WebDAVServerFormView"
            case .localExportPicker: "LocalBackupExportDocumentPicker"
            case .localImportPicker: "LocalBackupImportDocumentPicker"
            case .calendarMonthSummary: "ReadCalendarMonthSummarySheet"
            case .calendarYearSummary: "ReadCalendarYearSummarySheet"
            case .calendarSettings: "ReadCalendarSettingsSheet"
            case .readingYearSummary: "ReadingYearSummarySheet"
            case .relatedCategoryNavigation: "相关分类选择 NavigationStack"
            case .templateNavigation: "模板选择 NavigationStack"
            case .excludedBooksNavigation: "书籍排除 NavigationStack"
            case .xmTagNameCreate: "XMTagNameSheet · 新建"
            case .xmTagNameRename: "XMTagNameSheet · 重命名"
            }
        }

        static func productionFixture(for owner: String) -> Fixture? {
            if owner.hasPrefix("BookPickerView") { return .bookPicker }
            if owner.hasPrefix("BookReadingStatusSheet") { return .readingStatusEdit }
            if owner.hasPrefix("XMYearMonthPickerSheet") { return .yearMonthPicker }
            if owner.hasPrefix("XMActivityShareSheet") { return .activityShare }
            if owner.hasPrefix("XMBookRatingSheet") { return .bookRating }
            if owner == "XMTagNameSheet · 新建" { return .xmTagNameCreate }
            if owner == "XMTagNameSheet · 重命名" { return .xmTagNameRename }
            if owner.hasPrefix("分享选项") { return .readingShare }
            if owner == "AIConfigurationPromptEditSheet" { return .aiPrompt }
            if owner == "ApiIntegrationEditSheet" { return .apiIntegration }
            if owner == "BackupHistorySheetView" { return .backupHistory }
            if owner == "BackupRestoreConfirmSheet" { return .backupRestore }
            if owner == "BookCollectionFormSheet" { return .collectionForm }
            if owner == "BookCollectionAnnualDescriptionSheet" { return .collectionAnnualDescription }
            if owner == "BookCollectionRecommendSheet" { return .collectionRecommend }
            if owner == "BookCollectionWereadImportSheet" { return .wereadImport }
            if owner == "BookGroupNameEditSheet" { return .bookGroupName }
            if owner == "SourceNameEditSheet" { return .sourceName }
            if owner == "TagNameEditSheet" { return .tagName }
            if owner == "WebDAVServerFormView" { return .webDAVServer }
            if owner == "LocalBackupExportDocumentPicker" { return .localExportPicker }
            if owner == "LocalBackupImportDocumentPicker" { return .localImportPicker }
            if owner == "ReadCalendarMonthSummarySheet" { return .calendarMonthSummary }
            if owner == "ReadCalendarYearSummarySheet" { return .calendarYearSummary }
            if owner == "ReadCalendarSettingsSheet" { return .calendarSettings }
            if owner == "ReadingYearSummarySheet" { return .readingYearSummary }
            if owner == "相关分类选择 NavigationStack" { return .relatedCategoryNavigation }
            if owner == "模板选择 NavigationStack" { return .templateNavigation }
            if owner == "书籍排除 NavigationStack" { return .excludedBooksNavigation }

            return allCases.first { fixture in
                fixture.subtitle
                    .components(separatedBy: " / ")
                    .contains(where: { owner.hasPrefix($0) || $0.hasPrefix(owner) })
            }
        }
    }

    static let tags = [
        NoteEditorTagOption(id: 1, title: "设计系统"),
        NoteEditorTagOption(id: 2, title: "用户体验"),
        NoteEditorTagOption(id: 3, title: "交互设计"),
        NoteEditorTagOption(id: 4, title: "知识管理")
    ]

    static let chapters = [
        NoteEditorChapterOption(id: 1, title: "设计原则", parentID: 0, level: 1, pathText: "设计原则", isStarred: true),
        NoteEditorChapterOption(id: 2, title: "视觉层级", parentID: 1, level: 2, pathText: "设计原则 / 视觉层级"),
        NoteEditorChapterOption(id: 3, title: "交互反馈", parentID: 1, level: 2, pathText: "设计原则 / 交互反馈"),
        NoteEditorChapterOption(id: 4, title: "可访问性", parentID: 0, level: 1, pathText: "可访问性")
    ]

    static let pickerBooks = [
        BookPickerBook(id: 1, title: "设计中的设计", author: "原研哉"),
        BookPickerBook(id: 2, title: "写给大家看的设计书", author: "Robin Williams"),
        BookPickerBook(id: 3, title: "点石成金", author: "Steve Krug")
    ]

    static let calendarBooks = [
        ReadCalendarDayBook(id: 1, name: "设计中的设计", coverURL: "", firstEventTime: 1_725_000_000_000),
        ReadCalendarDayBook(id: 2, name: "点石成金", coverURL: "", firstEventTime: 1_725_000_000_000)
    ]

    static let dailyBooks = calendarBooks.enumerated().map { index, book in
        DailyReadingBookSummary(
            book: book,
            readSeconds: (index + 1) * 1_800,
            noteCount: index + 1,
            relevantCount: index,
            reviewCount: 0,
            checkInCount: 1,
            readDoneCount: index
        )
    }

    static let timingEvent = TimelineReadTimingEvent(
        elapsedSeconds: 2_700,
        startTime: Int64(Date().addingTimeInterval(-2_700).timeIntervalSince1970 * 1_000),
        endTime: Int64(Date().timeIntervalSince1970 * 1_000),
        fuzzyReadDate: 0,
        position: 128,
        recordedPositionUnit: 1,
        insight: "系统控件让操作层级更稳定，也更容易被理解。"
    )

    static let placeholderBook = BookContentRelatedItem(
        id: 1,
        destination: .book(bookID: 10),
        title: "About Face 4",
        subtitle: "Alan Cooper",
        contentHTML: "",
        coverURL: "",
        createdDate: 1_725_000_000_000,
        isPlaceholder: true
    )

    static let batchMoveGroups = [
        BookshelfMoveGroupOption(id: 1, title: "设计与产品", bookCount: 12, representativeCovers: []),
        BookshelfMoveGroupOption(id: 2, title: "认知与心理", bookCount: 8, representativeCovers: []),
        BookshelfMoveGroupOption(id: 3, title: "稍后整理", bookCount: 5, representativeCovers: [])
    ]

    static let batchCollections = [
        BookCollectionSummary(
            id: 1,
            title: "交互设计精选",
            description: "设计原则、信息层级与可用性实践",
            bookCount: 9,
            representativeCovers: []
        ),
        BookCollectionSummary(
            id: 2,
            title: "产品思维",
            description: "从洞察到验证的产品方法",
            bookCount: 6,
            representativeCovers: []
        ),
        BookCollectionSummary(
            id: 3,
            title: "2026 阅读计划",
            description: "今年准备完成的重点书目",
            bookCount: 11,
            representativeCovers: []
        )
    ]

    static let batchSources = [
        BookshelfSourceOption(id: 1, title: "纸质书", category: .mine),
        BookshelfSourceOption(id: 2, title: "微信读书", category: .mine),
        BookshelfSourceOption(id: 3, title: "豆瓣读书", category: .appDefault),
        BookshelfSourceOption(id: 4, title: "手动录入", category: .appDefault)
    ]

    static let bookTagOptions = [
        BookEditorNamedOption(id: 1, title: "设计系统"),
        BookEditorNamedOption(id: 2, title: "用户体验"),
        BookEditorNamedOption(id: 3, title: "交互设计"),
        BookEditorNamedOption(id: 4, title: "知识管理")
    ]

    static let readStatusNamedOptions = [
        BookEditorNamedOption(id: 1, title: "想读"),
        BookEditorNamedOption(id: 2, title: "阅读中"),
        BookEditorNamedOption(id: 3, title: "读完"),
        BookEditorNamedOption(id: 4, title: "放弃")
    ]

    static let collectionDetail = BookCollectionDetail(
        id: 1,
        title: "交互设计精选",
        description: "围绕交互原则、视觉层级与可访问性整理的一组设计书籍。",
        kind: .manual,
        order: 0,
        year: nil,
        targetReadCount: 12,
        books: []
    )

    static let annualCollectionDetail = BookCollectionDetail(
        id: 2,
        title: "2026 年阅读",
        description: "记录这一年的阅读主题、完成情况与重要收获。",
        kind: .annual,
        order: 1,
        year: Calendar.current.component(.year, from: Date()),
        targetReadCount: 24,
        books: []
    )

    static let safeBackupHistory = [
        BackupFileInfo(
            id: "sheet-preview-backup",
            name: "XMNote-Preview-20260828.zip",
            remoteIdentifier: "debug/safe-preview",
            size: 1_248_320,
            lastModified: Date(),
            deviceName: "Sheet 校准模拟器",
            backupDate: Date(),
            provider: .webdav
        )
    ]

    static let safeRestoreTarget = BackupRestoreTarget(
        source: .cloud(safeBackupHistory[0]),
        title: "从备份恢复",
        sourceName: "安全外部模拟",
        deviceName: safeBackupHistory[0].deviceName,
        backupDate: safeBackupHistory[0].backupDate
    )

    static var safeExportURL: URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("XMNote-Sheet-Preview-Backup.zip")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("XMNote Sheet preview only".utf8).write(to: url, options: .atomic)
        }
        return url
    }

    static let fixtureBook = BookshelfBookListItem(
        id: 1,
        title: "设计中的设计",
        author: "原研哉",
        cover: "",
        readStatusId: 2,
        readStatusName: "阅读中",
        readStatusBadgeTitle: "阅读中",
        sourceName: "纸质书",
        press: "山东人民出版社",
        pubDateText: "2006-11",
        score: 80,
        noteCount: 12,
        readingProgressText: "第 128 页"
    )

    static let collectionMetadataEdit = BookCollectionBookMetadataEdit(
        item: BookCollectionBookItem(
            id: 1,
            collectionID: 1,
            book: fixtureBook,
            summary: "设计不只关乎外观，也关乎关系与秩序。",
            summaryPlainText: "设计不只关乎外观，也关乎关系与秩序。",
            recommend: "帮助重新理解日常物品与信息之间的关系。",
            isPlaceholder: false,
            order: 0,
            createdDate: 1_725_000_000_000,
            updatedDate: 1_725_000_000_000
        )
    )

    static let collectionImportPreview = BookCollectionImportPreview(
        sourceURL: "https://weread.qq.com/web/bookList/validation",
        title: "交互设计阅读清单",
        description: "从基础原则到可用性实践的一组书籍。",
        books: [
            BookCollectionImportPreviewBook(title: "设计中的设计", author: "原研哉"),
            BookCollectionImportPreviewBook(title: "写给大家看的设计书", author: "Robin Williams"),
            BookCollectionImportPreviewBook(title: "点石成金", author: "Steve Krug"),
            BookCollectionImportPreviewBook(title: "About Face 4", author: "Alan Cooper")
        ]
    )

    static let readingDetailBook = BookReadingDetailBook(
        id: 1,
        name: "设计中的设计",
        coverURL: "",
        author: "原研哉",
        translator: "",
        isbn: "9787209041065",
        publicationDate: "2006-11",
        press: "山东人民出版社",
        summary: "从日常生活重新审视设计的意义。",
        score: 80,
        bookType: 1,
        currentPositionUnit: 2,
        positionUnit: 2,
        readPosition: 128,
        totalPosition: 0,
        totalPagination: 280,
        readStatusID: 2,
        readStatusName: "阅读中",
        readStatusChangedAt: 1_725_000_000_000,
        readDoneCount: 1,
        sourceName: "纸质书",
        groupNames: ["设计"],
        tagNames: ["设计系统", "用户体验"],
        wordCount: nil,
        price: 68,
        createdAt: 1_725_000_000_000
    )

    static let readingStatusOptions = [
        BookReadingStatusOption(id: 1, title: "想读"),
        BookReadingStatusOption(id: 2, title: "阅读中"),
        BookReadingStatusOption(id: 3, title: "读完"),
        BookReadingStatusOption(id: 5, title: "搁置"),
        BookReadingStatusOption(id: 4, title: "放弃")
    ]

    static let readingStatusHistory = BookReadingStatusHistoryItem(
        recordID: 11,
        statusID: 2,
        statusName: "阅读中",
        changedAt: 1_725_000_000_000,
        isSyntheticShelfNode: false
    )

    static let chapterManagementItems = [
        ChapterManagementItem(
            id: 1,
            bookID: 1,
            parentID: 0,
            title: "设计作为秩序",
            remark: "",
            order: 0,
            level: 1,
            pathTitles: ["设计作为秩序"],
            directNoteCount: 3,
            descendantNoteCount: 7,
            childCount: 2,
            isStarred: true
        ),
        ChapterManagementItem(
            id: 2,
            bookID: 1,
            parentID: 0,
            title: "白",
            remark: "",
            order: 1,
            level: 1,
            pathTitles: ["白"],
            directNoteCount: 2,
            descendantNoteCount: 2,
            childCount: 0,
            isStarred: false
        ),
        ChapterManagementItem(
            id: 3,
            bookID: 1,
            parentID: 0,
            title: "再设计",
            remark: "",
            order: 2,
            level: 1,
            pathTitles: ["再设计"],
            directNoteCount: 4,
            descendantNoteCount: 4,
            childCount: 0,
            isStarred: false
        )
    ]

    static let chapterMoveTargets = [
        ChapterMoveTarget(id: 0, title: "根目录", pathText: "移动到根目录", level: 0, disabledReason: nil),
        ChapterMoveTarget(id: 1, title: "设计作为秩序", pathText: "设计作为秩序", level: 1, disabledReason: nil),
        ChapterMoveTarget(id: 2, title: "白", pathText: "白", level: 1, disabledReason: "不能移动到自身"),
        ChapterMoveTarget(id: 3, title: "再设计", pathText: "再设计", level: 1, disabledReason: nil)
    ]

    static let remoteDiscovery = ChapterRemoteCatalogDiscovery(
        bookTitle: "设计中的设计",
        matchMode: .bookTitleCandidates,
        candidates: [
            ChapterRemoteCatalogCandidate(
                id: "designing-design",
                remoteBookID: 101,
                doubanID: 1941558,
                title: "设计中的设计",
                author: "原研哉",
                press: "山东人民出版社",
                catalogTitles: ["设计的发生", "RE-DESIGN", "白", "外部与内部"]
            )
        ]
    )

    static let remoteCatalogItems = [
        ChapterRemoteCatalogItem(id: "designing-design-0", title: "设计的发生", originalIndex: 0),
        ChapterRemoteCatalogItem(id: "designing-design-1", title: "RE-DESIGN：日常用品的再设计", originalIndex: 1),
        ChapterRemoteCatalogItem(id: "designing-design-2", title: "白", originalIndex: 2),
        ChapterRemoteCatalogItem(id: "designing-design-3", title: "外部与内部", originalIndex: 3)
    ]

    static let reviewSettings = NoteReviewSettings(
        selectedBookIDs: [1, 2],
        selectedTagIDs: [1, 3],
        tagMatchRule: .any,
        sortRule: .random,
        palette: .paper,
        textAlignment: .leading,
        backgroundMode: .color,
        backgroundImageURL: nil,
        customBackgroundStartHex: nil,
        customBackgroundEndHex: nil,
        customTextColorHex: nil,
        fontSelection: .system
    )

    static let reviewTagOptions = [
        NoteReviewTagOption(id: 1, title: "设计系统", noteCount: 18),
        NoteReviewTagOption(id: 2, title: "用户体验", noteCount: 12),
        NoteReviewTagOption(id: 3, title: "交互设计", noteCount: 9),
        NoteReviewTagOption(id: 4, title: "知识管理", noteCount: 6)
    ]

    static let noteMergeDraft = NoteMergeDraft(
        sourceNoteIDs: [1, 2],
        sourceNotes: [
            NoteExcerptListItem(
                id: 1,
                bookID: 1,
                bookTitle: "设计中的设计",
                bookAuthor: "原研哉",
                bookCoverURL: "",
                chapterID: 1,
                chapterTitle: "设计作为秩序",
                contentHTML: "<p>设计不是装饰，而是建立秩序。</p>",
                ideaHTML: "<p>秩序降低了理解成本。</p>",
                plainContent: "设计不是装饰，而是建立秩序。",
                plainIdea: "秩序降低了理解成本。",
                position: "128",
                positionUnit: 2,
                includeTime: true,
                createdDate: 1_725_000_000_000,
                imageURLs: [],
                tags: []
            ),
            NoteExcerptListItem(
                id: 2,
                bookID: 1,
                bookTitle: "设计中的设计",
                bookAuthor: "原研哉",
                bookCoverURL: "",
                chapterID: 2,
                chapterTitle: "白",
                contentHTML: "<p>留白让关系与层级变得清楚。</p>",
                ideaHTML: "<p>克制也是一种表达。</p>",
                plainContent: "留白让关系与层级变得清楚。",
                plainIdea: "克制也是一种表达。",
                position: "176",
                positionUnit: 2,
                includeTime: true,
                createdDate: 1_725_086_400_000,
                imageURLs: [],
                tags: []
            )
        ],
        book: BookPickerBook(
            id: 1,
            title: "设计中的设计",
            author: "原研哉",
            press: "山东人民出版社",
            positionUnit: 2,
            totalPagination: 280
        ),
        contentNoteIDs: [1, 2],
        ideaNoteIDs: [1, 2],
        contentRule: .oneLine,
        ideaRule: .twoLines,
        contentHTML: "<p>设计不是装饰，而是建立秩序。</p><p>留白让关系与层级变得清楚。</p>",
        ideaHTML: "<p>秩序降低了理解成本。</p><p>克制也是一种表达。</p>",
        position: "176",
        positionUnit: 2,
        includeTime: true,
        createdDate: 1_725_086_400_000,
        chapterID: 1,
        chapterTitle: "设计作为秩序",
        selectedTags: Array(tags.prefix(2)),
        imageItems: []
    )

    static let readingDetailSnapshot = BookReadingDetailSnapshot(
        book: readingDetailBook,
        heatmapDays: [:],
        heatmapEarliestDate: nil,
        heatmapLatestDate: nil,
        analytics: BookReadingAnalytics(
            readingDayCount: 12,
            lastReadingAt: 1_725_086_400_000,
            progress: BookReadingProgress(
                unit: 2,
                currentValue: 128,
                totalValue: 280,
                fraction: 128.0 / 280.0
            ),
            totalReadingSeconds: 18_000,
            actualStartAt: 1_724_000_000_000,
            statusStartAt: 1_724_000_000_000,
            noteCount: 12,
            ideaCount: 8
        ),
        monthlyDurations: [],
        statusHistory: [readingStatusHistory],
        statusOptions: readingStatusOptions
    )

    static let timerBookContext = ReadingTimerBookContext(
        id: 1,
        name: "设计中的设计",
        author: "原研哉",
        coverURL: "",
        readStatusId: 2,
        readPosition: 128,
        totalPosition: 0,
        totalPagination: 280,
        currentPositionUnit: 2,
        positionUnit: 2
    )

    static let timerSession = ReadingTimerSession(
        id: 99,
        book: timerBookContext,
        startTime: Date().addingTimeInterval(-2_700),
        endTime: Date(),
        interruptTime: nil,
        elapsedSeconds: 2_700,
        countdownSeconds: 0,
        pausedDurationMillis: 0,
        isPaused: false,
        status: .stoppedPendingSave,
        position: 128,
        recordedPositionUnit: 2,
        fuzzyReadDate: nil,
        insight: "系统结构让操作更稳定。",
        createdDate: Date().addingTimeInterval(-2_700),
        updatedDate: Date()
    )
}

private struct SheetValidationBackupServerRepository: BackupServerRepositoryProtocol {
    func fetchServers() async throws -> [BackupServerRecord] { [] }
    func fetchCurrentServer() async throws -> BackupServerRecord? { nil }
    func saveServer(_ input: BackupServerFormInput, editingServer: BackupServerRecord?) async throws {
        try await Task.sleep(for: .milliseconds(650))
    }
    func delete(_ server: BackupServerRecord) async throws { }
    func select(_ server: BackupServerRecord) async throws { }
    func testConnection(_ input: BackupServerFormInput) async throws {
        try await Task.sleep(for: .milliseconds(650))
    }
}

private struct SheetValidationAIRepository: AIRepositoryProtocol {
    func fetchConfiguration() async throws -> AIConfigurationSnapshot {
        AIConfigurationSnapshot(
            configuration: .androidAlignedDefault,
            providersWithStoredKey: [.deepSeek]
        )
    }

    func saveConfiguration(_ configuration: AIConfiguration, apiKey: String?) async throws { }

    func savePromptTemplate(_ template: AIPromptTemplate, for kind: AIPromptKind) async throws { }

    func makePromptPreview(
        kind: AIPromptKind,
        template: AIPromptTemplate,
        sample: AIPromptSampleContext
    ) throws -> AIPromptRequestPreview {
        try AIPromptRequestBuilder.preview(
            kind: kind,
            template: template,
            replacements: sample.replacements
        )
    }

    func streamPromptTrial(
        kind: AIPromptKind,
        template: AIPromptTemplate,
        sample: AIPromptSampleContext,
        comparesDefault: Bool
    ) -> AsyncThrowingStream<AIPromptTrialEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                .content(
                    target: .current,
                    markdown: "## 核心观点\n\n当前提示词的试运行结果"
                )
            )
            continuation.yield(.completed(target: .current))
            if comparesDefault {
                continuation.yield(
                    .content(
                        target: .appDefault,
                        markdown: "## 核心观点\n\n应用原始提示词的试运行结果"
                    )
                )
                continuation.yield(.completed(target: .appDefault))
            }
            continuation.finish()
        }
    }

    func optimizePrompt(
        kind: AIPromptKind,
        field: AIPromptEditorField,
        currentText: String,
        instruction: String
    ) async throws -> String {
        currentText
    }

    func deleteAPIKey(for provider: AIProvider) async throws { }

    func streamNoteExplanation(noteID: Int64) -> AsyncThrowingStream<String, Error> {
        explanationStream()
    }

    func streamTextLookup(input: AITextLookupInput) -> AsyncThrowingStream<String, Error> {
        explanationStream()
    }

    func streamTagSuggestions(noteID: Int64) -> AsyncThrowingStream<AIAutoTagGenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.content("正在从书摘中提炼长期可复用的主题…"))
            continuation.yield(.completed([
                AIAutoTagSuggestion(
                    name: "设计系统",
                    isExisting: true,
                    reason: "内容关注界面秩序与一致性。",
                    isSelected: true
                ),
                AIAutoTagSuggestion(
                    name: "交互反馈",
                    isExisting: false,
                    reason: "强调用户操作后的清晰反馈。",
                    isSelected: true
                ),
                AIAutoTagSuggestion(
                    name: "视觉层级",
                    isExisting: true,
                    reason: "讨论信息优先级与留白关系。",
                    isSelected: false
                )
            ]))
            continuation.finish()
        }
    }

    func applyAutoTags(noteID: Int64, suggestions: [AIAutoTagSuggestion]) async throws { }

    private func explanationStream() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(
                """
                ## 核心观点
                设计的价值不是增加装饰，而是用清楚的秩序降低理解与操作成本。

                ## 解析
                - **视觉层级**帮助用户先看到最重要的内容。
                - **交互反馈**让用户知道动作已经发生，以及下一步可以做什么。

                ## 延伸思考
                克制的界面并不等于缺少设计；恰当的留白与系统控件，往往比额外装饰更有品质。
                """
            )
            continuation.finish()
        }
    }
}
#endif
