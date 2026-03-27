import Foundation
import Testing
@testable import xmnote

@MainActor
struct BookPickerViewModelTests {
    @Test
    func localLoadUsesBookRepositoryAndAppliesDefaultQuery() async {
        let localBooks = [
            BookPickerBook(id: 1, title: "三体", author: "刘慈欣", coverURL: "", positionUnit: 0, totalPosition: 0, totalPagination: 302),
            BookPickerBook(id: 2, title: "球状闪电", author: "刘慈欣", coverURL: "", positionUnit: 0, totalPosition: 0, totalPagination: 280)
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
            BookPickerBook(id: 1, title: "三体", author: "刘慈欣", coverURL: "", positionUnit: 0, totalPosition: 0, totalPagination: 302),
            BookPickerBook(id: 2, title: "球状闪电", author: "刘慈欣", coverURL: "", positionUnit: 0, totalPosition: 0, totalPagination: 280)
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
        searchRepository.resultsBySource[.wenqu] = [
            BookSearchResult(
                id: "w-1",
                source: .wenqu,
                title: "三体",
                author: "刘慈欣",
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
                detailPageURL: nil
            )
        ]
        searchRepository.resultsBySource[.douban] = [
            BookSearchResult(
                id: "d-1",
                source: .douban,
                title: "三体（豆瓣）",
                author: "刘慈欣",
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
                detailPageURL: nil
            )
        ]
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
        #expect(searchRepository.searchRequests == [(.wenqu, "三体"), (.douban, "三体")])
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
        let createdBook = BookPickerBook(id: 99, title: "新书", author: "作者", coverURL: "", positionUnit: 0, totalPosition: 0, totalPagination: 100)

        let singleRepository = BookPickerTestBookRepository(localBooks: [createdBook], resolvedBooks: [99: createdBook])
        let singleViewModel = BookPickerViewModel(
            configuration: BookPickerConfiguration(scope: .local, selectionMode: .single),
            bookRepository: singleRepository,
            searchRepository: BookPickerTestSearchRepository()
        )
        let singleResult = await singleViewModel.handleCreatedBook(bookId: 99)

        #expect(singleResult == .single(createdBook))

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

    private func settleAsyncState() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        await Task.yield()
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

    func search(keyword: String, source: BookSearchSource) async throws -> [BookSearchResult] {
        searchRequests.append((source, keyword))
        return resultsBySource[source] ?? []
    }

    func prepareSeed(for result: BookSearchResult) async throws -> BookEditorSeed {
        result.seed ?? .manual
    }

    func fetchRecentQueries() -> [String] {
        []
    }

    func saveRecentQuery(_ query: String) { }

    func removeRecentQuery(_ query: String) { }
}
