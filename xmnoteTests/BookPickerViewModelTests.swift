import Foundation
import Testing
@testable import xmnote

@MainActor
struct BookPickerViewModelTests {
    @Test
    func localLoadUsesBookRepositoryAndAppliesDefaultQuery() async {
        let localBooks = [
            BookPickerBook(id: 1, title: "三体", author: "刘慈欣", totalPagination: 302),
            BookPickerBook(id: 2, title: "球状闪电", author: "刘慈欣", totalPagination: 280)
        ]
        let bookRepository = BookPickerTestBookRepository(localBooks: localBooks)
        let viewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(
                scope: .local,
                selectionMode: .single,
                defaultQuery: "三体"
            ),
            bookRepository: bookRepository,
            searchRepository: BookPickerTestSearchRepository()
        )

        await viewModel.loadIfNeeded()

        #expect(bookRepository.fetchQueries == ["三体"])
        #expect(viewModel.localBooks.map(\.id) == [1])
    }

    @Test
    func updatingQueryInLocalScopeRefreshesLocalBooks() async {
        let localBooks = [
            BookPickerBook(id: 1, title: "三体", author: "刘慈欣", totalPagination: 302),
            BookPickerBook(id: 2, title: "球状闪电", author: "刘慈欣", totalPagination: 280)
        ]
        let bookRepository = BookPickerTestBookRepository(localBooks: localBooks)
        let viewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(scope: .local, selectionMode: .single),
            bookRepository: bookRepository,
            searchRepository: BookPickerTestSearchRepository()
        )

        await viewModel.loadIfNeeded()
        viewModel.updateQuery("球状")
        await settleAsyncState()

        #expect(viewModel.query == "球状")
        #expect(viewModel.localBooks.map(\.id) == [2])
    }

    @Test
    func switchingOnlineSourceRerunsSearchAndKeepsQuery() async {
        let searchRepository = BookPickerTestSearchRepository()
        searchRepository.resultsBySource[.wenqu] = [sampleRemoteResult(id: "w-1", source: .wenqu, title: "三体")]
        searchRepository.resultsBySource[.douban] = [sampleRemoteResult(id: "d-1", source: .douban, title: "三体（豆瓣）")]

        let viewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(
                scope: .online,
                selectionMode: .single,
                defaultQuery: "三体",
                onlineSources: [.wenqu, .douban],
                preferredOnlineSource: .wenqu
            ),
            bookRepository: BookPickerTestBookRepository(localBooks: []),
            searchRepository: searchRepository
        )

        await viewModel.loadIfNeeded()
        viewModel.selectOnlineSource(.douban)
        await settleAsyncState()

        #expect(viewModel.query == "三体")
        #expect(
            searchRepository.searchRequests.map { "\($0.0.rawValue)-\($0.1)" }
                == ["0-三体", "6-三体"]
        )
        #expect(viewModel.remoteResults.map(\.source) == [.douban])
    }

    @Test
    func switchingVisibleScopeKeepsQuery() async {
        let viewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(scope: .both, selectionMode: .single, defaultQuery: "三体"),
            bookRepository: BookPickerTestBookRepository(localBooks: []),
            searchRepository: BookPickerTestSearchRepository()
        )

        viewModel.switchVisibleScope(.online)

        #expect(viewModel.query == "三体")
        #expect(viewModel.visibleScope == .online)
    }

    @Test
    func createdBookCompletesSingleModeOrAddsIntoMultipleSelection() async {
        let createdBook = BookPickerBook(id: 99, title: "新书", author: "作者", totalPagination: 100)

        let singleRepository = BookPickerTestBookRepository(localBooks: [createdBook], resolvedBooks: [99: createdBook])
        let singleViewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(scope: .local, selectionMode: .single),
            bookRepository: singleRepository,
            searchRepository: BookPickerTestSearchRepository()
        )
        let singleResult = await singleViewModel.handleCreatedBook(bookId: 99)

        #expect(singleResult == .single(.local(createdBook)))

        let multipleRepository = BookPickerTestBookRepository(localBooks: [createdBook], resolvedBooks: [99: createdBook])
        let multipleViewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(scope: .local, selectionMode: .multiple),
            bookRepository: multipleRepository,
            searchRepository: BookPickerTestSearchRepository()
        )
        let multipleResult = await multipleViewModel.handleCreatedBook(bookId: 99)

        #expect(multipleResult == nil)
        #expect(multipleViewModel.selectedBooks == [createdBook])
    }

    @Test
    func remoteSingleDirectSelectionHydratesSeedAndReturnsRemoteResult() async {
        let searchRepository = BookPickerTestSearchRepository()
        let remoteResult = sampleRemoteResult(id: "remote-1", source: .douban, title: "三体")
        let preparedSeed = sampleSeed(title: "三体", author: "刘慈欣")
        searchRepository.preparedSeedsByResultID[remoteResult.id] = preparedSeed

        let viewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(
                scope: .online,
                selectionMode: .single,
                onlineSelectionPolicy: .returnRemoteSelection,
                defaultQuery: "三体"
            ),
            bookRepository: BookPickerTestBookRepository(localBooks: []),
            searchRepository: searchRepository
        )

        let outcome = await viewModel.handleRemoteResultTap(remoteResult)

        #expect(
            outcome == .complete(
                .single(
                    .remote(
                        BookPickerRemoteSelection(result: remoteResult, seed: preparedSeed)
                    )
                )
            )
        )
        #expect(searchRepository.prepareSeedRequests == [remoteResult.id])
    }

    @Test
    func mixedMultipleSelectionReturnsStableOrderedSelections() async {
        let localPreselected = BookPickerBook(id: 1, title: "三体", author: "刘慈欣")
        let localSecond = BookPickerBook(id: 2, title: "活着", author: "余华")
        let remoteFirst = sampleRemoteResult(id: "remote-a", source: .douban, title: "明朝那些事儿")
        let remoteSecond = sampleRemoteResult(id: "remote-b", source: .wenqu, title: "人类群星闪耀时")

        let searchRepository = BookPickerTestSearchRepository()
        searchRepository.preparedSeedsByResultID[remoteFirst.id] = sampleSeed(title: "明朝那些事儿", author: "当年明月")
        searchRepository.preparedSeedsByResultID[remoteSecond.id] = sampleSeed(title: "人类群星闪耀时", author: "茨威格")

        let viewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(
                scope: .both,
                selectionMode: .multiple,
                onlineSelectionPolicy: .returnRemoteSelection,
                preselectedBooks: [localPreselected]
            ),
            bookRepository: BookPickerTestBookRepository(localBooks: [localPreselected, localSecond]),
            searchRepository: searchRepository
        )

        _ = await viewModel.handleRemoteResultTap(remoteFirst)
        _ = viewModel.handleLocalBookTap(localSecond)
        _ = await viewModel.handleRemoteResultTap(remoteSecond)

        let result = await viewModel.confirmMultipleSelection()

        #expect(
            result == .multiple([
                .local(localPreselected),
                .remote(BookPickerRemoteSelection(result: remoteFirst, seed: sampleSeed(title: "明朝那些事儿", author: "当年明月"))),
                .local(localSecond),
                .remote(BookPickerRemoteSelection(result: remoteSecond, seed: sampleSeed(title: "人类群星闪耀时", author: "茨威格")))
            ])
        )
        #expect(searchRepository.prepareSeedRequests == [remoteFirst.id, remoteSecond.id])
    }

    @Test
    func allowsEmptyResultConfirmsEmptyMultipleSelection() async {
        let viewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(
                scope: .local,
                selectionMode: .multiple,
                multipleConfirmationPolicy: .allowsEmptyResult
            ),
            bookRepository: BookPickerTestBookRepository(localBooks: []),
            searchRepository: BookPickerTestSearchRepository()
        )

        let result = await viewModel.confirmMultipleSelection()

        #expect(result == .multiple([]))
    }

    @Test
    func requireLocalCreationKeepsCreationFlow() async {
        let remoteResult = sampleRemoteResult(id: "remote-2", source: .douban, title: "三体")
        let preparedSeed = sampleSeed(title: "三体", author: "刘慈欣")
        let searchRepository = BookPickerTestSearchRepository()
        searchRepository.preparedSeedsByResultID[remoteResult.id] = preparedSeed

        let viewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(
                scope: .online,
                selectionMode: .single,
                onlineSelectionPolicy: .requireLocalCreation
            ),
            bookRepository: BookPickerTestBookRepository(localBooks: []),
            searchRepository: searchRepository
        )

        let outcome = await viewModel.handleRemoteResultTap(remoteResult)

        #expect(outcome == .presentEditor(preparedSeed))
        #expect(searchRepository.prepareSeedRequests == [remoteResult.id])
    }

    @Test
    func remoteResolutionFailureKeepsSelectionContextAndDoesNotReturnPartialResult() async {
        let localBook = BookPickerBook(id: 7, title: "三体", author: "刘慈欣")
        let remoteResult = sampleRemoteResult(id: "remote-fail", source: .douban, title: "球状闪电")
        let searchRepository = BookPickerTestSearchRepository()
        searchRepository.prepareSeedErrors[remoteResult.id] = BookPickerTestError.seedFailure

        let viewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(
                scope: .both,
                selectionMode: .multiple,
                onlineSelectionPolicy: .returnRemoteSelection
            ),
            bookRepository: BookPickerTestBookRepository(localBooks: [localBook]),
            searchRepository: searchRepository
        )

        _ = viewModel.handleLocalBookTap(localBook)
        _ = await viewModel.handleRemoteResultTap(remoteResult)

        let result = await viewModel.confirmMultipleSelection()

        #expect(result == nil)
        #expect(viewModel.selectedBooks == [localBook])
        #expect(viewModel.isRemoteResultSelected(remoteResult))
        #expect(viewModel.selectedCount == 2)
        #expect(viewModel.onlineErrorMessage == BookPickerTestError.seedFailure.errorDescription)
    }

    private func settleAsyncState() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        await Task.yield()
    }

    private func sampleRemoteResult(
        id: String,
        source: BookSearchSource,
        title: String
    ) -> BookSearchResult {
        BookSearchResult(
            id: id,
            source: source,
            title: title,
            author: "作者",
            coverURL: "",
            subtitle: "",
            summary: "",
            translator: "",
            press: "",
            isbn: "",
            pubDate: "",
            doubanId: nil,
            totalPages: nil,
            totalWordCount: nil,
            seed: nil,
            detailPageURL: "https://example.com/\(id)"
        )
    }

    private func sampleSeed(title: String, author: String) -> BookEditorSeed {
        BookEditorSeed(
            searchSource: .douban,
            title: title,
            rawTitle: title,
            author: author,
            authorIntro: "",
            translator: "",
            press: "",
            isbn: "",
            pubDate: "",
            summary: "",
            catalog: "",
            coverURL: "",
            doubanId: nil,
            totalPages: nil,
            totalWordCount: nil,
            preferredSourceName: nil,
            preferredBookType: nil,
            preferredProgressUnit: nil
        )
    }
}

