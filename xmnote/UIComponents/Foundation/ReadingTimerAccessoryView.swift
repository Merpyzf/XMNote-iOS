import Foundation
import SwiftUI

/**
 * [INPUT]: 依赖 ReadingTimerSession 领域快照、XMBookCover 与 DesignTokens，接收打开完整页、暂停/继续回调及显式布局模式
 * [OUTPUT]: 对外提供 ReadingTimerAccessoryView，在系统 TabView Bottom Accessory 的展开态、收缩态及 UIKit 来源宿主中投影全局计时
 * [POS]: UIComponents/Foundation 跨 Tab 复用计时状态条，只负责展示与高频可逆操作，不持有业务状态或计时生命周期
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 决定计时条沿用系统 Bottom Accessory 环境，或在 UIKit Zoom 来源宿主中显式还原指定形态。
enum ReadingTimerAccessoryLayoutMode {
    case automatic
    case expanded
    case inline
}

/// 系统 TabView 底部附属区中的阅读计时状态条，视觉时间由数据库快照和当前时间实时推导。
struct ReadingTimerAccessoryView: View {
    let session: ReadingTimerSession
    let isWriting: Bool
    let onOpen: () -> Void
    let onTogglePlayback: () -> Void
    var layoutMode: ReadingTimerAccessoryLayoutMode = .automatic

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let seconds = displaySeconds(at: timeline.date)

            if isInline {
                inlineContent(seconds: seconds)
            } else {
                expandedContent(seconds: seconds)
            }
        }
    }

    private var isInline: Bool {
        switch layoutMode {
        case .automatic:
            return placement == .inline
        case .expanded:
            return false
        case .inline:
            return true
        }
    }

    private func expandedContent(seconds: Int64) -> some View {
        HStack(spacing: Spacing.base) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.tight) {
                    accessoryBookCover(
                        height: ReadingTimerAccessoryLayout.expandedCoverHeight,
                        cornerRadius: CornerRadius.inlaySmall
                    )

                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text(session.book.name)
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        expandedStatus(seconds: seconds)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(openAccessibilityLabel)

            trailingControl
        }
        .padding(.leading, ReadingTimerAccessoryLayout.expandedLeadingInset)
        .padding(.trailing, ReadingTimerAccessoryLayout.expandedTrailingInset)
        .padding(.vertical, Spacing.half)
        .frame(maxWidth: .infinity)
    }

    private func inlineContent(seconds: Int64) -> some View {
        HStack(spacing: Spacing.cozy) {
            Button(action: onOpen) {
                HStack(spacing: Spacing.cozy) {
                    accessoryBookCover(
                        height: ReadingTimerAccessoryLayout.inlineCoverHeight,
                        cornerRadius: CornerRadius.inlayTiny
                    )

                    ViewThatFits(in: .vertical) {
                        inlineTwoLineInformation(seconds: seconds)
                            .fixedSize(horizontal: false, vertical: true)
                        inlineSingleLineInformation(seconds: seconds)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: Spacing.actionReserved,
                    maxHeight: Spacing.actionReserved,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(openAccessibilityLabel)

            trailingControl
        }
        .padding(.leading, ReadingTimerAccessoryLayout.inlineLeadingInset)
        .padding(.trailing, ReadingTimerAccessoryLayout.inlineTrailingInset)
        .frame(maxWidth: .infinity)
    }

    private func inlineTwoLineInformation(seconds: Int64) -> some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            Text(session.book.name)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            inlineStatus(seconds: seconds)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inlineSingleLineInformation(seconds: Int64) -> some View {
        HStack(spacing: Spacing.compact) {
            Text(session.book.name)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            inlineCompactStatus(seconds: seconds)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func inlineStatus(seconds: Int64) -> some View {
        switch session.status {
        case .running:
            inlineTimedStatus(
                session.countdownSeconds > 0 ? "剩余" : "阅读中 ·",
                seconds: seconds
            )
        case .paused:
            inlineTimedStatus(
                session.countdownSeconds > 0 ? "已暂停 · 剩余" : "已暂停 ·",
                seconds: seconds
            )
        case .stoppedPendingSave:
            Text("已结束 · 待保存")
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        case .finished:
            Text("已结束")
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    private func inlineTimedStatus(_ status: String, seconds: Int64) -> some View {
        HStack(spacing: Spacing.compact) {
            Text(status)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)

            animatedTime(
                seconds: seconds,
                minimumScaleFactor: ReadingTimerAccessoryLayout.inlineTimeMinimumScaleFactor
            )
            .font(AppTypography.caption2Medium)
            .foregroundStyle(Color.textPrimary)
            .layoutPriority(1)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func inlineCompactStatus(seconds: Int64) -> some View {
        switch session.status {
        case .running, .paused:
            animatedTime(
                seconds: seconds,
                minimumScaleFactor: ReadingTimerAccessoryLayout.inlineTimeMinimumScaleFactor
            )
            .font(AppTypography.caption2Medium)
            .foregroundStyle(Color.textPrimary)
        case .stoppedPendingSave:
            Text("待保存")
                .font(AppTypography.caption2Medium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        case .finished:
            Text("已结束")
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if session.status == .stoppedPendingSave {
            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("保存阅读记录")
        } else {
            Button(action: onTogglePlayback) {
                Image(systemName: session.status == .running ? "pause.fill" : "play.fill")
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWriting)
            .accessibilityLabel(session.status == .running ? "暂停阅读计时" : "继续阅读计时")
        }
    }

    @ViewBuilder
    private func expandedStatus(seconds: Int64) -> some View {
        switch session.status {
        case .running:
            HStack(spacing: Spacing.compact) {
                Text(session.countdownSeconds > 0 ? "剩余" : "正在阅读 ·")
                animatedTime(seconds: seconds)
            }
        case .paused:
            HStack(spacing: Spacing.compact) {
                Text("已暂停 ·")
                animatedTime(seconds: seconds)
            }
        case .stoppedPendingSave:
            Text("已结束 · 待保存")
        case .finished:
            Text("已结束")
        }
    }

    private func animatedTime(seconds: Int64, minimumScaleFactor: CGFloat = 1) -> some View {
        Text(digitalTime(seconds: seconds))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(minimumScaleFactor)
            .contentTransition(.numericText(value: Double(seconds)))
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: seconds)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                }
            }
            .accessibilityHidden(true)
    }

    private func accessoryBookCover(height: CGFloat, cornerRadius: CGFloat) -> some View {
        XMBookCover.fixedHeight(
            height,
            urlString: session.book.coverURL,
            cornerRadius: cornerRadius,
            border: .init(
                color: Color.surfaceBorderSubtle,
                width: CardStyle.borderWidth
            ),
            placeholderIconSize: .small,
            priority: .low,
            surfaceStyle: .plain
        )
        .accessibilityHidden(true)
    }

    private func displaySeconds(at date: Date) -> Int64 {
        let elapsed: Int64
        if session.status == .running {
            let anchor = session.interruptTime ?? session.updatedDate ?? session.startTime ?? date
            elapsed = session.elapsedSeconds + max(0, Int64(date.timeIntervalSince(anchor)))
        } else {
            elapsed = session.elapsedSeconds
        }

        guard session.countdownSeconds > 0 else {
            return max(0, elapsed)
        }
        return max(0, session.countdownSeconds - min(max(0, elapsed), session.countdownSeconds))
    }

    private var openAccessibilityLabel: String {
        let status: String
        switch session.status {
        case .running:
            status = session.countdownSeconds > 0 ? "倒计时进行中" : "正在阅读"
        case .paused:
            status = "计时已暂停"
        case .stoppedPendingSave:
            status = "计时已结束，记录待保存"
        case .finished:
            status = "计时已结束"
        }
        return "打开《\(session.book.name)》阅读计时，\(status)"
    }

    private func digitalTime(seconds: Int64) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let seconds = clamped % 60
        if hours > 0 {
            return String(format: "%02lld:%02lld:%02lld", hours, minutes, seconds)
        }
        return String(format: "%02lld:%02lld", minutes, seconds)
    }
}

/// 全局计时状态条的组件几何；点击热区仍统一使用 44pt 设计令牌。
private enum ReadingTimerAccessoryLayout {
    static let expandedCoverHeight: CGFloat = 36
    static let inlineCoverHeight: CGFloat = 28
    static let expandedLeadingInset: CGFloat = Spacing.screenEdge
    static let expandedTrailingInset: CGFloat = Spacing.cozy
    static let inlineLeadingInset: CGFloat = Spacing.comfortable
    static let inlineTrailingInset: CGFloat = Spacing.half
    static let inlineTimeMinimumScaleFactor: CGFloat = 0.82
}
