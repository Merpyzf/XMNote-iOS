import Foundation

/**
 * [INPUT]: 依赖 StatisticsRepositoryProtocol 提供热力图查询能力，依赖 HeatmapDay/HeatmapStatisticsDataType 领域模型
 * [OUTPUT]: 对外提供 ReadingHeatmapWidgetViewModel（在读页热力图小组件状态与交互编排）
 * [POS]: ViewModels 层在读页热力图状态中枢，负责加载、跨天刷新与统计类型切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@MainActor
@Observable
final class ReadingHeatmapWidgetViewModel {
    var days: [Date: HeatmapDay] = [:]
    var earliestDate: Date? = nil
    var latestDate: Date? = nil
    var statisticsDataType: HeatmapStatisticsDataType = .all

    var isLoading = false
    var errorMessage: String? = nil

    private let calendar = Calendar.current
    private var lastRefreshDay: Date? = nil

    func loadHeatmap(using repository: any StatisticsRepositoryProtocol) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let result = try await repository.fetchHeatmapData(
                year: 0,
                dataType: statisticsDataType
            )
            days = result.days
            earliestDate = result.earliestDate
            latestDate = result.latestDate
            lastRefreshDay = calendar.startOfDay(for: Date())
        } catch {
            if days.isEmpty {
                earliestDate = nil
                latestDate = nil
            }
            errorMessage = "热力图加载失败：\(error.localizedDescription)"
        }
    }

    func changeDataType(
        _ dataType: HeatmapStatisticsDataType,
        using repository: any StatisticsRepositoryProtocol
    ) async {
        guard statisticsDataType != dataType else { return }
        statisticsDataType = dataType
        await loadHeatmap(using: repository)
    }

    func refreshIfDayChanged(using repository: any StatisticsRepositoryProtocol) async {
        let today = calendar.startOfDay(for: Date())
        guard lastRefreshDay != today else { return }
        await loadHeatmap(using: repository)
    }
}
