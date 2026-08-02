import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarSettings 提供可绑定设置状态，依赖 DesignTokens 提供视觉语义令牌
 * [OUTPUT]: 对外提供 ReadCalendarSettingsSheet，并提供同模块预布局复用的 ReadCalendarSettingsContent
 * [POS]: ReadCalendar 业务模块 Sheet，负责阅读事件筛选、交互反馈设置与自然内容高度回传
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历设置弹层，集中承接事件筛选与交互反馈开关。
struct ReadCalendarSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: ReadCalendarSettings
    let onContentHeightChange: (CGFloat) -> Void
    @State private var showInvalidCloseAlert = false

    var body: some View {
        ReadCalendarSettingsContent(settings: settings, onClose: handleClose)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { geometry in
                ceil(geometry.size.height)
            } action: { height in
                onContentHeightChange(height)
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

    /// 校验阅读行为规则并关闭设置；无有效规则时保留弹层并给出系统提示。
    private func handleClose() {
        guard settings.isReadBehaviorRuleValid else {
            showInvalidCloseAlert = true
            return
        }
        dismiss()
    }
}

/// 阅读日历设置的自然内容布局，供正式 Sheet 与呈现前高度测量共用。
struct ReadCalendarSettingsContent: View {
    @Bindable var settings: ReadCalendarSettings
    let onClose: (() -> Void)?

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

            if let onClose {
                closeButton(action: onClose)
            }
        }
    }

    private func closeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
