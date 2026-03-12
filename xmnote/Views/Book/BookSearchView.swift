/**
 * [INPUT]: 依赖 RepositoryContainer 注入搜索仓储，依赖 BookSearchViewModel 驱动远端查询状态，依赖 XMBookCover 与豆瓣登录业务弹层承接搜索与回流
 * [OUTPUT]: 对外提供 BookSearchView，承载首页加号进入的完整书籍搜索体验与豆瓣风控登录恢复流
 * [POS]: Book 模块搜索页壳层，负责六书源切换、豆瓣登录回流、最近搜索与结果进入录入页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书籍搜索页入口，负责承接首页新增书籍主链路与豆瓣风控登录恢复。
struct BookSearchView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @FocusState private var isSearchFieldFocused: Bool

    @State private var viewModel: BookSearchViewModel?
    @State private var navigationSeed: BookEditorSeed?
    @State private var isPreparingSeed = false
    @State private var didRequestSearchFocus = false
    @State private var pendingRecoveryAction: PendingRecoveryAction?
    @State private var activeDoubanLoginPrompt: DoubanLoginPromptPresentation?
    @State private var activeDoubanLoginPresentation: DoubanLoginPresentation?
    @State private var inlineFeedback: InlineFeedback?
    @State private var didDetectDoubanLogin = false

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
        .task {
            guard viewModel == nil else { return }
            viewModel = BookSearchViewModel(repository: repositories.bookSearchRepository)
            isSearchFieldFocused = true
        }
        .navigationDestination(item: $navigationSeed) { seed in
            BookEditorView(seed: seed)
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
    }

    private func content(_ viewModel: BookSearchViewModel) -> some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    sourcePills(viewModel)
                    recentQueries(viewModel)
                    resultsSection(viewModel)
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.base)
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
                Button("手动创建") {
                    navigationSeed = .manual
                }
                .font(
                    SemanticTypography.font(
                        baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                        relativeTo: .subheadline,
                        weight: .semibold
                    )
                )
                .foregroundStyle(Color.brand)
            }
        }
        .onAppear {
            guard !didRequestSearchFocus else { return }
            didRequestSearchFocus = true
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
    }

    private func sourcePills(_ viewModel: BookSearchViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.cozy) {
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
                            .font(
                                SemanticTypography.font(
                                    baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                    relativeTo: .subheadline,
                                    weight: .medium
                                )
                            )
                            .foregroundStyle(isSelected ? .white : Color.textPrimary)
                            .padding(.horizontal, Spacing.base)
                            .padding(.vertical, Spacing.cozy)
                            .background(
                                isSelected ? AnyShapeStyle(Color.brand) : AnyShapeStyle(Color.surfaceCard),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func recentQueries(_ viewModel: BookSearchViewModel) -> some View {
        if viewModel.shouldShowRecentQueries {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text("最近搜索")
                    .font(
                        SemanticTypography.font(
                            baseSize: SemanticTypography.defaultPointSize(for: .headline),
                            relativeTo: .headline,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(Color.textPrimary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.cozy) {
                        ForEach(viewModel.recentQueries, id: \.self) { query in
                            Button(query) {
                                clearTransientState()
                                Task {
                                    viewModel.query = query
                                    await performSearch(using: viewModel)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(
                                SemanticTypography.font(
                                    baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                    relativeTo: .subheadline
                                )
                            )
                            .foregroundStyle(Color.textPrimary)
                            .padding(.horizontal, Spacing.base)
                            .padding(.vertical, Spacing.cozy)
                            .background(Color.surfaceCard, in: Capsule())
                            .contextMenu {
                                Button(role: .destructive) {
                                    viewModel.removeRecentQuery(query)
                                } label: {
                                    Label("删除搜索词", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func resultsSection(_ viewModel: BookSearchViewModel) -> some View {
        if viewModel.isSearching {
            loadingStateCard(viewModel)
        } else if !viewModel.results.isEmpty {
            resultsListSection(viewModel)
        } else if let pendingRecoveryAction {
            doubanRecoveryCard(pendingRecoveryAction)
        } else if let errorMessage = viewModel.errorMessage {
            genericErrorCard(errorMessage, viewModel: viewModel)
        } else if viewModel.shouldShowEmptyState {
            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    resultSectionHeader(
                        title: "没有找到匹配结果",
                        detail: viewModel.selectedSource.title
                    )
                    EmptyStateView(icon: "books.vertical", message: "换个关键词或切换搜索源再试试")
                        .frame(minHeight: 180)
                }
                .padding(Spacing.contentEdge)
            }
        } else {
            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                EmptyStateView(icon: "magnifyingglass", message: "输入书名、作者或 ISBN 开始搜索")
                    .frame(minHeight: 180)
                    .padding(Spacing.contentEdge)
            }
        }
    }

    private func loadingStateCard(_ viewModel: BookSearchViewModel) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                resultSectionHeader(
                    title: "正在搜索",
                    detail: viewModel.selectedSource.title
                )

                VStack(spacing: Spacing.none) {
                    ForEach(0..<3, id: \.self) { index in
                        searchResultSkeleton
                        if index < 2 {
                            Divider()
                                .padding(.leading, Spacing.contentEdge + 68 + Spacing.base)
                        }
                    }
                }
            }
            .padding(.vertical, Spacing.cozy)
        }
    }

    private func resultsListSection(_ viewModel: BookSearchViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if let pendingRecoveryAction {
                doubanRecoveryCard(pendingRecoveryAction)
            }

            if let inlineFeedback {
                inlineFeedbackCard(inlineFeedback)
            }

            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                VStack(alignment: .leading, spacing: Spacing.none) {
                    resultSectionHeader(
                        title: viewModel.selectedSource.title,
                        detail: "\(viewModel.results.count) 个结果"
                    )
                    .padding(.horizontal, Spacing.contentEdge)
                    .padding(.top, Spacing.contentEdge)
                    .padding(.bottom, Spacing.base)

                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { index, result in
                        searchResultRow(result, viewModel: viewModel)
                        if index < viewModel.results.count - 1 {
                            Divider()
                                .padding(.leading, Spacing.contentEdge + 68 + Spacing.base)
                        }
                    }
                }
                .padding(.bottom, Spacing.cozy)
            }
        }
    }

    private func genericErrorCard(_ errorMessage: String, viewModel: BookSearchViewModel) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                resultSectionHeader(
                    title: "搜索失败",
                    detail: viewModel.selectedSource.title
                )
                Text(errorMessage)
                    .font(
                        SemanticTypography.font(
                            baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                            relativeTo: .subheadline
                        )
                    )
                    .foregroundStyle(Color.textSecondary)

                Button("重新搜索") {
                    Task {
                        await performSearch(using: viewModel)
                    }
                }
                .font(
                    SemanticTypography.font(
                        baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                        relativeTo: .subheadline,
                        weight: .semibold
                    )
                )
                .foregroundStyle(Color.brand)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func inlineFeedbackCard(_ feedback: InlineFeedback) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(feedback.title)
                    .font(
                        SemanticTypography.font(
                            baseSize: SemanticTypography.defaultPointSize(for: .headline),
                            relativeTo: .headline,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(Color.textPrimary)

                Text(feedback.message)
                    .font(
                        SemanticTypography.font(
                            baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                            relativeTo: .subheadline
                        )
                    )
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func doubanRecoveryCard(_ action: PendingRecoveryAction) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.brand)

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text(action.recoveryTitle)
                            .font(
                                SemanticTypography.font(
                                    baseSize: SemanticTypography.defaultPointSize(for: .headline),
                                    relativeTo: .headline,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(Color.textPrimary)

                        Text(action.recoveryMessage)
                            .font(
                                SemanticTypography.font(
                                    baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                    relativeTo: .subheadline
                                )
                            )
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button(action.recoveryButtonTitle) {
                    Task {
                        await openDoubanLogin(for: action)
                    }
                }
                .font(
                    SemanticTypography.font(
                        baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                        relativeTo: .subheadline,
                        weight: .semibold
                    )
                )
                .foregroundStyle(Color.brand)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func resultSectionHeader(title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(
                    SemanticTypography.font(
                        baseSize: SemanticTypography.defaultPointSize(for: .headline),
                        relativeTo: .headline,
                        weight: .semibold
                    )
                )
                .foregroundStyle(Color.textPrimary)

            Spacer(minLength: Spacing.base)

            Text(detail)
                .font(
                    SemanticTypography.font(
                        baseSize: SemanticTypography.defaultPointSize(for: .footnote),
                        relativeTo: .footnote,
                        weight: .medium
                    )
                )
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func searchResultRow(_ result: BookSearchResult, viewModel: BookSearchViewModel) -> some View {
        Button {
            Task {
                await prepareSeed(for: result, using: viewModel)
            }
        } label: {
            HStack(alignment: .top, spacing: Spacing.base) {
                XMBookCover.fixedWidth(
                    68,
                    urlString: result.coverURL,
                    cornerRadius: CornerRadius.inlayHairline,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: .medium,
                    surfaceStyle: .spine
                )

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text(result.title)
                        .font(
                            SemanticTypography.font(
                                baseSize: SemanticTypography.defaultPointSize(for: .headline),
                                relativeTo: .headline,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if result.isLightweightDoubanSearchCard {
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(
                                    SemanticTypography.font(
                                        baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                        relativeTo: .subheadline
                                    )
                                )
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(2)
                        }
                    } else {
                        ForEach(result.metadataLines) { line in
                            Text("\(line.label)\(line.value)")
                                .font(
                                    SemanticTypography.font(
                                        baseSize: SemanticTypography.defaultPointSize(for: .subheadline),
                                        relativeTo: .subheadline
                                    )
                                )
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.base)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var searchResultSkeleton: some View {
        HStack(spacing: Spacing.base) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.surfaceNested)
                .frame(width: 68, height: 96)

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(height: 16)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(width: 120, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.surfaceNested)
                    .frame(height: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.base)
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
                    clearTransientState()
                }
            }
        )
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
        }
        inlineFeedback = nil

        let failure = await viewModel.search()
        guard let failure else {
            pendingRecoveryAction = nil
            return
        }

        guard case .doubanLoginRequired? = failure.bookSearchError else {
            pendingRecoveryAction = nil
            return
        }

        let action = PendingRecoveryAction.search(
            keyword: viewModel.trimmedQuery,
            source: viewModel.selectedSource,
            recoveryAttempt: recoveryAttempt
        )
        presentDoubanRecovery(for: action, autoPrompt: recoveryAttempt == 0)
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
        inlineFeedback = nil
        didDetectDoubanLogin = false
    }
}

private struct SearchResultMetadataLine: Identifiable {
    let id: String
    let label: String
    let value: String
}

private extension BookSearchResult {
    var isLightweightDoubanSearchCard: Bool {
        source == .douban &&
            seed == nil &&
            author.isEmpty &&
            translator.isEmpty &&
            press.isEmpty &&
            pubDate.isEmpty
    }

    var metadataLines: [SearchResultMetadataLine] {
        [
            SearchResultMetadataLine(id: "author", label: "作者：", value: author),
            SearchResultMetadataLine(id: "translator", label: "译者：", value: translator),
            SearchResultMetadataLine(id: "press", label: "出版社：", value: press),
            SearchResultMetadataLine(id: "pubDate", label: "出版日期：", value: pubDate)
        ]
        .filter { !$0.value.isEmpty }
    }
}

private extension BookSearchView {
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
}

#Preview {
    NavigationStack {
        BookSearchView()
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
