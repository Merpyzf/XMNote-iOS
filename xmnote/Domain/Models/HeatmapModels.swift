import Foundation
import SwiftUI

/**
 * [INPUT]: 依赖 DesignTokens 的 Color 语义扩展（heatmapNone/brandLight/brand/brandDeep/brandDarkest/status*）
 * [OUTPUT]: 对外提供 HeatmapDay（单日热力数据，含书籍状态分段）、HeatmapLevel（五级强度枚举）、HeatmapStatisticsDataType（统计类型）
 * [POS]: Domain 层热力图领域模型，供 StatisticsRepository 产出、HeatmapChart 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - 统计类型

/// 对齐 Android AppConstant.HeatChartStatisticsDataType
enum HeatmapStatisticsDataType: Int, CaseIterable, Identifiable {
    case noteCount = 1
    case readingTime = 2
    case all = 3
    case checkIn = 4

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .noteCount: "书摘"
        case .readingTime: "阅读"
        case .all: "全部"
        case .checkIn: "打卡"
        }
    }
}

// MARK: - 阅读状态

/// 对齐 Android BookReadingStatus：1=想读 2=在读 3=读完 4=弃读 5=搁置
enum HeatmapBookState: Int, CaseIterable, Hashable {
    case wantRead = 1
    case reading = 2
    case readDone = 3
    case abandon = 4
    case onHold = 5

    /// 对齐 Android Mark.getColors 的叠加顺序：想读→在读→读完→搁置→弃读
    static let renderOrder: [HeatmapBookState] = [.wantRead, .reading, .readDone, .onHold, .abandon]

    var color: Color {
        switch self {
        case .wantRead: .statusWish
        case .reading: .statusReading
        case .readDone: .statusDone
        case .onHold: .statusOnHold
        case .abandon: .statusAbandoned
        }
    }

    var title: String {
        switch self {
        case .wantRead: "想读"
        case .reading: "在读"
        case .readDone: "读完"
        case .onHold: "搁置"
        case .abandon: "弃读"
        }
    }
}

// MARK: - 单日热力数据

struct HeatmapDay: Identifiable {
    let id: Date          // 日历日期（零时零分零秒）
    let readSeconds: Int  // 阅读秒数
    let noteCount: Int    // 书摘数量
    let checkInCount: Int // 打卡次数
    let checkInSeconds: Int // 打卡时长（秒）
    let bookStates: Set<HeatmapBookState> // 书籍阅读状态（可多状态叠加）

    init(
        id: Date,
        readSeconds: Int,
        noteCount: Int,
        checkInCount: Int,
        checkInSeconds: Int,
        bookStates: Set<HeatmapBookState> = []
    ) {
        self.id = id
        self.readSeconds = readSeconds
        self.noteCount = noteCount
        self.checkInCount = checkInCount
        self.checkInSeconds = checkInSeconds
        self.bookStates = bookStates
    }

    /// 综合等级取阅读时长/笔记数/打卡时长三者最大值
    var level: HeatmapLevel {
        let readLevel = HeatmapLevel.from(readSeconds: readSeconds)
        let noteLevel = HeatmapLevel.from(noteCount: noteCount)
        let checkInLevel = HeatmapLevel.from(checkInSeconds: checkInSeconds)
        let maxRaw = max(max(readLevel.rawValue, noteLevel.rawValue), checkInLevel.rawValue)
        return HeatmapLevel(rawValue: maxRaw) ?? .none
    }

    /// Android 空数据格子也可点击；这里提供零值占位模型
    static func empty(for date: Date) -> HeatmapDay {
        HeatmapDay(
            id: date,
            readSeconds: 0,
            noteCount: 0,
            checkInCount: 0,
            checkInSeconds: 0,
            bookStates: []
        )
    }

    /// 当前统计类型对应的强度等级（用于“阅读/书摘/打卡/全部”切换）
    func amountLevel(for dataType: HeatmapStatisticsDataType) -> HeatmapLevel {
        switch dataType {
        case .noteCount:
            HeatmapLevel.from(noteCount: noteCount)
        case .readingTime:
            HeatmapLevel.from(readSeconds: readSeconds)
        case .all:
            level
        case .checkIn:
            // 对齐 Android Mark.getColors：CHECK_IN 走 ALL 的 amount 计算分支
            level
        }
    }

    /// 对齐 Android Mark.getColors：先绘制状态色，再按统计类型补充阅读量色。
    func segmentColors(for dataType: HeatmapStatisticsDataType) -> [Color] {
        let stateColors = HeatmapBookState.renderOrder.compactMap { state in
            bookStates.contains(state) ? state.color : nil
        }

        let amountColor = amountLevel(for: dataType).color
        if stateColors.isEmpty {
            return [amountColor]
        }

        switch dataType {
        case .noteCount:
            return noteCount == 0 ? stateColors : stateColors + [amountColor]
        case .readingTime:
            return readSeconds == 0 ? stateColors : stateColors + [amountColor]
        case .all:
            let hasAnyAmount = noteCount != 0 || readSeconds != 0 || checkInSeconds != 0
            return hasAnyAmount ? stateColors + [amountColor] : stateColors
        case .checkIn:
            // 对齐 Android 现有行为：CHECK_IN + 有状态色时，不追加 amount 色块
            return stateColors
        }
    }

    var bookStateTitles: String {
        let titles = HeatmapBookState.renderOrder.compactMap { state in
            bookStates.contains(state) ? state.title : nil
        }
        return titles.isEmpty ? "无" : titles.joined(separator: "、")
    }
}

// MARK: - 热力等级

/// 阅读活动强度五级，对齐 Android AppConstant.ReadTimeColorLevel
enum HeatmapLevel: Int, CaseIterable {
    case none, veryLess, less, more, veryMore

    var color: Color {
        switch self {
        case .none:     .heatmapNone
        case .veryLess: .brandLight
        case .less:     .brand
        case .more:     .brandDeep
        case .veryMore: .brandDarkest
        }
    }

    /// 无障碍标签文本
    var accessibilityText: String {
        switch self {
        case .none:     "无活动"
        case .veryLess: "少量活动"
        case .less:     "中等活动"
        case .more:     "较多活动"
        case .veryMore: "大量活动"
        }
    }

    /// 阅读时长 → 等级（阈值对齐 Android AppConstant:596-606）
    static func from(readSeconds: Int) -> HeatmapLevel {
        switch readSeconds {
        case 0:          .none
        case 1...1200:   .veryLess
        case 1201...2400: .less
        case 2401...3600: .more
        default:          .veryMore
        }
    }

    /// 打卡时长 → 等级（阈值与阅读时长一致，对齐 Android CHECK_IN 逻辑）
    static func from(checkInSeconds: Int) -> HeatmapLevel {
        from(readSeconds: checkInSeconds)
    }

    /// 笔记数量 → 等级（阈值对齐 Android AppConstant:608-616）
    static func from(noteCount: Int) -> HeatmapLevel {
        switch noteCount {
        case 0:        .none
        case 1...5:    .veryLess
        case 6...10:   .less
        case 11...20:  .more
        default:       .veryMore
        }
    }
}
