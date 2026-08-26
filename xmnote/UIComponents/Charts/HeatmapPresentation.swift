/**
 * [INPUT]: 依赖 HeatmapDay/HeatmapLevel/HeatmapStatisticsDataType/HeatmapBookState 纯值模型与 ReadingStatusPresentation
 * [OUTPUT]: 对外提供热力图领域值的展示文案、状态颜色与分段颜色映射
 * [POS]: UIComponents/Charts 的领域到视觉适配层，阻止 Domain 反向依赖 SwiftUI
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

extension HeatmapStatisticsDataType {
    var title: String {
        switch self {
        case .noteCount: "书摘"
        case .readingTime: "阅读"
        case .all: "全部"
        case .checkIn: "打卡"
        }
    }
}

extension HeatmapBookState {
    var color: Color {
        ReadingStatusPresentation.color(for: Int64(rawValue)) ?? .textHint
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

extension HeatmapLevel {
    var color: Color {
        HeatmapColorPalette.appDefault.color(for: self)
    }
}

extension HeatmapDay {
    /// 对齐 Android Mark.getColors：先绘制状态色，再按统计类型补充阅读量色。
    func segmentColors(for dataType: HeatmapStatisticsDataType) -> [Color] {
        segmentColors(for: dataType) { level in
            level.color
        }
    }

    /// 对齐 Android Mark.getColors，并允许视图层替换阅读量色阶；书籍状态仍使用固定语义色。
    func segmentColors(
        for dataType: HeatmapStatisticsDataType,
        amountColor: (HeatmapLevel) -> Color
    ) -> [Color] {
        let stateColors = HeatmapBookState.renderOrder.compactMap { state in
            bookStates.contains(state) ? state.color : nil
        }

        let amountColor = amountColor(amountLevel(for: dataType))
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
