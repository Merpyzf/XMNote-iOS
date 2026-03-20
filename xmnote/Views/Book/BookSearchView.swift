/**
 * [INPUT]: 依赖 RepositoryContainer 注入搜索仓储，依赖 BookSearchViewModel 驱动远端查询状态，依赖 BookSearchResultRow、BookSearchStatusCard 与登录/验证弹层承接搜索与回流
 * [OUTPUT]: 对外提供 BookSearchView，承载首页加号进入的完整书籍搜索体验、豆瓣登录恢复与番茄风控恢复
 * [POS]: Book 模块搜索页壳层，负责六书源切换、最近搜索、豆瓣/番茄风控回流与结果进入录入页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍搜索页入口，负责承接首页新增书籍主链路与豆瓣风控登录恢复。
struct BookSearchView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(SceneStateStore.self) private var sceneStateStore
    @FocusState private var isSearchFieldFocused: Bool

    @State private var viewModel: BookSearchViewModel?
    @State private var navigationSeed: BookEditorSeed?
    @State private var auxiliaryDestination: AuxiliaryDestination?
    @State private var isPreparingSeed = false
    @State private var didRequestSearchFocus = false
    @State private var pendingRecoveryAction: PendingRecoveryAction?
    @State private var activeDoubanLoginPrompt: DoubanLoginPromptPresentation?
    @State private var activeDoubanLoginPresentation: DoubanLoginPresentation?
    @State private var pendingFanqieVerificationAction: FanqieVerificationRecoveryAction?
    @State private var activeFanqieVerificationPrompt: FanqieVerificationPromptPresentation?
    @State private var activeFanqieVerificationPresentation: FanqieVerificationPresentation?
    @State private var inlineFeedback: InlineFeedback?
    @State private var didDetectDoubanLogin = false
    @State private var didCompleteFanqieVerification = false
    @State private var isRecentQueriesExpanded = false
    @State private var didBootstrapFromScene = false

    var body: some View {
        Group {
            if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.surfacePage)
            }
        }
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored else { return }
            guard !didBootstrapFromScene else { return }
            didBootstrapFromScene = true
            guard viewModel == nil else { return }
            let snapshot = sceneStateStore.snapshot.books.search
            viewModel = BookSearchViewModel(
                repository: repositories.bookSearchRepository,
                initialQuery: snapshot?.query ?? "",
                initialSource: snapshot?.selectedSource ?? .wenqu
            )
            isSearchFieldFocused = true
        }
        .navigationDestination(item: $navigationSeed) { seed in
            BookEditorView(seed: seed)
        }
        .navigationDestination(item: $auxiliaryDestination) { destination in
            auxiliaryDestinationView(destination)
        }
        .alert(
            activeDoubanLoginPrompt?.action.promptTitle ?? "",
            isPresented: Binding(
                get: { activeDoubanLoginPrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        activeDoubanLoginPrompt = nil
                    }
                }
            ),
            presenting: activeDoubanLoginPrompt
        ) { prompt in
            Button("取消", role: .cancel) {
                activeDoubanLoginPrompt = nil
            }

            Button("去登录") {
                activeDoubanLoginPrompt = nil
                Task {
                    await openDoubanLogin(for: prompt.action)
                }
            }
        } message: { prompt in
            Text(prompt.action.promptMessage)
        }
        .alert(
            activeFanqieVerificationPrompt?.action.promptTitle ?? "",
            isPresented: Binding(
                get: { activeFanqieVerificationPrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        activeFanqieVerificationPrompt = nil
                    }
                }
            ),
            presenting: activeFanqieVerificationPrompt
        ) { prompt in
            Button("取消", role: .cancel) {
                activeFanqieVerificationPrompt = nil
            }

            Button("去验证") {
                activeFanqieVerificationPrompt = nil
                Task {
                    await openFanqieVerification(for: prompt.action)
                }
            }
        } message: { prompt in
            Text(prompt.action.promptMessage)
        }
        .fullScreenCover(
            item: $activeDoubanLoginPresentation,
            onDismiss: {
                Task {
                    await handleDoubanLoginDismissed()
                }
            }
        ) { presentation in
            BookDoubanLoginScreen(
                title: presentation.title,
                onClose: {
                    activeDoubanLoginPresentation = nil
                },
                onLoginDetected: {
                    didDetectDoubanLogin = true
                    activeDoubanLoginPresentation = nil
                }
            )
        }
        .fullScreenCover(
            item: $activeFanqieVerificationPresentation,
            onDismiss: {
                Task {
                    await handleFanqieVerificationDismissed()
                }
            }
        ) { presentation in
            BookFanqieVerificationScreen(
                title: presentation.title,
                searchURL: presentation.searchURL,
                onClose: {
                    activeFanqieVerificationPresentation = nil
                },
                onVerificationCompleted: {
                    didCompleteFanqieVerification = true
                    activeFanqieVerificationPresentation = nil
                }
            )
        }
        .onAppear {
            syncSceneSnapshot()
        }
    }

    private func content(_ viewModel: BookSearchViewModel) -> some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: mainSectionSpacing(for: viewModel)) {
                    controlsSection(viewModel)

                    if resultsDisplayState(viewModel) != .idle {
                        resultsSection(viewModel)
                            .padding(.horizontal, Spacing.screenEdge)
                    }
                }
                .padding(.top, SearchPageLayout.topContentPadding)
                .padding(.bottom, Spacing.double)
            }
            .scrollIndicators(.hidden)

            if isPreparingSeed {
                Color.overlay.ignoresSafeArea()
                ProgressView("正在补全书籍信息…")
                    .padding(Spacing.contentEdge)
                    .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            }
        }
        .navigationTitle("添加书籍")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: queryBinding(for: viewModel),
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "书名、作者、ISBN"
        )
        .searchFocused($isSearchFieldFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(of: .search) {
            Task {
                await performSearch(using: viewModel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                auxiliaryMenu
            }
        }
        .onAppear {
            guard !didRequestSearchFocus else { return }
            didRequestSearchFocus = true
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
        .onChange(of: viewModel.query) { _, _ in
            syncSceneSnapshot()
        }
        .onChange(of: viewModel.selectedSource) { _, _ in
            syncSceneSnapshot()
        }
    }

    private func syncSceneSnapshot() {
        guard let viewModel else { return }
        sceneStateStore.updateBookSearch(
            BookSearchSceneSnapshot(
                query: viewModel.query,
                selectedSource: viewModel.selectedSource
            )
        )
    }

    private func controlsSection(_ viewModel: BookSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: SearchPageLayout.controlsVerticalSpacing) {
            sourcePills(viewModel)
            recentQueries(viewModel)
        }
        .padding(.horizontal, Spacing.screenEdge)
    }

    private func sourcePills(_ viewModel: BookSearchViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SearchPageLayout.sourceChipSpacing) {
                ForEach(BookSearchSource.allCases) { source in
                    let isSelected = source == viewModel.selectedSource
                    Button {
                        withAnimation(.snappy) {
                            viewModel.selectedSource = source
                        }
                        clearTransientState()

                        guard !viewModel.trimmedQuery.isEmpty, !viewModel.isSearching else { return }
                        Task {
                            await performSearch(using: viewModel)
                        }
                    } label: {
                        Text(source.title)
                            .font(AppTypography.semantic(.footnote, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? .white : Color.textSecondary)
                            .padding(.horizontal, SearchPageLayout.sourceChipHorizontalPadding)
                            .frame(height: SearchPageLayout.sourceChipVisualHeight)
                            .background(
                                isSelected ? AnyShapeStyle(Color.brand) : AnyShapeStyle(Color.controlFillSecondary),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke(
                                        isSelected ? Color.clear : Color.surfaceBorderSubtle,
                                        lineWidth: CardStyle.borderWidth
                                    )
                            }
                            .frame(minHeight: SearchPageLayout.chipTapHeight)
                    }
                    .buttonStyle(SearchChipButtonStyle())
                }
            }
            .padding(.vertical, SearchPageLayout.sourceChipVerticalPadding)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func recentQueries(_ viewModel: BookSearchViewModel) -> some View {
        if viewModel.shouldShowRecentQueries {
            BookSearchRecentQueriesSection(
                queries: viewModel.recentQueries,
                isExpanded: $isRecentQueriesExpanded,
                onTap: { query in
                    clearTransientState()
                    Task {
                        viewModel.query = query
                        await performSearch(using: viewModel)
                    }
                },
                onRemove: { query in
                    viewModel.removeRecentQuery(query)
                }
            )
        }
    }

    @ViewBuilder
    private func resultsSection(_ viewModel: BookSearchViewModel) -> some View {
        if resultsDisplayState(viewModel) != .idle {
            ZStack {
                switch resultsDisplayState(viewModel) {
                case .loading:
                    loadingStateCard(viewModel)
                        .transition(.opacity)
                case .results:
                    resultsListSection(viewModel)
                        .transition(.opacity)
                case .recoveryOnly:
                    if let pendingRecoveryAction {
                        doubanRecoveryCard(pendingRecoveryAction)
                            .transition(.opacity)
                    } else if let pendingFanqieVerificationAction {
                        fanqieRecoveryCard(pendingFanqieVerificationAction)
                            .transition(.opacity)
                    }
                case .error:
                    if let errorMessage = viewModel.errorMessage {
                        genericErrorCard(errorMessage, viewModel: viewModel)
                            .transition(.opacity)
                    }
                case .empty:
                    emptyResultsCard(viewModel)
                        .transition(.opacity)
                case .idle:
                    EmptyView()
                }
            }
            .animation(.smooth(duration: 0.22), value: resultsDisplayState(viewModel))
        }
    }

    private func loadingStateCard(_ viewModel: BookSearchViewModel) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            VStack(alignment: .leading, spacing: Spacing.none) {
                HStack(spacing: Spacing.cozy) {
                    ProgressView()
                        .controlSize(.small)

                    Text("正在从 \(viewModel.selectedSource.title) 搜索")
                        .font(AppTypography.semantic(.footnote, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.top, Spacing.contentEdge)
                .padding(.bottom, Spacing.half)

                VStack(spacing: Spacing.none) {
                    ForEach(0..<3, id: \.self) { index in
                        BookSearchResultSkeletonRow(source: viewModel.selectedSource)
                        if index < 2 {
                            Divider()
                                .padding(.leading, rowDividerLeadingInset)
                        }
                    }
                }
                .padding(.bottom, Spacing.cozy)
            }
        }
    }

    private func resultsListSection(_ viewModel: BookSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if let pendingRecoveryAction {
                doubanRecoveryCard(pendingRecoveryAction)
            } else if let pendingFanqieVerificationAction {
                fanqieRecoveryCard(pendingFanqieVerificationAction)
            }

            if let inlineFeedback {
                inlineFeedbackCard(inlineFeedback)
            }

            CardContainer(cornerRadius: CornerRadius.containerMedium) {
                VStack(alignment: .leading, spacing: Spacing.none) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        BookSearchResultRow(
                            result: result,
                            keyword: viewModel.trimmedQuery
                        ) {
                            Task {
                                await prepareSeed(for: result, using: viewModel)
                            }
                        }
                        if index < viewModel.results.count - 1 {
                            Divider()
                                .padding(.leading, rowDividerLeadingInset)
                        }
                    }
                }
                .padding(.vertical, Spacing.cozy)
            }
        }
    }

    private func genericErrorCard(_ errorMessage: String, viewModel: BookSearchViewModel) -> some View {
        BookSearchStatusCard(
            systemImage: "wifi.exclamationmark",
            tint: .feedbackError,
            title: "搜索失败",
            message: "\(viewModel.selectedSource.title) 暂时无法完成搜索。\(errorMessage)",
            actionTitle: "重新搜索"
        ) {
            Task {
                await performSearch(using: viewModel)
            }
        }
    }

    private func inlineFeedbackCard(_ feedback: InlineFeedback) -> some View {
        BookSearchStatusCard(
            systemImage: "exclamationmark.circle",
            tint: .feedbackWarning,
            title: feedback.title,
            message: feedback.message
        )
    }

    private func doubanRecoveryCard(_ action: PendingRecoveryAction) -> some View {
        BookSearchStatusCard(
            systemImage: "person.crop.circle.badge.exclamationmark",
            tint: .brand,
            title: action.recoveryTitle,
            message: action.recoveryMessage,
            actionTitle: action.recoveryButtonTitle
        ) {
            Task {
                await openDoubanLogin(for: action)
            }
        }
    }

    private func fanqieRecoveryCard(_ action: FanqieVerificationRecoveryAction) -> some View {
        BookSearchStatusCard(
            systemImage: "checkmark.shield",
            tint: .brand,
            title: action.recoveryTitle,
            message: action.recoveryMessage,
            actionTitle: action.recoveryButtonTitle
        ) {
            Task {
                await openFanqieVerification(for: action)
            }
        }
    }

    private func emptyResultsCard(_ viewModel: BookSearchViewModel) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            VStack(spacing: Spacing.base) {
                ContentUnavailableView.search(text: viewModel.trimmedQuery)

                Text("当前搜索源：\(viewModel.selectedSource.title)")
                    .font(AppTypography.semantic(.footnote, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(Spacing.contentEdge)
        }
    }

    private func queryBinding(for viewModel: BookSearchViewModel) -> Binding<String> {
        Binding(
            get: { viewModel.query },
            set: { query in
                viewModel.query = query
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    viewModel.results = []
                    viewModel.errorMessage = nil
                    viewModel.latestSearchError = nil
                    viewModel.hasSearched = false
                    isRecentQueriesExpanded = false
                    clearTransientState()
                }
            }
        )
    }

    private var auxiliaryMenu: some View {
        Menu {
            Button {
                auxiliaryDestination = .scan
            } label: {
                Label("扫码录入", systemImage: "barcode.viewfinder")
                    .foregroundStyle(.primary)
            }

            Button {
                navigationSeed = .manual
            } label: {
                Label("手动添加", systemImage: "square.and.pencil")
                    .foregroundStyle(.primary)
            }

            Button {
                auxiliaryDestination = .settings
            } label: {
                Label("设置", systemImage: "slider.horizontal.3")
                    .foregroundStyle(.primary)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .tint(nil)
        .accessibilityLabel("更多操作")
    }

    @ViewBuilder
    private func auxiliaryDestinationView(_ destination: AuxiliaryDestination) -> some View {
        switch destination {
        case .scan:
            BookScanPlaceholderView()
        case .settings:
            BookSearchSettingsPlaceholderView()
        }
    }

    @MainActor
    private func performSearch(
        using viewModel: BookSearchViewModel,
        keyword: String? = nil,
        source: BookSearchSource? = nil,
        recoveryAttempt: Int = 0
    ) async {
        if let keyword {
            viewModel.query = keyword
        }
        if let source {
            viewModel.selectedSource = source
        }

        if recoveryAttempt == 0 {
            pendingRecoveryAction = nil
            pendingFanqieVerificationAction = nil
        }
        inlineFeedback = nil

        let failure = await viewModel.search()
        guard let failure else {
            pendingRecoveryAction = nil
            pendingFanqieVerificationAction = nil
            return
        }

        switch failure.bookSearchError {
        case .doubanLoginRequired?:
            pendingFanqieVerificationAction = nil
            let action = PendingRecoveryAction.search(
                keyword: viewModel.trimmedQuery,
                source: viewModel.selectedSource,
                recoveryAttempt: recoveryAttempt
            )
            presentDoubanRecovery(for: action, autoPrompt: recoveryAttempt == 0)
        case .fanqieVerificationRequired?:
            pendingRecoveryAction = nil
            let action = FanqieVerificationRecoveryAction.search(
                keyword: viewModel.trimmedQuery,
                recoveryAttempt: recoveryAttempt
            )
            presentFanqieVerificationRecovery(for: action, autoPrompt: recoveryAttempt == 0)
        default:
            pendingRecoveryAction = nil
            pendingFanqieVerificationAction = nil
        }
    }

    @MainActor
    private func prepareSeed(
        for result: BookSearchResult,
        using viewModel: BookSearchViewModel,
        recoveryAttempt: Int = 0
    ) async {
        inlineFeedback = nil
        if recoveryAttempt == 0 {
            pendingRecoveryAction = nil
        }

        isPreparingSeed = true
        defer { isPreparingSeed = false }

        do {
            navigationSeed = try await viewModel.prepareSeed(for: result)
            pendingRecoveryAction = nil
        } catch let searchError as BookSearchError {
            guard case .doubanLoginRequired = searchError else {
                pendingRecoveryAction = nil
                inlineFeedback = InlineFeedback(
                    title: "暂时无法打开这本书",
                    message: searchError.errorDescription ?? "请稍后再试。"
                )
                return
            }

            let action = PendingRecoveryAction.prepareSeed(
                result: result,
                recoveryAttempt: recoveryAttempt
            )
            presentDoubanRecovery(for: action, autoPrompt: recoveryAttempt == 0)
        } catch {
            pendingRecoveryAction = nil
            inlineFeedback = InlineFeedback(
                title: "暂时无法打开这本书",
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    @MainActor
    private func presentDoubanRecovery(for action: PendingRecoveryAction, autoPrompt: Bool) {
        pendingRecoveryAction = action
        pendingFanqieVerificationAction = nil
        inlineFeedback = nil

        guard autoPrompt else { return }
        activeDoubanLoginPrompt = DoubanLoginPromptPresentation(action: action)
    }

    @MainActor
    private func openDoubanLogin(for action: PendingRecoveryAction) async {
        pendingRecoveryAction = action
        activeDoubanLoginPrompt = nil

        if await DoubanWebLoginService.shared.isLoggedIn() {
            await resumePendingRecoveryAction()
            return
        }

        activeDoubanLoginPresentation = DoubanLoginPresentation(title: action.loginSheetTitle)
    }

    @MainActor
    private func handleDoubanLoginDismissed() async {
        let currentLoginState = await DoubanWebLoginService.shared.isLoggedIn()
        let isLoggedIn = didDetectDoubanLogin || currentLoginState
        didDetectDoubanLogin = false
        guard isLoggedIn else { return }
        await resumePendingRecoveryAction()
    }

    @MainActor
    private func presentFanqieVerificationRecovery(for action: FanqieVerificationRecoveryAction, autoPrompt: Bool) {
        pendingFanqieVerificationAction = action
        pendingRecoveryAction = nil
        inlineFeedback = nil

        guard autoPrompt else { return }
        activeFanqieVerificationPrompt = FanqieVerificationPromptPresentation(action: action)
    }

    @MainActor
    private func openFanqieVerification(for action: FanqieVerificationRecoveryAction) async {
        pendingFanqieVerificationAction = action
        activeFanqieVerificationPrompt = nil

        guard let searchURL = FanqieWebVerificationService.shared.makeSearchURL(keyword: action.keyword) else {
            pendingFanqieVerificationAction = nil
            inlineFeedback = InlineFeedback(
                title: "暂时无法打开验证页",
                message: "番茄搜索地址无效，请稍后再试。"
            )
            return
        }

        activeFanqieVerificationPresentation = FanqieVerificationPresentation(
            title: action.verificationSheetTitle,
            searchURL: searchURL
        )
    }

    @MainActor
    private func handleFanqieVerificationDismissed() async {
        guard let action = pendingFanqieVerificationAction else {
            didCompleteFanqieVerification = false
            return
        }

        let completed = didCompleteFanqieVerification
        didCompleteFanqieVerification = false
        guard completed, let viewModel else { return }

        await performSearch(
            using: viewModel,
            keyword: action.keyword,
            source: .fanqie,
            recoveryAttempt: action.recoveryAttempt + 1
        )
    }

    @MainActor
    private func resumePendingRecoveryAction() async {
        guard let action = pendingRecoveryAction, let viewModel else { return }

        switch action {
        case .search(let keyword, let source, let recoveryAttempt):
            await performSearch(
                using: viewModel,
                keyword: keyword,
                source: source,
                recoveryAttempt: recoveryAttempt + 1
            )
        case .prepareSeed(let result, let recoveryAttempt):
            await prepareSeed(
                for: result,
                using: viewModel,
                recoveryAttempt: recoveryAttempt + 1
            )
        }
    }

    private func clearTransientState() {
        pendingRecoveryAction = nil
        activeDoubanLoginPrompt = nil
        pendingFanqieVerificationAction = nil
        activeFanqieVerificationPrompt = nil
        activeFanqieVerificationPresentation = nil
        inlineFeedback = nil
        didDetectDoubanLogin = false
        didCompleteFanqieVerification = false
    }

    private var rowDividerLeadingInset: CGFloat {
        Spacing.contentEdge + BookSearchResultRow.coverWidth + Spacing.base
    }

    private func mainSectionSpacing(for viewModel: BookSearchViewModel) -> CGFloat {
        viewModel.shouldShowRecentQueries ? SearchPageLayout.controlsToResultsSpacing : Spacing.base
    }

    private func resultsDisplayState(_ viewModel: BookSearchViewModel) -> ResultsDisplayState {
        if viewModel.isSearching {
            return .loading
        }
        if !viewModel.results.isEmpty {
            return .results
        }
        if pendingRecoveryAction != nil || pendingFanqieVerificationAction != nil {
            return .recoveryOnly
        }
        if viewModel.errorMessage != nil {
            return .error
        }
        if viewModel.shouldShowEmptyState {
            return .empty
        }
        return .idle
    }
}

private extension BookSearchView {
    enum AuxiliaryDestination: String, Identifiable {
        case scan
        case settings

        var id: String { rawValue }
    }

    enum ResultsDisplayState: Equatable {
        case loading
        case results
        case recoveryOnly
        case error
        case empty
        case idle
    }

    struct InlineFeedback {
        let title: String
        let message: String
    }

    struct DoubanLoginPromptPresentation: Identifiable {
        let id = UUID()
        let action: PendingRecoveryAction
    }

    struct DoubanLoginPresentation: Identifiable {
        let id = UUID()
        let title: String
    }

    struct FanqieVerificationPromptPresentation: Identifiable {
        let id = UUID()
        let action: FanqieVerificationRecoveryAction
    }

    struct FanqieVerificationPresentation: Identifiable {
        let id = UUID()
        let title: String
        let searchURL: URL
    }

    enum PendingRecoveryAction: Identifiable {
        case search(keyword: String, source: BookSearchSource, recoveryAttempt: Int)
        case prepareSeed(result: BookSearchResult, recoveryAttempt: Int)

        var id: String {
            switch self {
            case .search(let keyword, let source, let recoveryAttempt):
                return "search-\(source.rawValue)-\(keyword)-\(recoveryAttempt)"
            case .prepareSeed(let result, let recoveryAttempt):
                return "seed-\(result.id)-\(recoveryAttempt)"
            }
        }

        var promptTitle: String {
            switch self {
            case .search:
                return "豆瓣需要登录后继续搜索"
            case .prepareSeed:
                return "豆瓣需要登录后补全书籍信息"
            }
        }

        var promptMessage: String {
            switch self {
            case .search(let keyword, _, _):
                return "豆瓣当前触发了访问风控。登录后会自动继续搜索“\(keyword)”。"
            case .prepareSeed(let result, _):
                return "豆瓣当前触发了访问风控。登录后会自动继续补全《\(result.title)》的详细信息。"
            }
        }

        var recoveryTitle: String {
            switch self {
            case .search:
                return "登录豆瓣后继续搜索"
            case .prepareSeed:
                return "登录豆瓣后继续补全信息"
            }
        }

        var recoveryMessage: String {
            switch self {
            case .search(let keyword, _, let recoveryAttempt):
                if recoveryAttempt == 0 {
                    return "豆瓣搜索触发了登录风控。完成登录后会继续搜索“\(keyword)”。"
                }
                return "豆瓣仍要求登录验证。你可以重新打开登录页，再继续搜索“\(keyword)”。"
            case .prepareSeed(let result, let recoveryAttempt):
                if recoveryAttempt == 0 {
                    return "补全《\(result.title)》时触发了豆瓣登录风控。完成登录后会自动继续。"
                }
                return "补全《\(result.title)》时仍然需要豆瓣登录验证。你可以重新打开登录页后再继续。"
            }
        }

        var recoveryButtonTitle: String {
            switch self {
            case .search:
                return "登录豆瓣"
            case .prepareSeed:
                return "登录后继续补全"
            }
        }

        var loginSheetTitle: String {
            switch self {
            case .search(let keyword, _, _):
                return "登录完成后将自动继续搜索“\(keyword)”"
            case .prepareSeed(let result, _):
                return "登录完成后将自动补全《\(result.title)》"
            }
        }
    }

    enum FanqieVerificationRecoveryAction: Identifiable {
        case search(keyword: String, recoveryAttempt: Int)

        var id: String {
            switch self {
            case .search(let keyword, let recoveryAttempt):
                return "fanqie-search-\(keyword)-\(recoveryAttempt)"
            }
        }

        var keyword: String {
            switch self {
            case .search(let keyword, _):
                return keyword
            }
        }

        var recoveryAttempt: Int {
            switch self {
            case .search(_, let recoveryAttempt):
                return recoveryAttempt
            }
        }

        var promptTitle: String {
            "番茄需要完成验证后继续搜索"
        }

        var promptMessage: String {
            "番茄搜索触发了站点验证。完成验证后会自动继续搜索“\(keyword)”。"
        }

        var recoveryTitle: String {
            "完成验证后继续搜索"
        }

        var recoveryMessage: String {
            if recoveryAttempt == 0 {
                return "番茄搜索触发了站点验证。完成验证后会自动继续搜索“\(keyword)”。"
            }
            return "番茄仍然要求完成站点验证。你可以重新打开验证页，再继续搜索“\(keyword)”。"
        }

        var recoveryButtonTitle: String {
            "打开验证页"
        }

        var verificationSheetTitle: String {
            "验证完成后将自动继续搜索“\(keyword)”"
        }
    }
}

/// 搜索页局部布局常量，统一筛选胶囊的尺寸节奏。
private enum SearchPageLayout {
    static let topContentPadding: CGFloat = Spacing.compact
    static let controlsVerticalSpacing: CGFloat = Spacing.base
    static let controlsToResultsSpacing: CGFloat = 18
    static let chipTapHeight: CGFloat = 44
    static let chipVisualHeight: CGFloat = 32
    static let sourceChipVisualHeight: CGFloat = 34
    static let sourceChipHorizontalPadding: CGFloat = 14
    static let sourceChipSpacing: CGFloat = Spacing.cozy
    static let sourceChipVerticalPadding: CGFloat = Spacing.half
}

#Preview {
    NavigationStack {
        BookSearchView()
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
