#if DEBUG
import Foundation

/**
 * [INPUT]: 依赖 HeatmapDay/HeatmapLevel 领域模型
 * [OUTPUT]: 对外提供 HeatmapTestViewModel（测试数据生成与场景切换）
 * [POS]: Debug 测试页状态编排，供 HeatmapTestView 消费；支持真实仓储数据集成测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - 测试场景

enum HeatmapTestScenario: String, CaseIterable, Identifiable {
    case empty        = "空数据"
    case sparse       = "稀疏（3个月）"
    case dense        = "密集（6个月）"
    case checkInOnly  = "仅打卡"
    case fullYear     = "全年"
    case multiYear    = "跨年（2年）"
    case allLevels    = "全等级"
    case todayOnly    = "仅今天"
    case edgeBoundary = "边界值"
    case realData     = "真实数据（仓储）"

    var id: String { rawValue }
}

// MARK: - ViewModel

@MainActor
@Observable
class HeatmapTestViewModel {
    var days: [Date: HeatmapDay] = [:]
    var earliestDate: Date? = nil
    var latestDate: Date? = nil
    var statisticsDataType: HeatmapStatisticsDataType = .all
    var selectedDay: HeatmapDay? = nil
    var currentScenario: HeatmapTestScenario = .empty
    var realDataType: HeatmapStatisticsDataType = .all
    var realDataYear: Int = 0
    var isLoadingRealData = false
    var realDataError: String? = nil

    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date()) }

    func loadScenario(_ scenario: HeatmapTestScenario) {
        currentScenario = scenario
        selectedDay = nil
        latestDate = nil
        realDataError = nil

        switch scenario {
        case .empty:        loadEmpty()
        case .sparse:       loadSparse()
        case .dense:        loadDense()
        case .checkInOnly:  loadCheckInOnly()
        case .fullYear:     loadFullYear()
        case .multiYear:    loadMultiYear()
        case .allLevels:    loadAllLevels()
        case .todayOnly:    loadTodayOnly()
        case .edgeBoundary: loadEdgeBoundary()
        case .realData:     break
        }
    }

    func loadRealData(using repository: any StatisticsRepositoryProtocol) async {
        currentScenario = .realData
        selectedDay = nil
        isLoadingRealData = true
        realDataError = nil

        do {
            let result = try await repository.fetchHeatmapData(
                year: realDataYear,
                dataType: realDataType
            )
            days = result.days
            earliestDate = result.earliestDate
            latestDate = result.latestDate
            statisticsDataType = realDataType
            if result.earliestDate == nil {
                realDataError = "当前仓储没有可用热力图数据。"
            }
        } catch {
            days = [:]
            earliestDate = nil
            latestDate = nil
            realDataError = "真实数据加载失败：\(error.localizedDescription)"
        }

        isLoadingRealData = false
    }

    var candidateYears: [Int] {
        let currentYear = calendar.component(.year, from: Date())
        return [0, currentYear, currentYear - 1, currentYear - 2]
    }
}

// MARK: - 场景数据生成

private extension HeatmapTestViewModel {

    func loadEmpty() {
        statisticsDataType = .all
        days = [:]
        earliestDate = nil
    }

    func loadSparse() {
        statisticsDataType = .all
        let start = calendar.date(byAdding: .month, value: -3, to: today)!
        var result: [Date: HeatmapDay] = [:]
        for _ in 0..<20 {
            let offset = Int.random(in: 0..<90)
            let date = calendar.date(byAdding: .day, value: -offset, to: today)!
            let d = calendar.startOfDay(for: date)
            result[d] = HeatmapDay(
                id: d,
                readSeconds: Int.random(in: 600...7200),
                noteCount: Int.random(in: 0...8),
                checkInCount: 0,
                checkInSeconds: 0
            )
        }
        days = result
        earliestDate = start
    }

    func loadDense() {
        statisticsDataType = .all
        let start = calendar.date(byAdding: .month, value: -6, to: today)!
        var result: [Date: HeatmapDay] = [:]
        var current = calendar.startOfDay(for: start)
        var seconds = 300
        while current <= today {
            seconds = min(seconds + Int.random(in: -200...300), 5400)
            seconds = max(seconds, 100)
            let checkInCount = Int.random(in: 0...1)
            result[current] = HeatmapDay(
                id: current,
                readSeconds: seconds,
                noteCount: Int.random(in: 0...12),
                checkInCount: checkInCount,
                checkInSeconds: checkInCount * 20 * 60
            )
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        days = result
        earliestDate = start
    }

    func loadCheckInOnly() {
        statisticsDataType = .checkIn
        let start = calendar.date(byAdding: .day, value: -29, to: today)!
        var result: [Date: HeatmapDay] = [:]
        var current = calendar.startOfDay(for: start)
        while current <= today {
            if Int.random(in: 0...2) > 0 {
                let checkInCount = Int.random(in: 1...3)
                result[current] = HeatmapDay(
                    id: current,
                    readSeconds: 0,
                    noteCount: 0,
                    checkInCount: checkInCount,
                    checkInSeconds: checkInCount * 20 * 60
                )
            }
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        days = result
        earliestDate = start
    }

    func loadFullYear() {
        statisticsDataType = .all
        let start = calendar.date(byAdding: .day, value: -364, to: today)!
        var result: [Date: HeatmapDay] = [:]
        var current = calendar.startOfDay(for: start)
        var dayIndex = 0
        while current <= today {
            // 正弦波模拟阅读节奏
            let wave = sin(Double(dayIndex) / 30.0 * .pi)
            let seconds = Int(max(0, wave * 2400 + 1200))
            result[current] = HeatmapDay(
                id: current,
                readSeconds: seconds,
                noteCount: Int.random(in: 0...5),
                checkInCount: 0,
                checkInSeconds: 0
            )
            current = calendar.date(byAdding: .day, value: 1, to: current)!
            dayIndex += 1
        }
        days = result
        earliestDate = start
    }
}

// MARK: - 跨年与特殊场景

private extension HeatmapTestViewModel {

    func loadMultiYear() {
        statisticsDataType = .all
        let start = calendar.date(byAdding: .year, value: -2, to: today)!
        var result: [Date: HeatmapDay] = [:]
        var current = calendar.startOfDay(for: start)
        while current <= today {
            if Int.random(in: 0...3) > 0 {
                let checkInCount = Int.random(in: 0...2)
                result[current] = HeatmapDay(
                    id: current,
                    readSeconds: Int.random(in: 300...4800),
                    noteCount: Int.random(in: 0...10),
                    checkInCount: checkInCount,
                    checkInSeconds: checkInCount * 20 * 60
                )
            }
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        days = result
        earliestDate = start
    }

    func loadAllLevels() {
        statisticsDataType = .readingTime
        let values = [0, 600, 1800, 3000, 5000]
        var result: [Date: HeatmapDay] = [:]
        for (i, seconds) in values.enumerated() {
            let date = calendar.date(byAdding: .day, value: -i, to: today)!
            result[date] = HeatmapDay(
                id: date,
                readSeconds: seconds,
                noteCount: 0,
                checkInCount: 0,
                checkInSeconds: 0
            )
        }
        days = result
        earliestDate = calendar.date(byAdding: .day, value: -4, to: today)
    }

    func loadTodayOnly() {
        statisticsDataType = .all
        days = [
            today: HeatmapDay(
                id: today,
                readSeconds: 1800,
                noteCount: 3,
                checkInCount: 1,
                checkInSeconds: 20 * 60
            )
        ]
        earliestDate = today
    }

    func loadEdgeBoundary() {
        statisticsDataType = .readingTime
        let thresholds = [1200, 1201, 2400, 2401, 3600, 3601]
        var result: [Date: HeatmapDay] = [:]
        for (i, seconds) in thresholds.enumerated() {
            let date = calendar.date(byAdding: .day, value: -i, to: today)!
            result[date] = HeatmapDay(
                id: date,
                readSeconds: seconds,
                noteCount: 0,
                checkInCount: 0,
                checkInSeconds: 0
            )
        }
        days = result
        earliestDate = calendar.date(byAdding: .day, value: -5, to: today)
    }
}
#endif
