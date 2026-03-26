import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarSettings 提供可绑定设置状态，依赖 DesignTokens 提供视觉语义令牌
 * [OUTPUT]: 对外提供 ReadCalendarSettingsSheet（阅读日历设置弹层）
 * [POS]: ReadCalendar 业务模块 Sheet，负责阅读事件筛选与交互反馈设置
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历设置弹层，集中承接事件筛选与交互反馈开关。
struct ReadCalendarSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: ReadCalendarSettings
    @State private var showInvalidCloseAlert = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: Spacing.double) {
                titleSection
                    .padding(.trailing, Spacing.actionReserved)
                eventTogglesSection
                feedbackSection
                dayEventCountSection
            }
            .padding(Spacing.double)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height)
                }
            )

            closeButton
        }
        .interactiveDismissDisabled(!settings.isReadBehaviorRuleValid)
        .xmSystemAlert(
            isPresented: $showInvalidCloseAlert,
            descriptor: XMSystemAlertDescriptor(
                title: "无法关闭设置",
                message: "判定阅读行为的规则至少要选一个",
                actions: [
                    XMSystemAlertAction(title: "我知道了", role: .cancel) { }
                ]
            )
        )
    }

    private var closeButton: some View {
        Button {
            guard settings.isReadBehaviorRuleValid else {
                showInvalidCloseAlert = true
                return
            }
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(.top, Spacing.double)
        .padding(.trailing, Spacing.double)
    }

    private var titleSection: some View {
        Text("阅读日历设置")
            .font(AppTypography.title3Semibold)
    }

    private var eventTogglesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("阅读事件")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textSecondary)

            Toggle("阅读计时（含补录）", isOn: Binding(
                get: { !settings.excludeReadTiming },
                set: { settings.excludeReadTiming = !$0 }
            ))

            Toggle("笔记记录", isOn: Binding(
                get: { !settings.excludeNoteRecord },
                set: { settings.excludeNoteRecord = !$0 }
            ))

            Toggle("阅读打卡", isOn: Binding(
                get: { !settings.excludeCheckIn },
                set: { settings.excludeCheckIn = !$0 }
            ))

            if !settings.isReadBehaviorRuleValid {
                Text("判定阅读行为的规则至少要选一个")
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.feedbackError)
            }
        }
        .tint(.brand)
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("交互反馈")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textSecondary)

            Toggle("触感反馈", isOn: $settings.isHapticsEnabled)
            Toggle("连续阅读提示", isOn: $settings.isStreakHintEnabled)
        }
        .tint(.brand)
    }

    private var dayEventCountSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("每日展示书籍数量")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textSecondary)

            HStack(spacing: Spacing.half) {
                ForEach(Array(ReadCalendarSettings.dayEventCountRange), id: \.self) { count in
                    dayCountChip(count, isSelected: count == settings.dayEventCount)
                }
            }
        }
    }

    private func dayCountChip(_ count: Int, isSelected: Bool) -> some View {
        Button {
            withAnimation(.snappy) { settings.dayEventCount = count }
        } label: {
            Text("\(count)")
                .font(AppTypography.semantic(.subheadline, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : Color.textPrimary)
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.brand : Color.controlFillSecondary, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) 本")
    }
}
