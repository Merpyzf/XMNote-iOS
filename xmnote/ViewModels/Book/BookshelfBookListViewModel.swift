/**
 * [INPUT]: 依赖 BookRepositoryProtocol 提供二级书籍列表观察流，依赖 BookshelfBookListRoute 描述当前聚合上下文
 * [OUTPUT]: 对外提供 BookshelfBookListViewModel，驱动二级书籍列表加载、空态、搜索与实时刷新
 * [POS]: Book 模块二级书籍列表状态编排器，被 BookshelfBookListView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 二级书籍列表状态编排器，让 pushed destination 通过 Repository 实时观察数据，而不是消费静态路由数组。
@Observable
final class BookshelfBookListViewModel {
    let route: BookshelfBookListRoute
    var snapshot: BookshelfBookListSnapshot = .empty
    var contentState: BookshelfContentState = .loading
    var searchKeyword: String = "" {
        didSet {
            guard normalizedSearchKeyword(oldValue) != normalizedSearchKeyword(searchKeyword) else { return }
            restartObservation()
        }
    }
    var displaySetting: BookshelfDisplaySetting

    private let repository: any BookRepositoryProtocol
    private var observationTask: Task<Void, Never>?

    var navigationTitle: String {
        route.title
    }

    var subtitle: String {
        snapshot.subtitle.isEmpty ? route.subtitleHint : snapshot.subtitle
    }

    /// 注入路由和仓储，并启动二级列表观察流。
    init(
        route: BookshelfBookListRoute,
        repository: any BookRepositoryProtocol
    ) {
        self.route = route
        self.repository = repository
        let settings = repository.fetchBookshelfDisplaySettings()
        self.displaySetting = settings[route.context.dimension] ?? .defaultValue(for: route.context.dimension)
        startObservation()
    }

    /// 取消二级列表观察任务。
    deinit {
        observationTask?.cancel()
    }

    /// 清空搜索关键词并恢复完整列表。
    func clearSearchKeyword() {
        searchKeyword = ""
    }

    private func startObservation() {
        contentState = .loading
        let context = route.context
        let currentSetting = displaySetting
        let currentKeyword = normalizedSearchKeyword(searchKeyword)
        observationTask = Task {
            do {
                for try await snapshot in repository.observeBookshelfBookList(
                    context: context,
                    setting: currentSetting,
                    searchKeyword: currentKeyword
                ) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.snapshot = snapshot
                        self.contentState = snapshot.books.isEmpty ? .empty : .content
                    }
                }
            } catch {
                await MainActor.run {
                    self.contentState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func restartObservation() {
        observationTask?.cancel()
        startObservation()
    }

    private func normalizedSearchKeyword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
