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
final class ReadingDashboardViewModel {
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

    private func startObservation(referenceDate: Date) {
        isLoading = snapshot == nil
        errorMessage = nil

        observationTask = Task { [weak self] in
            do {
                for try await snapshot in repository.observeDashboard(referenceDate: referenceDate) {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self else { return }
                        self.snapshot = snapshot
                        self.isLoading = false
                        self.errorMessage = nil
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.isLoading = false
                    self.errorMessage = "首页数据加载失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
