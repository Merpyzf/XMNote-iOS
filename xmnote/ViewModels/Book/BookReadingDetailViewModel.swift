/**
 * [INPUT]: 依赖 BookReadingDetailRepositoryProtocol 的观察流/写入/偏好接口与 ReadCalendarColorRepositoryProtocol 封面取色
 * [OUTPUT]: 对外提供 BookReadingDetailViewModel，驱动独立阅读详情加载、封面主题、进度/状态 CRUD、庆祝与分享设置
 * [POS]: ViewModels/Book 页面状态中枢，不直接访问数据库或 UserDefaults
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 独立阅读详情页面状态；观察任务随 SwiftUI task 取消，写入成功由新快照自然刷新。
@MainActor
@Observable
final class BookReadingDetailViewModel {
    enum WriteOperation: Hashable {
        case rating
        case progress
        case readingStatus
        case readingStatusDeletion
    }

    let bookID: Int64
    private(set) var snapshot: BookReadingDetailSnapshot?
    private(set) var loadPhase: DailyReadingLoadPhase = .idle
    private(set) var errorMessage: String?
    private(set) var writeOperation: WriteOperation?
    private(set) var completionTracker: BookReadingCompletionTracker?
    var setting = BookReadingDetailSetting()
    var shareSetting = BookReadingDetailShareSetting()
    var ratingValue: Double = 0
    private(set) var coverThemeColor: BookCoverThemeColor = .pending

    var isWriting: Bool { writeOperation != nil }
    var isSavingProgress: Bool { writeOperation == .progress }
    var isSavingStatus: Bool { writeOperation == .readingStatus || writeOperation == .readingStatusDeletion }

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
                guard let value else {
                    snapshot = nil
                    errorMessage = "书籍不存在或已被删除"
                    loadPhase = .failed
                    continue
                }
                snapshot = value
                ratingValue = Double(value.book.score) / 10
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

    /// 读取封面代表色与强调色；无封面或取色失败保持中性背景，成功结果立即原子交给页面主题状态。
    func resolveCoverThemeColor(using repository: any ReadCalendarColorRepositoryProtocol) async {
        guard let book = snapshot?.book else { return }
        guard !book.coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            coverThemeColor = .pending
            return
        }
        let resolved = await repository.resolveCoverThemeColor(
            bookId: book.id,
            bookName: book.name,
            coverURL: book.coverURL
        )
        guard !Task.isCancelled else { return }
        coverThemeColor = resolved
    }

    /// 更新评分；写入期间禁止重复提交，成功后等待观察流刷新书籍快照。
    func updateRating(
        _ stars: Double,
        using repository: any BookReadingDetailRepositoryProtocol
    ) async {
        guard beginWriting(.rating) else { return }
        defer { endWriting() }
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
        guard beginWriting(.progress) else { return }
        defer { endWriting() }
        try await repository.updateProgress(
            bookID: bookID,
            input: BookReadingProgressInput(currentValue: currentValue, totalValue: totalValue)
        )
    }

    /// 新增或精确编辑阅读状态；读完时先提交状态事务，再独立评分，只有新增且两段都成功才产出庆祝追踪。
    func saveReadingStatus(
        _ input: BookReadingStatusInput,
        using repository: any BookReadingDetailRepositoryProtocol
    ) async throws {
        guard beginWriting(.readingStatus) else { return }
        defer { endWriting() }

        if let recordID = input.recordID {
            try await repository.updateReadingStatus(
                bookID: bookID,
                recordID: recordID,
                statusID: input.statusID,
                changedAt: input.changedAt
            )
        } else {
            try await repository.addReadingStatus(
                bookID: bookID,
                statusID: input.statusID,
                changedAt: input.changedAt
            )
        }

        if input.statusID == 3 {
            try await repository.updateRating(bookID: bookID, score: input.ratingScore)
        }
        if input.recordID == nil, input.statusID == 3 {
            completionTracker = try await repository.fetchCompletionTracker()
        }
    }

    /// 删除精确历史记录；唯一状态保护和 book 当前状态回落由 Repository 同一事务完成。
    func deleteReadingStatus(
        recordID: Int64,
        using repository: any BookReadingDetailRepositoryProtocol
    ) async throws {
        guard beginWriting(.readingStatusDeletion) else { return }
        defer { endWriting() }
        try await repository.deleteReadingStatus(bookID: bookID, recordID: recordID)
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

    /// 庆祝层退场后清除一次性追踪，保证页面刷新或生命周期恢复不会重复播放。
    func dismissCompletionCelebration() {
        completionTracker = nil
    }

    /// 建立单写门闩；所有写入都由主 Actor 串行判定，避免跨 Sheet 重复触发。
    private func beginWriting(_ operation: WriteOperation) -> Bool {
        guard writeOperation == nil else { return false }
        writeOperation = operation
        return true
    }

    /// 释放写门闩；调用方以 defer 保证成功、失败与取消都能恢复入口。
    private func endWriting() {
        writeOperation = nil
    }
}
