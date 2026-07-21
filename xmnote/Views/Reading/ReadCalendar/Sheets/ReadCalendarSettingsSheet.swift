import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarSettings 提供可绑定设置状态，依赖 DesignTokens 提供视觉语义令牌
 * [OUTPUT]: 对外提供 ReadCalendarSettingsSheet（阅读日历设置弹层）
 * [POS]: ReadCalendar 业务模块 Sheet，负责六类事件源、读完标记与交互反馈设置
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历设置弹层，集中承接事件筛选与交互反馈开关。
struct ReadCalendarSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: ReadCalendarSettings
    @State private var showInvalidCloseAlert = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.double) {
                    titleSection
                        .padding(.trailing, Spacing.actionReserved)
                    eventTogglesSection
                    doneMarkerSection
                    feedbackSection
                    dayEventCountSection
                }
                .padding(Spacing.double)
            }

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

            Toggle("书摘", isOn: Binding(
                get: { !settings.excludeNote },
                set: { settings.excludeNote = !$0 }
            ))

            Toggle("相关内容", isOn: Binding(
                get: { !settings.excludeRelevant },
                set: { settings.excludeRelevant = !$0 }
            ))

            Toggle("书评", isOn: Binding(
                get: { !settings.excludeReview },
                set: { settings.excludeReview = !$0 }
            ))

            Toggle("读完记录", isOn: Binding(
                get: { !settings.excludeReadDone },
                set: { settings.excludeReadDone = !$0 }
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

    private var doneMarkerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("读完标记")
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textSecondary)

            Picker("读完标记样式", selection: $settings.doneMarkerStyle) {
                ForEach(ReadCalendarDoneMarkerStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)

            if settings.doneMarkerStyle == .emoji {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.half), count: 6),
                    spacing: Spacing.half
                ) {
                    ForEach(ReadCalendarSettings.doneEmojiAssetNames, id: \.self) { assetName in
                        doneEmojiButton(assetName)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: settings.doneMarkerStyle)
    }

    private func doneEmojiButton(_ assetName: String) -> some View {
        let isSelected = settings.doneEmojiAssetName == assetName
        return Button {
            settings.doneEmojiAssetName = assetName
        } label: {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .padding(Spacing.half)
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    isSelected ? Color.brand.opacity(0.14) : Color.controlFillSecondary,
                    in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                            .stroke(Color.brand, lineWidth: 1.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("读完标记图案")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
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
