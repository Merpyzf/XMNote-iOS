import CoreGraphics
import Foundation

/**
 * [INPUT]: 依赖 ReadingDashboardSnapshot 领域模型与 ReadDurationFormatter 时长文案能力，依赖 CoreGraphics 提供趋势柱图比例映射
 * [OUTPUT]: 对外提供 ReadingDashboardFormatting（首页文案格式化帮助）与 ReadingDashboardMetricValueDisplay（趋势值分段描述）
 * [POS]: ViewModels/Reading 的首页展示辅助工具，被 ReadingDashboardViewModel 与页面私有组件复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 首页趋势总值的分段显示模型，避免视图层再解析“数字 + 单位”字符串。
struct ReadingDashboardMetricValueDisplay: Equatable {
    /// Segment 标记单段文本及其角色，供视图按品牌数字/系统单位分别渲染。
    struct Segment: Equatable {
        /// Role 区分品牌数字与单位文本，保证同一主值里能做差异化排版。
        enum Role: Equatable {
            case number
            case unit
        }

        let text: String
        let role: Role
    }

    let segments: [Segment]
}

/// ReadingDashboardFormatting 统一承接首页仪表盘的文案压缩、趋势值拆段与柱图可视化映射。
enum ReadingDashboardFormatting {
    private enum TrendBarScale {
        static let shortRangeUpperBound: CGFloat = 0.18
        static let shortRangeGamma: CGFloat = 0.78
        static let minVisualRatioFloor: CGFloat = 0.08
        static let minVisualRatioCeiling: CGFloat = 0.14
        static let minVisualHeight: CGFloat = 4
    }

    /// 把秒数格式化为首页环形卡中使用的 `MM:SS` / `H:MM:SS` 文案。
    static func clockText(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// 为今日阅读卡压缩主值长度，超过 1 小时时改为 `H:MM`，避免品牌数字撑爆弧环中轴。
    static func dailyGoalValueText(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d", hours, minutes)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// 生成年度目标文案，对齐 Android 的“再读 X 本，即可完成今年目标”语义。
    static func yearSummarySubtitle(summary: ReadingYearSummary) -> String {
        if summary.isTargetAchieved {
            return "已完成今年阅读目标"
        }
        return "再读 \(summary.remainingCount) 本，即可完成今年目标"
    }

    /// 生成首页趋势卡的分段值，供数字与单位使用不同字体层级。
    static func metricValueDisplay(metric: ReadingTrendMetric) -> ReadingDashboardMetricValueDisplay {
        switch metric.kind {
        case .readingDuration:
            return durationDisplay(seconds: metric.totalValue)
        case .noteCount:
            return countDisplay(value: metric.totalValue, unit: " 条")
        case .readDoneCount:
            return countDisplay(value: metric.totalValue, unit: " 本")
        }
    }

    /// 按图表高度计算各柱子的显示比例，保留 Android 零值语义并增强极小非零值可见性。
    static func displayedBarRatios(points: [ReadingTrendMetric.Point], chartHeight: CGFloat) -> [CGFloat] {
        let maxValue = points.map(\.value).max() ?? 0
        return points.map { point in
            displayedBarRatio(value: point.value, maxValue: maxValue, chartHeight: chartHeight)
        }
    }

    /// 首页进度百分比统一保留 1 位小数。
    static func percentText(_ value: Double?) -> String {
        guard let value else { return "暂无进度" }
        return String(format: "%.1f%%", value)
    }

    /// 把阅读时长拆成“数字 / 单位”交替分段，对齐在读页趋势卡的排版需求。
    static func durationDisplay(seconds: Int) -> ReadingDashboardMetricValueDisplay {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60

        if hours > 0 {
            var segments = [
                ReadingDashboardMetricValueDisplay.Segment(text: "\(hours)", role: .number),
                ReadingDashboardMetricValueDisplay.Segment(text: " 小时", role: .unit)
            ]
            if minutes > 0 {
                segments.append(.init(text: "\(minutes)", role: .number))
                segments.append(.init(text: " 分钟", role: .unit))
            }
            return ReadingDashboardMetricValueDisplay(segments: segments)
        }

        if minutes > 0 {
            var segments = [
                ReadingDashboardMetricValueDisplay.Segment(text: "\(minutes)", role: .number),
                ReadingDashboardMetricValueDisplay.Segment(text: " 分钟", role: .unit)
            ]
            if secs > 0 {
                segments.append(.init(text: "\(secs)", role: .number))
                segments.append(.init(text: " 秒", role: .unit))
            }
            return ReadingDashboardMetricValueDisplay(segments: segments)
        }

        return ReadingDashboardMetricValueDisplay(
            segments: [
                .init(text: "\(secs)", role: .number),
                .init(text: " 秒", role: .unit)
            ]
        )
    }

    /// 把计数值拆成一段数字和一段单位，供趋势卡保持统一版式。
    static func countDisplay(value: Int, unit: String) -> ReadingDashboardMetricValueDisplay {
        ReadingDashboardMetricValueDisplay(
            segments: [
                .init(text: "\(max(0, value))", role: .number),
                .init(text: unit, role: .unit)
            ]
        )
    }

    /// 将原始数值映射到趋势卡柱高比例，避免极差场景下的小值完全消失。
    static func displayedBarRatio(value: Int, maxValue: Int, chartHeight: CGFloat) -> CGFloat {
        let clampedValue = max(0, value)
        guard clampedValue > 0, maxValue > 0 else { return 0 }

        let rawRatio = min(1, max(0, CGFloat(clampedValue) / CGFloat(maxValue)))
        if rawRatio >= TrendBarScale.shortRangeUpperBound {
            return rawRatio
        }

        let safeChartHeight = max(1, chartHeight)
        let minVisualRatio = min(
            TrendBarScale.minVisualRatioCeiling,
            max(
                TrendBarScale.minVisualRatioFloor,
                TrendBarScale.minVisualHeight / safeChartHeight
            )
        )
        let t = rawRatio / TrendBarScale.shortRangeUpperBound
        let eased = CGFloat(pow(Double(t), Double(TrendBarScale.shortRangeGamma)))
        let mapped = minVisualRatio + (TrendBarScale.shortRangeUpperBound - minVisualRatio) * eased
        return min(TrendBarScale.shortRangeUpperBound, max(minVisualRatio, mapped))
    }
}
