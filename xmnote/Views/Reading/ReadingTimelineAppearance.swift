/**
 * [INPUT]: 依赖 AppTypography、语义颜色、圆角令牌、SwiftUI 与 UIKit
 * [OUTPUT]: 对 Reading feature 提供时间线日历、事件卡片与富文本的组合视觉配置
 * [POS]: Views/Reading 的时间线视觉 owner，供正式时间线与阅读日历记录列表共同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 时间线日历样式令牌，集中维护字体、尺寸与颜色语义，避免页面内硬编码。
enum TimelineCalendarStyle {
    static let monthNumberFont: Font = AppTypography.brandDisplay(size: 20, relativeTo: .title3)
    static let monthNumberVerticalTrim = AppTypography.brandTrim(size: 20, textStyle: .title3)
    static let monthUnitFont: Font = AppTypography.fixed(baseSize: 10, relativeTo: .caption2, weight: .medium, design: .rounded)
    static let actionButtonFont: Font = AppTypography.fixed(baseSize: 13, relativeTo: .caption, weight: .semibold, design: .rounded)
    static let relativeNumberFont: Font = AppTypography.brandDisplay(size: 16, relativeTo: .body)
    static let relativeNumberVerticalTrim = AppTypography.brandTrim(size: 16, textStyle: .body)
    static let relativeUnitFont: Font = AppTypography.fixed(baseSize: 10, relativeTo: .caption2, design: .rounded)
    static let weekdayFont: Font = AppTypography.fixed(baseSize: 11, relativeTo: .caption2, weight: .medium, design: .rounded)
    static let categoryChipFont: Font = AppTypography.fixed(baseSize: 12, relativeTo: .caption, weight: .medium, design: .rounded)
    static let dayNumberFont: Font = AppTypography.brandDisplay(size: 13, relativeTo: .body)

    // 时间线圆角语义：顶部日历背景卡对齐热力图卡片，事件卡统一主内容卡角色。
    static let panelCornerRadius: CGFloat = CornerRadius.containerLarge
    static let eventCardCornerRadius: CGFloat = CornerRadius.blockLarge

    static let dayCellSize: CGFloat = 32
    static let selectedCircleSize: CGFloat = 30
    static let progressRingSize: CGFloat = 28
    static let progressRingLineWidth: CGFloat = 1.6
    static let markerDotSize: CGFloat = 4
    static let markerDotOffsetY: CGFloat = 12
    static let connectorDotSize: CGFloat = 8
    static let connectorLineWidth: CGFloat = 1.5
    static let connectorDashPattern: [CGFloat] = [4, 3]
    static let connectorLineOpacity: Double = 0.35
    static let connectorDotColor: Color = .selectionAccent
    static let connectorLineColor: Color = Color.textHint.opacity(connectorLineOpacity)
    static let eventTimeColor: Color = .textHint

    static let monthNumberColor: Color = .textPrimary
    static let monthUnitColor: Color = .textSecondary
    static let relativeNumberColor: Color = .textPrimary
    static let relativeUnitColor: Color = .textSecondary
    static let weekdayTextColor: Color = .textHint
    static let progressTrackColor: Color = Color.selectionAccent.opacity(0.18)

    // 粘性日期头部：品牌衬线体提升分组锚点辨识度，与顶部日历标题建立字体家族呼应。
    static let sectionDateFont: Font = AppTypography.brandDisplay(size: 18, relativeTo: .subheadline)
    static let sectionYearFont: Font = AppTypography.brandDisplay(size: 18, relativeTo: .subheadline)
    static let sectionDateVerticalTrim = AppTypography.brandTrim(size: 18, textStyle: .subheadline)
    static let sectionFilterFont: Font = AppTypography.fixed(baseSize: 12, relativeTo: .caption, weight: .medium, design: .rounded)
}

/// 时间线卡片正文字体令牌，确保富文本密度在不同卡片中保持一致。
enum TimelineTypography {
    static let eventRichTextBaseFont: UIFont = AppTypography.uiSemantic(.callout)
    static let eventRichTextLineSpacing: CGFloat = 4
    static let eventFallbackTextFont: Font = AppTypography.callout
}
