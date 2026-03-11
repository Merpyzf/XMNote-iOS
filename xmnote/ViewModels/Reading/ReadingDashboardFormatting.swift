import Foundation

/**
 * [INPUT]: 依赖 ReadingDashboardSnapshot 领域模型与 ReadDurationFormatter 时长文案能力
 * [OUTPUT]: 对外提供 ReadingDashboardFormatting（首页文案格式化帮助）
 * [POS]: ViewModels/Reading 的首页展示辅助工具，被 ReadingDashboardViewModel 与页面私有组件复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

enum ReadingDashboardFormatting {
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

    /// 生成年度目标文案，对齐 Android 的“再读 X 本，即可完成今年目标”语义。
    static func yearSummarySubtitle(summary: ReadingYearSummary) -> String {
        if summary.isTargetAchieved {
            return "已完成今年阅读目标"
        }
        return "再读 \(summary.remainingCount) 本，即可完成今年目标"
    }

    /// 将整数总值按指标类型转为首页卡片展示文案。
    static func totalValueText(metric: ReadingTrendMetric) -> String {
        switch metric.kind {
        case .readingDuration:
            return ReadDurationFormatter.format(seconds: Int64(metric.totalValue))
        case .noteCount:
            return "\(metric.totalValue)条"
        case .readDoneCount:
            return "\(metric.totalValue)本"
        }
    }

    /// 首页进度百分比统一保留 1 位小数。
    static func percentText(_ value: Double?) -> String {
        guard let value else { return "暂无进度" }
        return String(format: "%.1f%%", value)
    }
}
