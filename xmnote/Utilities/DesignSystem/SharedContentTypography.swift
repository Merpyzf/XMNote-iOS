/**
 * [INPUT]: 依赖 AppTypography、SemanticTypography、BrandTypography、SwiftUI 与 UIKit
 * [OUTPUT]: 对外提供现有书架、书摘、阅读日历与时间线的组合排版 token
 * [POS]: Utilities/DesignSystem 的共享内容排版层；DS5 将单业务 owner 继续下沉到对应模块
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

enum BookshelfTypography {
    static let topSelected: Font = AppTypography.fixed(
        baseSize: 20,
        relativeTo: .title3,
        weight: .semibold,
        minimumPointSize: 20
    )
    static let topUnselected: Font = AppTypography.fixed(
        baseSize: 18,
        relativeTo: .title3,
        weight: .medium,
        minimumPointSize: 18
    )
    static let searchField: Font = AppTypography.fixed(
        baseSize: 15,
        relativeTo: .body,
        minimumPointSize: 15
    )
    static let uiSearchField: UIFont = AppTypography.uiFixed(
        baseSize: 15,
        textStyle: .body,
        minimumPointSize: 15
    )
    static let gridTitle: Font = AppTypography.fixed(
        baseSize: 12,
        relativeTo: .caption,
        weight: .medium,
        minimumPointSize: 12
    )
    static let gridSubtitle: Font = AppTypography.fixed(
        baseSize: 11,
        relativeTo: .caption2,
        minimumPointSize: 11
    )

    static let uiGridTitle: UIFont = AppTypography.uiFixed(
        baseSize: 12,
        textStyle: .caption1,
        weight: .medium,
        minimumPointSize: 12
    )
    static let uiGridSubtitle: UIFont = AppTypography.uiFixed(
        baseSize: 11,
        textStyle: .caption2,
        minimumPointSize: 11
    )
}

/// 书摘列表的阅读排版令牌，统一正文、想法与辅助信息的字号和行距。
enum NoteExcerptTypography {
    static var body: Font {
        AppTypography.fixed(
            baseSize: 16,
            relativeTo: .body,
            minimumPointSize: 16
        )
    }
    static let bodyLineSpacing: CGFloat = 7
    static var uiBody: UIFont {
        AppTypography.uiFixed(
            baseSize: 16,
            textStyle: .body,
            minimumPointSize: 16
        )
    }
    static var idea: Font {
        AppTypography.fixed(
            baseSize: 14,
            relativeTo: .subheadline,
            minimumPointSize: 14
        )
    }
    static let ideaLineSpacing: CGFloat = 5
    static var uiIdea: UIFont {
        AppTypography.uiFixed(
            baseSize: 14,
            textStyle: .subheadline,
            minimumPointSize: 14
        )
    }
    static var footer: Font {
        AppTypography.fixed(
            baseSize: 11,
            relativeTo: .caption2,
            minimumPointSize: 11
        )
    }
}

/// 阅读日历字体令牌，集中维护日期相关文本层级。
enum ReadCalendarTypography {
    private static let denseGridMaximumTraits = UITraitCollection(
        preferredContentSizeCategory: .extraExtraExtraLarge
    )

    static let topControlTitleFont: Font = AppTypography.fixed(baseSize: 18, relativeTo: .headline, weight: .semibold, design: .rounded)
    static let weekdayHeaderFont: Font = AppTypography.fixed(baseSize: 13, relativeTo: .caption, weight: .medium, design: .rounded)
    static let weekdayHeaderAccessibilityFont: Font = SemanticTypography.font(
        baseSize: 13,
        relativeTo: .caption,
        weight: .medium,
        design: .rounded,
        minimumPointSize: 13,
        compatibleWith: denseGridMaximumTraits
    )
    static let monthGridDayNumberFont: Font = AppTypography.fixed(baseSize: 13, relativeTo: .caption, weight: .medium, design: .rounded)
    static let monthGridDayNumberAccessibilityFont: Font = SemanticTypography.font(
        baseSize: 13,
        relativeTo: .caption,
        weight: .medium,
        design: .rounded,
        minimumPointSize: 13,
        compatibleWith: denseGridMaximumTraits
    )
    static let monthGridDayNumberSelectedFont: Font = AppTypography.fixed(baseSize: 13, relativeTo: .caption, weight: .semibold, design: .rounded)
    static let monthGridDayNumberSelectedAccessibilityFont: Font = SemanticTypography.font(
        baseSize: 13,
        relativeTo: .caption,
        weight: .semibold,
        design: .rounded,
        minimumPointSize: 13,
        compatibleWith: denseGridMaximumTraits
    )
    static let monthGridEventTitleFont: Font = AppTypography.fixed(baseSize: 10, relativeTo: .caption2, weight: .semibold, design: .rounded, minimumPointSize: 10)
    static let monthGridEventTitleAccessibilityFont: Font = SemanticTypography.font(
        baseSize: 10,
        relativeTo: .caption2,
        weight: .semibold,
        design: .rounded,
        minimumPointSize: 10,
        compatibleWith: denseGridMaximumTraits
    )
    static let monthGridOverflowFont: Font = AppTypography.fixed(baseSize: 10, relativeTo: .caption2, weight: .medium, design: .rounded, minimumPointSize: 10)
    static let monthGridOverflowAccessibilityFont: Font = SemanticTypography.font(
        baseSize: 10,
        relativeTo: .caption2,
        weight: .medium,
        design: .rounded,
        minimumPointSize: 10,
        compatibleWith: denseGridMaximumTraits
    )
    static let selectedDayTitleFont: Font = AppTypography.subheadlineSemibold
    static let selectedDayFactsFont: Font = AppTypography.caption
    static let selectedDayActionFont: Font = AppTypography.subheadlineSemibold
    static let yearHeatmapMonthTitleFont: Font = AppTypography.semantic(.callout, weight: .semibold)
}

/// 阅读日历统计排版令牌，统一指标、洞察、排行与树图中的文本层级。
enum ReadCalendarSummaryTypography {
    static let sectionTitle: Font = AppTypography.headlineSemibold
    static let metricTitle: Font = AppTypography.captionMedium
    static let metricNumber: Font = AppTypography.title3Semibold
    static let metricUnit: Font = AppTypography.caption2Medium
    static let metricText: Font = AppTypography.subheadlineSemibold
    static let metricSubtitle: Font = AppTypography.caption
    static let insightLabel: Font = AppTypography.caption2Semibold
    static let insightMeta: Font = AppTypography.footnote
    static let insightNumber: Font = AppTypography.subheadlineSemibold
    static let insightUnit: Font = AppTypography.captionMedium
    static let rankingTitle: Font = AppTypography.captionMedium
    static let rankingNumber: Font = AppTypography.captionMedium
    static let rankingUnit: Font = AppTypography.caption2Medium
    static let treemapMonth: Font = AppTypography.captionSemibold
    static let treemapPercent: Font = AppTypography.caption2Semibold
    static let treemapDetail: Font = AppTypography.caption2
}

// MARK: - Timeline Calendar Style

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
    static let connectorDotColor: Color = .brand
    static let connectorLineColor: Color = Color.textHint.opacity(connectorLineOpacity)
    static let eventTimeColor: Color = .textHint

    static let monthNumberColor: Color = .textPrimary
    static let monthUnitColor: Color = .textSecondary
    static let relativeNumberColor: Color = .textPrimary
    static let relativeUnitColor: Color = .textSecondary
    static let weekdayTextColor: Color = .textHint
    static let progressTrackColor: Color = Color.brand.opacity(0.18)

    // 粘性日期头部：品牌衬线体提升分组锚点辨识度，与顶部日历标题建立字体家族呼应
    static let sectionDateFont: Font = AppTypography.brandDisplay(size: 18, relativeTo: .subheadline)
    static let sectionYearFont: Font = AppTypography.brandDisplay(size: 18, relativeTo: .subheadline)
    static let sectionDateVerticalTrim = AppTypography.brandTrim(size: 18, textStyle: .subheadline)
    static let sectionFilterFont: Font = AppTypography.fixed(baseSize: 12, relativeTo: .caption, weight: .medium, design: .rounded)
}

// MARK: - Timeline Typography

/// 时间线卡片正文字体令牌，确保富文本密度在不同卡片中保持一致。
enum TimelineTypography {
    static let eventRichTextBaseFont: UIFont = AppTypography.uiSemantic(.callout)
    static let eventRichTextLineSpacing: CGFloat = 4
    static let eventFallbackTextFont: Font = AppTypography.callout
}
