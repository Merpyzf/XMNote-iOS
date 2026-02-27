import Foundation
import SwiftUI

/**
 * [INPUT]: 依赖 DesignTokens 的 Color 语义扩展（heatmapNone/brandLight/brand/brandDeep/brandDarkest）
 * [OUTPUT]: 对外提供 HeatmapDay（单日热力数据，含打卡时长）、HeatmapLevel（五级强度枚举）
 * [POS]: Domain 层热力图领域模型，供 StatisticsRepository 产出、HeatmapChart 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - 单日热力数据

struct HeatmapDay: Identifiable {
    let id: Date          // 日历日期（零时零分零秒）
    let readSeconds: Int  // 阅读秒数
    let noteCount: Int    // 书摘数量
    let checkInCount: Int // 打卡次数
    let checkInSeconds: Int // 打卡时长（秒）

    /// 综合等级取阅读时长/笔记数/打卡时长三者最大值
    var level: HeatmapLevel {
        let readLevel = HeatmapLevel.from(readSeconds: readSeconds)
        let noteLevel = HeatmapLevel.from(noteCount: noteCount)
        let checkInLevel = HeatmapLevel.from(checkInSeconds: checkInSeconds)
        let maxRaw = max(max(readLevel.rawValue, noteLevel.rawValue), checkInLevel.rawValue)
        return HeatmapLevel(rawValue: maxRaw) ?? .none
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
