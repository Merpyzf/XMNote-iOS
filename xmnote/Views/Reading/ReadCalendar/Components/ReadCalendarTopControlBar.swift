import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarTheme 次级文字色、ReadCalendarTextStyle、月份/年份与两态 Reicon 显示模式状态，依赖回调驱动页面壳层打开选择 Sheet 或切换显示模式
 * [OUTPUT]: 对外提供 ReadCalendarTopControlBar（固定光学尺寸、无玻璃重影、仅底板运动的阅读日历顶部控制区）
 * [POS]: ReadCalendar 业务内复用组件，承载月份或年份切换与显示模式切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 日历顶部控制栏，负责月份或年份切换以及显示模式切换入口。
struct ReadCalendarTopControlBar: View {
    private enum Layout {
        static let topControlSpacing: CGFloat = Spacing.cozy
        static let modeSwitcherWidth: CGFloat = 116
        static let expandedModeSwitcherWidth: CGFloat = 128
        static let leadingSwitcherMinHeight: CGFloat = InteractionMetrics.minimumTouchTarget
        static let expandedLeadingSwitcherMinHeight: CGFloat = 48
    }

    private enum Motion {
        static let yearValue = Animation.snappy(duration: 0.24)
    }

    let monthTitle: String
    let yearTitle: String
    let pagerSelection: Date
    let selectedYear: Int
    let displayMode: ReadCalendarContentView.DisplayMode
    let onDisplayModeChanged: (ReadCalendarContentView.DisplayMode) -> Void
    let onMonthPickerRequested: () -> Void
    let onYearPickerRequested: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption2) private var chevronSymbolSize = 10

    var body: some View {
        HStack(alignment: usesExpandedTextLayout ? .top : .center, spacing: Layout.topControlSpacing) {
            leadingSwitcher
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .transaction(value: displayMode) { transaction in
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }

            modeSwitcher
                .frame(width: usesExpandedTextLayout ? Layout.expandedModeSwitcherWidth : Layout.modeSwitcherWidth)
        }
        .padding(.horizontal, Spacing.screenEdge)
    }
}

private extension ReadCalendarTopControlBar {
    @ViewBuilder
    var leadingSwitcher: some View {
        if displayMode == .heatmap {
            yearSwitcher
        } else {
            monthSwitcher
        }
    }

    var monthSwitcher: some View {
        CalendarMonthStepperBar(
            title: monthTitle,
            selectedMonth: pagerSelection,
            onRequestPicker: onMonthPickerRequested
        )
    }

    var yearSwitcher: some View {
        Button {
            onYearPickerRequested()
        } label: {
            HStack(spacing: Spacing.compact) {
                Text(yearTitle)
                    .font(ReadCalendarTextStyle.topControlTitleFont)
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(usesExpandedTextLayout ? 2 : 1)
                    .minimumScaleFactor(usesExpandedTextLayout ? 1 : 0.9)
                    .multilineTextAlignment(.leading)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : Motion.yearValue, value: selectedYear)

                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSymbolSize, weight: .semibold))
                    .foregroundStyle(ReadCalendarTheme.subtleText)
                    .offset(y: 0.5)
            }
            .padding(.horizontal, Spacing.half)
            .padding(.vertical, Spacing.compact)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(
            minHeight: usesExpandedTextLayout ? Layout.expandedLeadingSwitcherMinHeight : Layout.leadingSwitcherMinHeight,
            alignment: .leading
        )
        .accessibilityLabel("年份选择")
        .accessibilityValue("\(selectedYear)年")
    }

    var modeSwitcher: some View {
        ReadCalendarModeSwitcher(
            displayMode: displayMode,
            onDisplayModeChanged: onDisplayModeChanged
        )
    }

    var usesExpandedTextLayout: Bool {
        dynamicTypeSize >= .accessibility1
    }
}

/// 阅读日历页面私有的紧凑模式选择器，将业务状态、图标状态和底板运动隔离以消除矢量重影。
private struct ReadCalendarModeSwitcher: View {
    typealias DisplayMode = ReadCalendarContentView.DisplayMode

    private enum Layout {
        static let visualHeight: CGFloat = 32
        static let touchHeight: CGFloat = InteractionMetrics.minimumTouchTarget
        static let containerInset: CGFloat = Spacing.tiny
        static let selectionHorizontalInset: CGFloat = Spacing.hairline
        static let selectionVerticalInset: CGFloat = Spacing.tiny
        static let iconSlotSize: CGFloat = 18
        static let selectionShadowRadius: CGFloat = 3
        static let selectionShadowOffsetY: CGFloat = 1
    }

    private enum Motion {
        static let selection = Animation.snappy(duration: 0.18)
    }

    let displayMode: DisplayMode
    let onDisplayModeChanged: (DisplayMode) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var indicatorSelection: DisplayMode

