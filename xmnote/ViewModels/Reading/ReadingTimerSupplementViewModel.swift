import Foundation
import Observation

/**
 * [INPUT]: 依赖 ReadingTimerRepositoryProtocol 提供书籍上下文读取与补录记录保存能力，依赖 ReadingTimerSupplementInput 承接保存字段
 * [OUTPUT]: 对外提供 ReadingTimerSupplementViewModel（补录阅读的加载、表单校验与保存状态）
 * [POS]: ViewModels/Reading 的阅读补录状态编排器，被 ReadingTimerSupplementView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
/// 阅读补录状态编排器，负责把“按日期记录 / 按开始结束记录”表单转换为兼容 Android 的完成记录。
final class ReadingTimerSupplementViewModel {
    var bookContext: ReadingTimerBookContext?
    var mode: ReadingTimerSupplementMode = .dateDuration
    var readDate: Date = Date()
    var startAt: Date = Calendar.current.date(byAdding: .minute, value: -30, to: Date()) ?? Date()
    var endAt: Date = Date()
    var hoursText = "0"
    var minutesText = "30"
    var positionText = ""
    var insight = ""
    var markReadDone = false
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var didSave = false

    private let repository: any ReadingTimerRepositoryProtocol

    /// 注入阅读计时仓储，等待页面根据入口书籍加载上下文。
    init(repository: any ReadingTimerRepositoryProtocol) {
        self.repository = repository
    }

    var durationSeconds: Int64 {
        switch mode {
        case .dateDuration:
            let hours = max(0, Int(hoursText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            let minutes = max(0, Int(minutesText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            return Int64(hours * 3600 + minutes * 60)
        case .timeRange:
            return max(0, Int64(endAt.timeIntervalSince(startAt)))
        }
    }

    var needsLongDurationConfirmation: Bool {
        durationSeconds > 8 * 60 * 60
    }

    var positionValue: Double? {
        let trimmed = positionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    /// 加载入口书籍上下文，并用当前书籍阅读位置预填补录位置。
    /// 并发语义：方法运行在 MainActor；Repository 异步读取可被取消，取消后不写回 UI 状态。
    func load(bookId: Int64) async {
        guard bookContext == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let context = try await repository.fetchBookContext(bookId: bookId)
            bookContext = context
            if context.readPosition > 0 {
                positionText = Self.positionText(for: context.readPosition)
            }
        } catch {
            errorMessage = "补录页面加载失败：\(error.localizedDescription)"
        }
    }

    /// 保存补录记录；日期模式写入 fuzzy_read_date，精确模式写入 start_time/end_time。
    /// 并发语义：保存期间禁用重复提交；Repository 在事务中写入记录、位置和读完状态。
    func save() async {
        guard let bookContext else { return }
        let seconds = durationSeconds
        guard seconds > 0 else {
            errorMessage = "请输入有效的阅读时长"
            return
        }
        if mode == .timeRange, endAt <= startAt {
            errorMessage = "结束时间需要晚于开始时间"
            return
        }
        if mode == .timeRange, endAt > Date() {
            errorMessage = "结束时间不能晚于现在"
            return
        }
        if mode == .dateDuration,
           Calendar.current.startOfDay(for: readDate) > Calendar.current.startOfDay(for: Date()) {
            errorMessage = "阅读日期不能晚于今天"
            return
        }
        if !positionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           positionValue == nil {
            errorMessage = "阅读位置格式不正确"
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let input = ReadingTimerSupplementInput(
                bookId: bookContext.id,
                mode: mode,
                readDate: mode == .dateDuration ? readDate : nil,
                startAt: mode == .timeRange ? startAt : nil,
                endAt: mode == .timeRange ? endAt : nil,
                elapsedSeconds: seconds,
                position: positionValue,
                insight: insight,
                markReadDone: markReadDone
            )
            _ = try await repository.saveSupplement(input)
            NotificationCenter.default.post(name: .readingTimerRecordsDidChange, object: nil)
            didSave = true
        } catch {
            errorMessage = "补录保存失败：\(error.localizedDescription)"
        }
    }

    private static func positionText(for value: Double) -> String {
        if value.rounded() == value {
            return String(Int64(value))
        }
        return String(value)
    }
}