private enum BookPickerTestError: LocalizedError {
    case seedFailure

    var errorDescription: String? {
        switch self {
        case .seedFailure:
            return "种子补齐失败"
        }
    }
}

private final class BookPickerTestBookRepository: BookRepositoryProtocol {
    let localBooks: [BookPickerBook]
    let resolvedBooks: [Int64: BookPickerBook]
    var fetchQueries: [String] = []

    init(localBooks: [BookPickerBook], resolvedBooks: [Int64: BookPickerBook] = [:]) {
        self.localBooks = localBooks
        self.resolvedBooks = resolvedBooks
    }

    func observeBooks() -> AsyncThrowingStream<[BookItem], Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func observeBookshelf(
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<[BookshelfItem], Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func observeBookshelfSnapshot(
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<BookshelfSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func observeBookshelfAggregateSnapshot(
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<BookshelfAggregateSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func observeBookshelfBookList(
        context: BookshelfListContext,
        setting: BookshelfDisplaySetting,
        searchKeyword: String?
    ) -> AsyncThrowingStream<BookshelfBookListSnapshot, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func updateBookshelfOrder(_ orderedItems: [BookshelfOrderItem]) async throws {}

    func updateBookshelfAggregateOrder(context: BookshelfAggregateOrderContext, orderedIDs: [Int64]) async throws {}

    func pinBookshelfItems(_ ids: [BookshelfItemID]) async throws {}

    func unpinBookshelfItem(_ id: BookshelfItemID) async throws {}

    func moveBookshelfItemsToStart(
        _ ids: [BookshelfItemID],
        in currentItems: [BookshelfOrderItem]
    ) async throws {}

    func moveBookshelfItemsToEnd(
        _ ids: [BookshelfItemID],
        in currentItems: [BookshelfOrderItem]
    ) async throws {}

    func deleteBookshelfItems(
        _ ids: [BookshelfItemID],
        groupBooksPlacement: GroupBooksPlacement
    ) async throws {}

    func moveBooks(_ bookIDs: [Int64], toGroup targetGroupID: Int64) async throws {}

    func fetchBookshelfDisplaySettings(scope: BookshelfDisplaySettingScope) -> [BookshelfDimension: BookshelfDisplaySetting] {
        Dictionary(uniqueKeysWithValues: BookshelfDimension.allCases.map {
            switch scope {
            case .main:
                return ($0, BookshelfDisplaySetting.defaultValue(for: $0))
            case .bookList:
                return ($0, BookshelfDisplaySetting.defaultBookListValue(for: $0))
            }
        })
    }

    func saveBookshelfDisplaySetting(
        _ setting: BookshelfDisplaySetting,
        for dimension: BookshelfDimension,
        scope: BookshelfDisplaySettingScope
    ) {}

    func observeBookDetail(bookId: Int64) -> AsyncThrowingStream<BookDetail?, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func observeBookNotes(bookId: Int64) -> AsyncThrowingStream<[NoteExcerpt], Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func fetchPickerBooks(matching query: String) async throws -> [BookPickerBook] {
        fetchQueries.append(query)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return localBooks }
        return localBooks.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
            || $0.author.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    func fetchPickerBook(bookId: Int64) async throws -> BookPickerBook? {
        resolvedBooks[bookId]
    }
}

private final class BookPickerTestSearchRepository: BookSearchRepositoryProtocol {
    var resultsBySource: [BookSearchSource: [BookSearchResult]] = [:]
    var searchRequests: [(BookSearchSource, String)] = []
    var prepareSeedRequests: [String] = []
    var preparedSeedsByResultID: [String: BookEditorSeed] = [:]
    var prepareSeedErrors: [String: Error] = [:]

    func search(keyword: String, source: BookSearchSource) async throws -> [BookSearchResult] {
        searchRequests.append((source, keyword))
        return resultsBySource[source] ?? []
    }

    func prepareSeed(for result: BookSearchResult) async throws -> BookEditorSeed {
        prepareSeedRequests.append(result.id)
        if let error = prepareSeedErrors[result.id] {
            throw error
        }
        return preparedSeedsByResultID[result.id] ?? result.seed ?? .manual
    }

    func fetchRecentQueries() -> [String] {
        []
    }

    func saveRecentQuery(_ query: String) { }

    func removeRecentQuery(_ query: String) { }
}
