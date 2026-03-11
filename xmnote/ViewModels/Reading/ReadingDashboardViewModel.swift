import Foundation
import Observation

/**
 * [INPUT]: 依赖 ReadingDashboardRepositoryProtocol 提供首页聚合观察流，依赖 ReadingDashboardSnapshot 领域模型与格式化工具
 * [OUTPUT]: 对外提供 ReadingDashboardViewModel（在读首页状态管理与目标编辑交互编排）
 * [POS]: ViewModels/Reading 的首页仪表盘状态中枢，被 ReadingDashboardView 与相关 Sheet 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
/// 在读首页状态中枢，负责首页聚合订阅与目标编辑交互。
final class ReadingDashboardViewModel {
    /// GoalEditorMode 区分今日目标与年度目标编辑入口，避免弹层文案和保存逻辑分叉散落在视图层。
    enum GoalEditorMode: Equatable {
        case daily
        case yearly

        var title: String {
            switch self {
            case .daily: "设置今日阅读目标"
            case .yearly: "设置年度阅读目标"
            }
        }
    }

    var snapshot: ReadingDashboardSnapshot?
    var isLoading = false
    var errorMessage: String?
    var goalEditorMode: GoalEditorMode?
    var draftGoalValue = ""
    var isSavingGoal = false

    private let repository: any ReadingDashboardRepositoryProtocol
    private let calendar = Calendar.current
    private var observationTask: Task<Void, Never>?
    private var activeReferenceDate: Date?

    /// 注入首页仓储，等待视图触发首轮订阅。
    init(repository: any ReadingDashboardRepositoryProtocol) {
        self.repository = repository
    }

    var trendMetrics: [ReadingTrendMetric] {
        snapshot?.trends ?? []
    }

    var dailyGoal: ReadingDailyGoal {
        snapshot?.dailyGoal ?? ReadingDailyGoal(readSeconds: 0, targetSeconds: 3600)
    }

    var resumeBook: ReadingResumeBook? {
        snapshot?.resumeBook
    }

    var recentBooks: [ReadingRecentBook] {
        snapshot?.recentBooks ?? []
    }

    var yearSummary: ReadingYearSummary? {
        snapshot?.yearSummary
    }

    /// 启动首页 observation；业务意图是让 KeepAlive 页面首次进入后建立常驻订阅。
    func startObservationIfNeeded(referenceDate: Date = Date()) {
        let normalized = calendar.startOfDay(for: referenceDate)
        guard observationTask == nil else { return }
        activeReferenceDate = normalized
        startObservation(referenceDate: normalized)
    }

    /// 场景回到前台且跨天时重建首页订阅，保证“今日/今年”语义及时切换。
    func refreshIfNeeded(referenceDate: Date = Date()) {
        let normalized = calendar.startOfDay(for: referenceDate)
        guard activeReferenceDate != normalized else { return }
        observationTask?.cancel()
        observationTask = nil
        activeReferenceDate = normalized
        startObservation(referenceDate: normalized)
    }

    /// 打开今日目标编辑弹层，并填入当前目标值。
    func presentDailyGoalEditor() {
        goalEditorMode = .daily
        draftGoalValue = "\(max(1, dailyGoal.targetSeconds / 60))"
    }

    /// 打开年度目标编辑弹层，并填入当前目标值。
    func presentYearlyGoalEditor() {
        goalEditorMode = .yearly
        draftGoalValue = "\(max(1, yearSummary?.targetCount ?? 12))"
    }

    /// 关闭目标编辑弹层并清空草稿。
    func dismissGoalEditor() {
        goalEditorMode = nil
        draftGoalValue = ""
    }

    /// 保存当前弹层对应的目标值。
    /// 业务意图：把编辑弹层中的草稿值回写到首页真相源，并让 observation 自动刷新卡片。
    /// 前置条件：goalEditorMode 已设置，且草稿值能解析成正整数。
    /// 副作用：写入 `read_target` 对应记录，并在失败时更新错误文案。
    /// 失败语义：仓储写入失败时保留弹层，向页面暴露可读错误信息。
    func saveGoal() async {
        guard let mode = goalEditorMode else { return }
        let trimmed = draftGoalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else {
            errorMessage = mode == .daily ? "请输入大于 0 的分钟数" : "请输入大于 0 的年度目标"
            return
        }

        isSavingGoal = true
        defer { isSavingGoal = false }

        do {
            switch mode {
            case .daily:
                let referenceDate = activeReferenceDate ?? calendar.startOfDay(for: Date())
                try await repository.updateDailyReadingGoal(seconds: value * 60, for: referenceDate)
            case .yearly:
                let year = yearSummary?.year ?? calendar.component(.year, from: Date())
                try await repository.updateYearlyReadGoal(count: value, forYear: year)
            }
            dismissGoalEditor()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    /// 建立首页观察任务，并在主线程回写最新快照。
    /// 并发语义：仓储 observation 在后台持续消费，状态写入统一回到 MainActor；跨天刷新时由外层先取消旧任务再重建。
    private func startObservation(referenceDate: Date) {
        isLoading = snapshot == nil
        errorMessage = nil

        observationTask = Task { [weak self, repository = self.repository] in
            do {
                for try await snapshot in repository.observeDashboard(referenceDate: referenceDate) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.snapshot = snapshot
                        self.isLoading = false
                        self.errorMessage = nil
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    self.errorMessage = "首页数据加载失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
