/**
 * [INPUT]: 接收页面已确认的当前序号与真实总数，不持有业务 Session
 * [OUTPUT]: 提供局部数字过渡、中性深色底托与合并朗读的回顾进度
 * [POS]: NoteReviewViewController 底部控件的页面私有 SwiftUI 内容
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import SwiftUI

/// UIKit 只提交已确认数值；观察范围限定为数字内容，不刷新阅读或手势表面。
@MainActor @Observable
final class NoteReviewProgressState {
    private(set) var current = 0
    private(set) var total = 0
    private var initialized = false

    /// 首次、隐藏及模式交接期间直接同步，连续数值更新接续当前动画而不排队。
    func update(current: Int, total: Int, animated: Bool) {
        guard !initialized || self.current != current || self.total != total else { return }
        let animation: Animation? = initialized && animated && !UIAccessibility.isReduceMotionEnabled
            ? .snappy(duration: 0.18, extraBounce: 0) : nil
        withTransaction(Transaction(animation: animation)) {
            self.current = current
            self.total = total
        }
        initialized = true
    }
}

/// 数字分别变化，分隔符保持静止；元数据排版与原 UIKit 标签同源。
struct NoteReviewProgressView: View {
    let state: NoteReviewProgressState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Text(state.current.formatted(.number.grouping(.never)))
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(state.current)))
            Text("/")
            Text(state.total.formatted(.number.grouping(.never)))
                .contentTransition(reduceMotion ? .identity : .numericText(value: Double(state.total)))
        }
        .font(Font(ReadingContentTypography.uiMetadataMedium))
        .monospacedDigit()
        .foregroundStyle(colorScheme == .dark ? AnyShapeStyle(NoteReviewCanvasAppearance.progressForeground) : AnyShapeStyle(.secondary))
        .padding(.horizontal, colorScheme == .dark ? Spacing.base : Spacing.none)
        .padding(.vertical, colorScheme == .dark ? Spacing.half : Spacing.none)
        .background {
            if colorScheme == .dark {
                Capsule().fill(NoteReviewCanvasAppearance.progressSurface)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("回顾进度")
        .accessibilityValue("第 \(state.current) 条，共 \(state.total) 条")
    }
}
