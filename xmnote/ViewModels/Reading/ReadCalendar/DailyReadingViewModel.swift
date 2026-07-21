/**
 * [INPUT]: 依赖 ReadCalendarRepositoryProtocol 获取当日聚合并保存打卡
 * [OUTPUT]: 对外提供 DailyReadingViewModel，驱动日期汇总、书籍卡片与打卡写入状态
 * [POS]: Reading/ReadCalendar 二级页面状态中枢，不直接访问数据库
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 当日阅读页的读取阶段。
enum DailyReadingLoadPhase: Hashable {
    case idle
    case loading
    case loaded
    case failed
}

/// 当日阅读页展示的紧凑指标。
struct DailyReadingMetric: Identifiable, Hashable {
    let value: String
    let label: String

    var id: String { "\(value)-\(label)" }
}

/// 当日阅读二级页状态中枢；读取任务遵循 newest-wins，离开页面时可取消且不回写过期结果。
@MainActor
@Observable
final class DailyReadingViewModel {
    let date: Date
    private(set) var summary: DailyReadingSummary
    private(set) var loadPhase: DailyReadingLoadPhase = .idle
    private(set) var errorMessage: String?
    private(set) var isSavingCheckIn = false

    private var loadTask: Task<Void, Never>?
    private var requestToken: UInt64 = 0

    /// 以自然日初始化页面，导航携带的书籍快照不会作为数据真相源。
    init(date: Date) {
        let normalized = Calendar.current.startOfDay(for: date)
        self.date = normalized
        self.summary = .empty(for: normalized)
    }

    var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
            ? "M月d日"
            : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    var headline: String? {
        guard hasAnyData else { return nil }
        if summary.readSeconds > 0 {
            return "阅读 \(ReadDurationFormatter.format(seconds: Int64(summary.readSeconds)))"
        }
        if summary.noteCount > 0 { return "留下 \(summary.noteCount) 条书摘" }
        if summary.reviewCount > 0 { return "写下 \(summary.reviewCount) 篇书评" }
        if summary.relevantCount > 0 { return "整理 \(summary.relevantCount) 条相关内容" }
        if summary.finishedBookCount > 0 { return "读完 \(summary.finishedBookCount) 本书" }
        if !summary.books.isEmpty { return "读了 \(summary.books.count) 本书" }
        return "完成 \(summary.checkInCount) 次打卡"
    }

    var metrics: [DailyReadingMetric] {
        var values: [DailyReadingMetric] = []
        if !summary.books.isEmpty {
            values.append(DailyReadingMetric(value: "\(summary.books.count)", label: "本书"))
        }
        if summary.noteCount > 0 {
            values.append(DailyReadingMetric(value: "\(summary.noteCount)", label: "条书摘"))
        }
        if summary.checkInCount > 0 {
            values.append(DailyReadingMetric(value: "\(summary.checkInCount)", label: "次打卡"))
        }
        if summary.finishedBookCount > 0 {
            values.append(DailyReadingMetric(value: "\(summary.finishedBookCount)", label: "本读完"))
        }
        if summary.reviewCount > 0 {
            values.append(DailyReadingMetric(value: "\(summary.reviewCount)", label: "篇书评"))
        }
        if summary.relevantCount > 0 {
            values.append(DailyReadingMetric(value: "\(summary.relevantCount)", label: "条相关"))
        }
        return Array(values.prefix(3))
    }

    var hasAnyData: Bool {
        !summary.books.isEmpty
            || summary.readSeconds > 0
            || summary.noteCount > 0
            || summary.relevantCount > 0
            || summary.reviewCount > 0
            || summary.checkInCount > 0
            || summary.finishedBookCount > 0
    }

    /// 首次进入时读取当天数据；并发刷新通过 token 丢弃旧响应。
    func loadIfNeeded(using repository: any ReadCalendarRepositoryProtocol) async {
        guard loadPhase == .idle else { return }
        await reload(using: repository)
    }

    /// 重新读取当日聚合；任务取消或 token 过期时不覆盖新页面状态。
    func reload(using repository: any ReadCalendarRepositoryProtocol) async {
        loadTask?.cancel()
        requestToken &+= 1
        let token = requestToken
        loadPhase = .loading
        errorMessage = nil

        let task = Task {
            do {
                let result = try await repository.fetchDailySummary(for: date)
                guard !Task.isCancelled, token == requestToken else { return }
                summary = result
                loadPhase = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, token == requestToken else { return }
                errorMessage = error.localizedDescription
                loadPhase = .failed
            }
        }
        loadTask = task
        await task.value
    }

    /// 即时进入写入态保存打卡，成功后重新查询数据库确认结果；重复点击在写入期间被忽略。
    func saveCheckIn(
        bookID: Int64,
        amount: Int,
        using repository: any ReadCalendarRepositoryProtocol
    ) async throws {
        guard !isSavingCheckIn else { return }
        isSavingCheckIn = true
        defer { isSavingCheckIn = false }
        try await repository.saveCheckIn(
            ReadCalendarCheckInDraft(
                recordID: nil,
                bookID: bookID,
                amount: amount,
                date: date
            )
        )
        await reload(using: repository)
    }

    /// 页面离开时取消读取任务，防止旧日期结果回写。
    func cancel() {
        requestToken &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

}
