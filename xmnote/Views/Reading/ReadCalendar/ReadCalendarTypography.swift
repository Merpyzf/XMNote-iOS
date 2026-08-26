/**
 * [INPUT]: 依赖 AppTypography、SemanticTypography、SwiftUI 与 UIKit，承接阅读日历的网格密度与 Dynamic Type 约束
 * [OUTPUT]: 对外提供 ReadCalendarTextStyle，统一日历顶部、网格、选中日与年度热力图排版
 * [POS]: Views/Reading/ReadCalendar 的 feature 排版 owner，密集日历规则不向全局设计系统泄漏
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 集中持有阅读日历专属的文本层级，并为密集七列网格保留受控的大字体封顶。
enum ReadCalendarTextStyle {
    private static let denseGridMaximumTraits = UITraitCollection(
        preferredContentSizeCategory: .extraExtraExtraLarge
    )

    static let topControlTitleFont: Font = AppTypography.fixed(
        baseSize: 18,
        relativeTo: .headline,
        weight: .semibold,
        design: .rounded
    )
    static let weekdayHeaderFont: Font = AppTypography.fixed(
        baseSize: 13,
        relativeTo: .caption,
        weight: .medium,
        design: .rounded
    )
    static let weekdayHeaderAccessibilityFont: Font = SemanticTypography.font(
        baseSize: 13,
        relativeTo: .caption,
        weight: .medium,
        design: .rounded,
        minimumPointSize: 13,
        compatibleWith: denseGridMaximumTraits
    )
    static let monthGridDayNumberFont: Font = AppTypography.fixed(
        baseSize: 13,
        relativeTo: .caption,
        weight: .medium,
        design: .rounded
    )
    static let monthGridDayNumberAccessibilityFont: Font = SemanticTypography.font(
        baseSize: 13,
        relativeTo: .caption,
        weight: .medium,
        design: .rounded,
        minimumPointSize: 13,
        compatibleWith: denseGridMaximumTraits
    )
    static let monthGridDayNumberSelectedFont: Font = AppTypography.fixed(
        baseSize: 13,
        relativeTo: .caption,
        weight: .semibold,
        design: .rounded
    )
    static let monthGridDayNumberSelectedAccessibilityFont: Font = SemanticTypography.font(
        baseSize: 13,
        relativeTo: .caption,
        weight: .semibold,
        design: .rounded,
        minimumPointSize: 13,
        compatibleWith: denseGridMaximumTraits
    )
    static let monthGridEventTitleFont: Font = AppTypography.fixed(
        baseSize: 10,
        relativeTo: .caption2,
        weight: .semibold,
        design: .rounded,
        minimumPointSize: 10
    )
    static let monthGridEventTitleAccessibilityFont: Font = SemanticTypography.font(
        baseSize: 10,
        relativeTo: .caption2,
        weight: .semibold,
        design: .rounded,
        minimumPointSize: 10,
        compatibleWith: denseGridMaximumTraits
    )
    static let monthGridOverflowFont: Font = AppTypography.fixed(
        baseSize: 10,
        relativeTo: .caption2,
        weight: .medium,
        design: .rounded,
        minimumPointSize: 10
    )
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
    static let summarySectionTitleFont: Font = AppTypography.headlineSemibold
}
