/**
 * [INPUT]: 依赖 NoteImportPreviewViewModel、原生搜索/菜单、BookPickerView 与项目列表和 Sheet 组件
 * [OUTPUT]: 提供解析草稿的来源标记、全来源书摘预览与确认导入
 * [POS]: Views/Personal/DataImport 的预览与提交层；输入准备由 NoteImportSourceScreen 独立持有
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Observation
import SwiftUI

extension Array where Element == NoteImportDraftBook {
    /// 在进入统一预览前设置来源身份，保留各导出版本共享的业务来源。
    func settingSource(for parserID: NoteImportParserID) -> [NoteImportDraftBook] {
        let sourceID: Int64 = switch parserID {
        case .kindle: 2; case .kindleApp: 3; case .wereadOld, .wereadPre830, .weread830: 4
        case .appleBooks: 5; case .moonReader: 6; case .duokan: 7; case .ireaderFile: 8
        case .doubanRead: 9; case .ireaderSelected: 10; case .jdReader: 11; case .booxOld, .booxNew: 12
        case .dangdang: 13; case .koreader: 14; case .reader163: 15; case .doubanApp: 16
        case .legado: 17; case .neatReader: 18; case .hanwang: 19; case .fanqie: 20
        case .dimo: 21; case .koodo: 23; case .ireaderEpub: 24; case .dedao: 25
        case .reeden: 26; case .readingo: 27
        }
        return map { source in var value = source; value.source = sourceID; return value }
    }
}

/// 全来源预览共享连续列表、直接选择和系统底部搜索。
struct UnifiedNoteImportPreviewView: View {
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var model: NoteImportPreviewViewModel
    @State private var isSearchActive = false
    @State private var showsFilters = false
    @State private var showsSelected = false
    @State private var showsIssuesOnly = false
    @State private var showsExitDialog = false
    @State private var showsReplacement = false
    @State private var isCheckingCommit = false
    @State private var retriesAfterResultDismissal = false
    private let onFinished: (() -> Void)?

    /// 来源入口持有会话，子页不重建选择身份。
    init(books: [NoteImportDraftBook], repository: any NoteImportRepositoryProtocol, preferenceKey: String? = nil,
         commit: NoteImportPreviewViewModel.Commit? = nil, onFinished: (() -> Void)? = nil) {
        _model = State(initialValue: .init(books: books, repository: repository, preferenceKey: preferenceKey, commit: commit))
        self.onFinished = onFinished
    }
    /// 微信批次返回复用同一会话及完成结果。
    init(model: NoteImportPreviewViewModel, onFinished: @escaping () -> Void) {
        _model = State(initialValue: model); self.onFinished = onFinished
    }
    var body: some View {
        XMScrollEdgeChrome(presentation: .overlaySoft, edges: .top, topBar: { controls }) {
            NoteImportPreviewBookList(model: model, books: model.visibleBooks, emptyAction: resetVisibleScope)
                .disabled(isCheckingCommit)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .navigationTitle("导入预览")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, isPresented: $isSearchActive, placement: .toolbar, prompt: "搜索书名或作者")
        .searchToolbarBehavior(.automatic)
        .navigationBarBackButtonHidden(model.hasUnsavedChanges || model.isCommitting)
        .navigationPopGuard(canPop: !model.hasUnsavedChanges && !model.isCommitting, onBlockedAttempt: requestExit)
        .interactiveDismissDisabled(model.hasUnsavedChanges || model.isCommitting)
        .toolbar {
            if model.hasUnsavedChanges || model.isCommitting {
                ToolbarItem(placement: .topBarLeading) { TopBarBackButton(action: requestExit) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: beginImport) {
                    Text("导入").foregroundStyle(Color.primaryActionForeground).opacity(model.isCommitting || isCheckingCommit ? 0 : 1)
                        .overlay { if model.isCommitting || isCheckingCommit { ProgressView().controlSize(.small).tint(Color.primaryActionForeground) } }
                }
                .buttonStyle(.borderedProminent).tint(Color.appTint)
                .disabled(model.selectedCount == 0 || model.isLocked || isCheckingCommit)
                .accessibilityLabel("导入已选书籍").accessibilityValue("已选 \(model.selectedCount) 本")
                .accessibilityIdentifier("note-import.commit")
            }
        }
        .task { await model.prepare() }
        .sheet(isPresented: $showsFilters) { NoteImportFilterSheet(model: model) }
        .sheet(isPresented: $model.showsResult, onDismiss: {
            if retriesAfterResultDismissal { retriesAfterResultDismissal = false; beginImport() }
        }) {
            NoteImportResultSheet(model: model, onFinish: finish, onRetry: {
                retriesAfterResultDismissal = true; model.showsResult = false
            })
        }
        .navigationDestination(isPresented: $showsSelected) {
            NoteImportPreviewBookList(model: model, books: showsIssuesOnly ? model.pendingIssues : model.selectedBooks)
                .navigationTitle(showsIssuesOnly ? "待处理书籍" : "已选书籍")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空选择") { model.clearSelection() }.disabled(model.isLocked || model.selectedCount == 0)
                            .xmToolbarNeutralTint()
                    }
                }
        }
        .confirmationDialog("替换本地阅读时长？", isPresented: $showsReplacement, titleVisibility: .visible) {
            Button("替换并导入", role: .destructive) { model.beginCommit() }
            Button("取消", role: .cancel) { }
        } message: { Text(model.replacementMessage ?? "") }
        .confirmationDialog(model.isCommitting ? "停止导入？" : "放弃本次导入的修改？", isPresented: $showsExitDialog) {
            if model.isCommitting { Button("停止导入", role: .destructive) { model.stopImport() } }
            else { Button("放弃修改", role: .destructive) { model.discardPendingChanges(); dismiss() } }
            Button("继续", role: .cancel) { }
        } message: { if model.isCommitting { Text("已完成的书籍会保留。") } }
        .xmSystemAlert(isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }),
            descriptor: model.errorMessage.map { message in
                .init(title: "无法完成操作", message: message, actions: [.init(title: "知道了") { model.errorMessage = nil }])
            })
    }
    private var controls: some View {
        VStack(spacing: Spacing.none) {
            if model.isPreparing || model.isCommitting {
                HStack(spacing: Spacing.cozy) {
                    ProgressView().controlSize(.small)
                    Text(model.isPreparing ? "正在准备预览…" : model.progressText).font(AppTypography.footnote)
                    Spacer()
                }
                .foregroundStyle(Color.textSecondary).frame(minHeight: InteractionMetrics.minimumTouchTarget)
            } else {
                if !model.capabilities.statuses.isEmpty { NoteImportStatusSegments(model: model) }
                ViewThatFits(in: .horizontal) {
                    HStack { selectionControls }
                    VStack(alignment: .leading, spacing: Spacing.none) { selectionControls }
                }
                .buttonStyle(.plain)
                .font(AppTypography.footnote)
                .foregroundStyle(Color.textSecondary)
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                if !model.filter.summary.isEmpty {
                    HStack(spacing: Spacing.cozy) {
                        Text(model.filter.summary).font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
                        Spacer()
                        Button("清除") {
                            var filter = model.filter; filter.onlyWithNotes = false; filter.duration = .all
                            model.applyFilter(filter)
                        }
                        .font(AppTypography.footnote).tint(Color.textSecondary)
                        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.cozy)
        .disabled(model.isLocked || isCheckingCommit)
    }
    @ViewBuilder private var selectionControls: some View {
        controlButton(model.allVisibleSelected ? "取消全选" : (model.query.isEmpty && model.filter.additionalCount == 0 && model.filter.statuses.isEmpty ? "全选" : "全选结果")) {
            model.selectVisible(!model.allVisibleSelected)
        }
        .disabled(model.visibleBooks.allSatisfy(\.isCompleted))
        Spacer(minLength: Spacing.cozy)
        if model.selectedCount > 0 {
            controlButton("已选 \(model.selectedCount) 本") { showsIssuesOnly = false; showsSelected = true }
            Spacer(minLength: Spacing.cozy)
        }
        Button { isSearchActive = false; showsFilters = true } label: {
            Label("筛选", systemImage: "line.3.horizontal.decrease")
                .frame(minHeight: InteractionMetrics.minimumTouchTarget).contentShape(Rectangle())
        }
        .accessibilityIdentifier("note-import.filter")
    }
    /// 直接选择操作保持完整触摸高度，不依赖文字本身的小命中框。
    private func controlButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(minHeight: InteractionMetrics.minimumTouchTarget).contentShape(Rectangle())
        }
    }
    /// MainActor 重读提交依据；未解决问题先定位，不通过禁用掩盖原因。
    private func beginImport() {
        guard !isCheckingCommit else { return }
        isSearchActive = false; isCheckingCommit = true
        Task {
            await model.prepareCommit()
            isCheckingCommit = false
            if !model.pendingIssues.isEmpty { showsIssuesOnly = true; showsSelected = true }
            else if model.replacementMessage != nil { showsReplacement = true }
            else { model.beginCommit() }
        }
    }
    /// 无结果恢复只改变显示范围。
    private func resetVisibleScope() {
        if !model.query.isEmpty { model.query = "" } else { model.applyFilter(.init()) }
    }
    /// 优先结束搜索，草稿保护沿用现有任务退出语义。
    private func requestExit() {
        isSearchActive = false
        if model.hasUnsavedChanges || model.isCommitting { showsExitDialog = true } else { dismiss() }
    }
    /// 批次完成返回批次列表，普通来源结束当前任务。
    private func finish() {
        model.showsResult = false
        if let onFinished { onFinished() } else { navigationCoordinator.dismissTask() }
    }
}

/// 局部状态分类；大字号或多分类允许横向展开，不借用一级导航切换器。
private struct NoteImportStatusSegments: View {
    @Bindable var model: NoteImportPreviewViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var options: [NoteImportReadingStatus?] {
        [nil] + NoteImportReadingStatus.allCases.filter { model.capabilities.statuses.contains($0) }.map(Optional.some)
    }
    private var selection: Binding<NoteImportReadingStatus?> {
        Binding(get: { model.filter.statuses.first }, set: { model.filter.statuses = $0.map { [$0] } ?? [] })
    }
    var body: some View {
        Group {
            if options.count <= 4 && !dynamicTypeSize.isAccessibilitySize {
                Picker("阅读状态", selection: selection) {
                    ForEach(options, id: \.self) { status in Text(title(status)).tag(status) }
                }.pickerStyle(.segmented)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.compact) {
                        ForEach(options, id: \.self) { status in
                            Button { selection.wrappedValue = status } label: {
                                Text(title(status)).font(AppTypography.subheadline)
                                    .padding(.horizontal, Spacing.base)
                                    .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                                    .background(selection.wrappedValue == status ? Color.surfaceCard : Color.clear, in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection.wrappedValue == status ? .isSelected : [])
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(Color.textPrimary).tint(Color.textPrimary)
        .padding(.bottom, Spacing.cozy)
    }
    /// 包含当前条件下数量，零结果分类仍可识别。
    private func title(_ status: NoteImportReadingStatus?) -> String { "\(status?.title ?? "全部") \(model.count(for: status))" }
}

/// 中性短菜单仅保留给书籍资料内的明确操作。
struct NoteImportMenuLabel: View {
    let title: String
    var body: some View {
        HStack(spacing: Spacing.compact) {
            Text(title)
            Image(systemName: "chevron.down").imageScale(.small).accessibilityHidden(true)
        }
        .font(AppTypography.footnote).foregroundStyle(Color.textSecondary)
        .frame(minHeight: InteractionMetrics.minimumTouchTarget).contentShape(Rectangle())
    }
}

/// 路由仅持有来源身份。
struct NoteImportPreviewBookRoute: Identifiable, Hashable { let id: UUID }

/// 主列表与已选列表共用布局；独立选择与单本设置各自拥有完整命中区域。
struct NoteImportPreviewBookList: View {
    @Bindable var model: NoteImportPreviewViewModel
    let books: [NoteImportPreviewBook]
    var emptyAction: (() -> Void)?
    @State private var editingBook: NoteImportPreviewBookRoute?
    var body: some View {
        List {
            ForEach(books) { book in
                NoteImportPreviewBookRow(book: book, metadata: model.metadata(for: book),
                    issue: book.issue ?? model.validationMessage(for: book),
                    durationSummary: model.durationChoice(for: book)?.policy?.summary,
                    onEdit: { editingBook = .init(id: book.id) }, onSelect: { model.toggleBook(book.id) })
                    .disabled(model.isLocked || book.isCompleted)
                    .listRowInsets(EdgeInsets(top: Spacing.base, leading: Spacing.screenEdge, bottom: Spacing.base, trailing: Spacing.screenEdge))
                    .listRowBackground(Color.surfaceSheet)
                    .listRowSeparatorTint(Color.surfaceDividerSubtle)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + InteractionMetrics.minimumTouchTarget + Spacing.base + 44 + Spacing.base }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden).background(Color.surfaceSheet)
        .scrollBounceBehavior(.always).scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .overlay {
            if books.isEmpty {
                XMContentStateView(role: .empty, title: emptyAction == nil ? "暂无书籍" : model.query.isEmpty ? "没有符合条件的书籍" : "未找到相关书籍",
                    action: emptyAction.map { XMStateAction(model.query.isEmpty ? "重置筛选" : "清除搜索", perform: $0) })
            }
        }
        .sheet(item: $editingBook) { route in NoteImportBookSettingsSheet(model: model, bookID: route.id) }
    }
}

/// 数量和来源时长紧邻资料，默认新建不制造重复操作标签。
private struct NoteImportPreviewBookRow: View {
    let book: NoteImportPreviewBook
    let metadata: NoteImportBookMetadata
    let issue: String?
    let durationSummary: String?
    let onEdit: () -> Void
    let onSelect: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Button(action: onSelect) {
                XMSelectionIndicator(style: .checkbox, isSelected: book.isSelected || book.isCompleted, font: AppTypography.body, showsUnselectedBase: true)
                    .frame(width: InteractionMetrics.minimumTouchTarget, height: InteractionMetrics.minimumTouchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(book.isSelected ? "取消选择《\(metadata.title)》" : "选择《\(metadata.title)》")
            .accessibilityAddTraits(book.isSelected ? .isSelected : [])
            Button(action: onEdit) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    XMBookCover.fixedWidth(44, urlString: metadata.coverURL, cornerRadius: CornerRadius.inlaySmall,
                        border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline), placeholderIconSize: .medium)
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text(metadata.title.isEmpty ? "未命名书籍" : metadata.title)
                            .font(AppTypography.bodyMedium).foregroundStyle(Color.textPrimary).lineLimit(1).truncationMode(.tail)
                        if !metadata.author.isEmpty { Text(metadata.author).font(AppTypography.subheadline).lineLimit(1) }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Spacing.base) { summary }
                            VStack(alignment: .leading, spacing: Spacing.compact) { summary }
                        }.font(AppTypography.footnote)
                        if book.targetID != nil { Text("存入《\(metadata.title)》").font(AppTypography.footnote).lineLimit(1) }
                        if book.isCompleted { Text("已完成").font(AppTypography.footnote) }
                        else if let issue { Text(issue).font(AppTypography.footnote).foregroundStyle(Color.feedbackWarning) }
                        else if let durationSummary, book.sourceSeconds != nil, book.targetID != nil {
                            Text(durationSummary).font(AppTypography.footnote)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(AppTypography.footnote).accessibilityHidden(true)
                }
                .foregroundStyle(Color.textSecondary)
                .frame(minHeight: InteractionMetrics.minimumTouchTarget).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("打开书籍设置")
        }
    }
    @ViewBuilder private var summary: some View {
        if book.sourceSeconds == nil || !book.source.notes.isEmpty || !book.source.reviews.isEmpty || book.source.hasPreviewReadingPosition { Text(book.contentTitle) }
        if let seconds = book.sourceSeconds { Text("阅读 \(NoteImportDurationMerge.text(seconds))") }
    }
}