    /// 注入真实业务模式并建立独立底板状态，避免场景恢复或图标换图继承选择动画。
    init(
        displayMode: DisplayMode,
        onDisplayModeChanged: @escaping (DisplayMode) -> Void
    ) {
        self.displayMode = displayMode
        self.onDisplayModeChanged = onDisplayModeChanged
        _indicatorSelection = State(initialValue: displayMode)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                shellBackground
                selectedIndicator(controlWidth: geometry.size.width)
                modeButtons
                shellBorder
            }
            .frame(width: geometry.size.width, height: Layout.touchHeight)
            .contentShape(Capsule())
        }
        .frame(height: Layout.touchHeight)
        .onChange(of: displayMode) { _, newValue in
            guard newValue != indicatorSelection else { return }
            syncIndicator(to: newValue)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("阅读日历显示模式")
        .accessibilityValue(displayMode.title)
    }
}

private extension ReadCalendarModeSwitcher {
    var shellBackground: some View {
        Capsule()
            .fill(Color.controlFillSecondary.opacity(0.52))
            .frame(height: Layout.visualHeight)
            .allowsHitTesting(false)
    }

    var shellBorder: some View {
        Capsule()
            .stroke(Color.surfaceBorderSubtle.opacity(0.42), lineWidth: StrokeWidth.hairline)
            .frame(height: Layout.visualHeight)
            .allowsHitTesting(false)
    }

    var modeButtons: some View {
        HStack(spacing: Spacing.none) {
            ForEach(DisplayMode.allCases, id: \.self) { mode in
                modeButton(for: mode)
            }
        }
        .padding(.horizontal, Layout.containerInset)
        .frame(height: Layout.touchHeight)
    }

    /// 构建等宽真实按钮，并由真实业务状态提供可访问的选中语义。
    func modeButton(for mode: DisplayMode) -> some View {
        let isSelected = displayMode == mode

        return Button {
            select(mode)
        } label: {
            modeIcon(for: mode, isSelected: isSelected)
                .frame(maxWidth: .infinity, minHeight: Layout.touchHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 渲染固定槽内的 Outline/Filled 图标，并切断资源替换继承到的动画事务。
    func modeIcon(for mode: DisplayMode, isSelected: Bool) -> some View {
        Image(mode.iconResource(isSelected: isSelected))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: mode.iconOpticalSize, height: mode.iconOpticalSize)
            .frame(width: Layout.iconSlotSize, height: Layout.iconSlotSize)
            .foregroundStyle(isSelected ? Color.iconPrimary : Color.iconSecondary)
            .transaction(value: displayMode) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .accessibilityHidden(true)
    }

    /// 绘制不透明选中底板，仅其水平位置响应独立展示状态。
    func selectedIndicator(controlWidth: CGFloat) -> some View {
        Capsule()
            .fill(Color.surfaceCard.opacity(0.98))
            .overlay {
                Capsule()
                    .stroke(Color.surfaceBorderSubtle.opacity(0.36), lineWidth: StrokeWidth.hairline)
            }
            .shadow(
                color: Color.black.opacity(0.035),
                radius: Layout.selectionShadowRadius,
                x: Spacing.none,
                y: Layout.selectionShadowOffsetY
            )
            .frame(
                width: max(
                    segmentWidth(controlWidth: controlWidth) - Layout.selectionHorizontalInset * 2,
                    Spacing.none
                ),
                height: Layout.visualHeight - Layout.selectionVerticalInset * 2
            )
            .position(
                x: indicatorCenterX(controlWidth: controlWidth),
                y: Layout.touchHeight / 2
            )
            .animation(reduceMotion ? nil : Motion.selection, value: indicatorSelection)
            .allowsHitTesting(false)
    }

    /// 提交新模式；真实内容即时更新，底板状态独立触发可中断的短动画。
    func select(_ mode: DisplayMode) {
        guard mode != displayMode else { return }

        indicatorSelection = mode
        onDisplayModeChanged(mode)
    }

    /// 以无动画事务同步场景恢复等外部写入，避免首次展示或恢复时底板滑动。
    func syncIndicator(to mode: DisplayMode) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            indicatorSelection = mode
        }
    }

    /// 按模式数量计算等宽分段，保留外壳水平内缩。
    func segmentWidth(controlWidth: CGFloat) -> CGFloat {
        let availableWidth = max(controlWidth - Layout.containerInset * 2, Spacing.none)
        return availableWidth / CGFloat(DisplayMode.allCases.count)
    }

    /// 根据独立底板状态计算中心点，使快速反向点击可从当前呈现位置续接。
    func indicatorCenterX(controlWidth: CGFloat) -> CGFloat {
        let index = DisplayMode.allCases.firstIndex(of: indicatorSelection) ?? 0
        return Layout.containerInset + segmentWidth(controlWidth: controlWidth) * (CGFloat(index) + 0.5)
    }
}
