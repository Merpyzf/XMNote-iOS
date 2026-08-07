/**
 * [INPUT]: 依赖 BookReadingDetailRepositoryProtocol 的观察流、写入与偏好接口
 * [OUTPUT]: 对外提供 BookReadingDetailViewModel，驱动独立阅读详情的加载、局部写入与分享设置
 * [POS]: ViewModels/Book 页面状态中枢，不直接访问数据库或 UserDefaults
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 独立阅读详情页面状态；观察任务随 SwiftUI task 取消，写入成功由新快照自然刷新。
@MainActor
@Observable
final class BookReadingDetailViewModel {
    let bookID: Int64
    private(set) var snapshot: BookReadingDetailSnapshot?
    private(set) var loadPhase: DailyReadingLoadPhase = .idle
    private(set) var errorMessage: String?
    private(set) var isWriting = false
    var setting = BookReadingDetailSetting()
    var shareSetting = BookReadingDetailShareSetting()
    var ratingValue: Double = 0
    var headerColor: ReadCalendarSegmentColor = .pending

    /// 以书籍主键初始化；页面数据始终由 Repository 观察流提供。
    init(bookID: Int64) {
        self.bookID = bookID
    }

    /// 启动单一观察流；任务取消时停止迭代，后续事务不会回写已离开的页面。
    func observe(using repository: any BookReadingDetailRepositoryProtocol) async {
        setting = repository.fetchSetting()
        shareSetting = repository.fetchShareSetting()
        loadPhase = .loading
        errorMessage = nil
        do {
            for try await value in repository.observeSnapshot(bookID: bookID) {
                try Task.checkCancellation()
                snapshot = value
                ratingValue = Double(value?.book.score ?? 0) / 10
                loadPhase = .loaded
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            loadPhase = .failed
        }
    }

    /// 读取封面主色用于页头轻量背景；取色失败时仓储返回稳定回退色，不影响正文加载。
    func resolveHeaderColor(using repository: any ReadCalendarColorRepositoryProtocol) async {
        guard let book = snapshot?.book else { return }
        headerColor = await repository.resolveEventColor(
            bookId: book.id,
            bookName: book.name,
            coverURL: book.coverURL
        )
    }

    /// 更新评分；写入期间禁止重复提交，成功后等待观察流刷新书籍快照。
    func updateRating(
        _ stars: Double,
        using repository: any BookReadingDetailRepositoryProtocol
    ) async {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        do {
            try await repository.updateRating(
                bookID: bookID,
                score: Int64((min(max(stars, 0), 5) * 10).rounded())
            )
        } catch {
            errorMessage = "评分更新失败：\(error.localizedDescription)"
        }
    }

    /// 更新阅读进度；Repository 依据书籍原单位选择目标字段。
    func updateProgress(
        currentValue: Double,
        totalValue: Int64?,
        using repository: any BookReadingDetailRepositoryProtocol
    ) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        try await repository.updateProgress(
            bookID: bookID,
            input: BookReadingProgressInput(currentValue: currentValue, totalValue: totalValue)
        )
    }

    /// 更新阅读状态和变更日期；状态历史合并及读完副作用由 Repository 事务收敛。
    func updateReadingStatus(
        statusID: Int64,
        changedAt: Date,
        using repository: any BookReadingDetailRepositoryProtocol
    ) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        try await repository.updateReadingStatus(bookID: bookID, statusID: statusID, changedAt: changedAt)
    }

    /// 保存页面设置并立即更新可观察状态。
    func saveSetting(
        _ value: BookReadingDetailSetting,
        using repository: any BookReadingDetailRepositoryProtocol
    ) {
        setting = value
        repository.saveSetting(value)
    }

    /// 保存七项长图开关并立即更新预览。
    func saveShareSetting(
        _ value: BookReadingDetailShareSetting,
        using repository: any BookReadingDetailRepositoryProtocol
    ) {
        shareSetting = value
        repository.saveShareSetting(value)
    }

    /// 消费一次性错误文本，避免 Toast 重复出现。
    func consumeError() {
        errorMessage = nil
    }
}
