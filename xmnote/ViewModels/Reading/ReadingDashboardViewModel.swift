import Foundation
import Observation

/**
 * [INPUT]: 依赖 ReadingDashboardRepositoryProtocol 提供首页聚合观察流，依赖 ReadingDashboardSnapshot 领域模型与格式化工具
 * [OUTPUT]: 对外提供 ReadingDashboardViewModel（原子快照订阅、首轮加载重试、目标草稿校验与错误反馈）
 * [POS]: ViewModels/Reading 的首页仪表盘状态中枢，被 ReadingDashboardView 与相关 Sheet 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
/// 在读首页状态中枢，负责首页聚合订阅与目标编辑交互。
final class ReadingDashboardViewModel {
    static let yearlyGoalRange = 1...365

    /// GoalEditorMode 区分今日目标与年度目标编辑入口，避免弹层文案和保存逻辑分叉散落在视图层。
    enum GoalEditorMode: Equatable {
        case daily
        case yearly

        var title: String {
            switch self {
            case .daily: "设置今日阅读目标"
            case .yearly: "年度阅读目标"
            }
        }
    }

    var snapshot: ReadingDashboardSnapshot?
    var isLoading = false
    var errorMessage: String?
    var goalEditorMode: GoalEditorMode?
    var draftGoalValue = ""
    var goalEditorErrorMessage: String?
    var isSavingGoal = false

    private let repository: any ReadingDashboardRepositoryProtocol
    private let calendar = Calendar.current
    private var observationTask: Task<Void, Never>?
    private var activeReferenceDate: Date?

    /// 注入首页仓储，等待视图触发首轮订阅。
    init(repository: any ReadingDashboardRepositoryProtocol) {
        self.repository = repository
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

    /// 重试首轮首页读取，并沿用当前业务日期重建 observation。
    /// 并发语义：先取消并释放旧任务，再由 MainActor 建立唯一新任务；旧任务的取消结果不会覆盖新任务状态。
    func retryInitialLoad(referenceDate: Date = Date()) {
        observationTask?.cancel()
        observationTask = nil
        let normalized = activeReferenceDate ?? calendar.startOfDay(for: referenceDate)
        activeReferenceDate = normalized
        startObservation(referenceDate: normalized)
    }

    /// 打开今日目标编辑弹层，并填入当前目标值。
    func presentDailyGoalEditor() {
        guard let dailyGoal = snapshot?.dailyGoal else { return }
        goalEditorErrorMessage = nil
        goalEditorMode = .daily
        draftGoalValue = "\(max(1, dailyGoal.targetSeconds / 60))"
    }

    /// 打开年度目标编辑弹层，并填入当前目标值。
    func presentYearlyGoalEditor() {
        guard let yearSummary = snapshot?.yearSummary else { return }
        goalEditorErrorMessage = nil
        goalEditorMode = .yearly
        let currentTarget = yearSummary.targetCount
        let clampedTarget = min(
            max(currentTarget, Self.yearlyGoalRange.lowerBound),
            Self.yearlyGoalRange.upperBound
        )
        draftGoalValue = "\(clampedTarget)"
    }

    /// 关闭目标编辑弹层并清空草稿。
    func dismissGoalEditor() {
        goalEditorMode = nil
        draftGoalValue = ""
        goalEditorErrorMessage = nil
    }

    /// 保存当前弹层对应的目标值。
    /// 业务意图：把编辑弹层中的草稿值回写到首页真相源，并让 observation 自动刷新卡片。
    /// 前置条件：goalEditorMode 已设置；今日目标为正整数，年度目标位于 1...365。
    /// 副作用：写入 `read_target` 对应记录，并在失败时更新目标编辑错误文案。
    /// 失败语义：校验或仓储写入失败时保留弹层，避免错误信息落到被遮挡的首页。
    func saveGoal() async {
        guard let mode = goalEditorMode, !isSavingGoal else { return }
        goalEditorErrorMessage = nil
        let trimmed = draftGoalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else {
            goalEditorErrorMessage = mode == .daily ? "请输入大于 0 的分钟数" : "请选择 1 至 365 本"
            return
        }

        switch mode {
        case .daily:
            guard value > 0 else {
                goalEditorErrorMessage = "请输入大于 0 的分钟数"
                return
            }
        case .yearly:
            guard Self.yearlyGoalRange.contains(value) else {
                goalEditorErrorMessage = "请选择 1 至 365 本"
                return
            }
        }

        isSavingGoal = true
        defer { isSavingGoal = false }

        do {
            switch mode {
            case .daily:
                let referenceDate = activeReferenceDate ?? calendar.startOfDay(for: Date())
                try await repository.updateDailyReadingGoal(seconds: value * 60, for: referenceDate)
            case .yearly:
                let year = snapshot?.yearSummary.year ?? calendar.component(.year, from: Date())
                try await repository.updateYearlyReadGoal(count: value, forYear: year)
            }
            dismissGoalEditor()
        } catch {
            goalEditorErrorMessage = "保存失败：\(error.localizedDescription)"
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
