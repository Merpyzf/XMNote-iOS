import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarSettings 提供受业务规则约束的设置状态，依赖通用设置卡片与根环境 Toast 中心
 * [OUTPUT]: 对外提供采用统一 17/15pt 设置行层级的 ReadCalendarSettingsSheet
 * [POS]: ReadCalendar 业务模块 Sheet，负责卡片外分组、流式数字选项、六类阅读行为与行内展开交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历设置弹层，使用 iOS 原生分组控件表达 Android 的设置结构与展开关系。
struct ReadCalendarSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(XMToastCenter.self) private var toastCenter
    @Bindable var settings: ReadCalendarSettings
    @State private var isDayEventCountExpanded = false
    @State private var isEmojiExpanded = false
    @State private var selectedDetent = ReadCalendarSettingsSheetLayout.compactDetent
    @State private var isAutomaticallyExpanded = false

    var body: some View {
        XMSheetScaffold(
            title: "阅读日历设置",
            onClose: { dismiss() }
        ) {
            VStack(spacing: Spacing.section) {
                displayGroup
                behaviorGroup
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .presentationDetents(
            [ReadCalendarSettingsSheetLayout.compactDetent, .large],
            selection: $selectedDetent
        )
        .presentationDragIndicator(.visible)
        .onChange(of: selectedDetent) { oldValue, newValue in
            guard oldValue == .large,
                  newValue == ReadCalendarSettingsSheetLayout.compactDetent else { return }
            isAutomaticallyExpanded = false
        }
    }

    private var displayGroup: some View {
        ReadCalendarSettingsSection(title: "显示") {
            XMSettingsGroup {
                VStack(spacing: Spacing.none) {
                    dayEventCountRow

                    if isDayEventCountExpanded {
                        dayEventCountGrid
                            .transition(expandableTransition)
                    }

                    XMSettingsDivider()
                    doneMarkerRow

                    if isEmojiExpanded && settings.doneMarkerStyle == .emoji {
                        doneEmojiGrid
                            .transition(expandableTransition)
                    }
                }
            }
        }
    }

    private var dayEventCountRow: some View {
        Button(action: toggleDayEventCount) {
            HStack(spacing: Spacing.base) {
                Text("每日最多事件")
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: Spacing.base)

                HStack(spacing: Spacing.compact) {
                    Text("\(settings.dayEventCount) 条")
                        .font(SettingsTypography.rowValue)
                        .foregroundStyle(Color.textSecondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    Image(
                        systemName: reduceMotion && isDayEventCountExpanded
                            ? "chevron.up"
                            : "chevron.down"
                    )
                    .font(AppTypography.caption2Semibold)
                    .foregroundStyle(Color.textHint)
                    .rotationEffect(
                        .degrees(!reduceMotion && isDayEventCountExpanded ? 180 : 0)
                    )
                    .animation(disclosureAnimation, value: isDayEventCountExpanded)
                    .accessibilityHidden(true)
                }
            }
            .frame(minHeight: ReadCalendarSettingsSheetLayout.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("每日最多事件")
        .accessibilityValue("\(settings.dayEventCount) 条")
        .accessibilityHint(isDayEventCountExpanded ? "收起数量选项" : "展开数量选项")
    }

    private var dayEventCountGrid: some View {
        ReadCalendarSettingsChoiceFlowLayout(
            horizontalSpacing: Spacing.cozy,
            verticalSpacing: Spacing.cozy,
            maximumItemsPerRow: ReadCalendarSettingsSheetLayout.dayCountMaximumItemsPerRow
        ) {
            ForEach(Array(ReadCalendarSettings.dayEventCountRange), id: \.self) { count in
                dayEventCountButton(count)
            }
        }
        .padding(.top, Spacing.compact)
        .padding(.bottom, Spacing.base)
    }

    private func dayEventCountButton(_ count: Int) -> some View {
        let isSelected = count == settings.dayEventCount
        return ReadCalendarSettingsChoiceChip(
            "\(count) 条",
            isSelected: isSelected
        ) {
            selectDayEventCount(count)
        }
        .accessibilityLabel("每天最多显示 \(count) 条事件")
    }

    private var doneMarkerRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.base) {
                doneMarkerTitle
                Spacer(minLength: Spacing.base)
                currentDoneMarker
                doneMarkerStyleControls
            }

            VStack(alignment: .leading, spacing: Spacing.half) {
                doneMarkerTitle

                HStack(spacing: Spacing.base) {
                    Spacer(minLength: Spacing.base)
                    currentDoneMarker
                    doneMarkerStyleControls
                }
            }
            .padding(.vertical, Spacing.half)
        }
        .frame(minHeight: ReadCalendarSettingsSheetLayout.rowMinHeight)
    }

    private var doneMarkerTitle: some View {
        Text("读完标识")
            .font(SettingsTypography.rowTitle)
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var currentDoneMarker: some View {
        if settings.doneMarkerStyle == .emoji {
            Image(settings.doneEmojiAssetName)
                .resizable()
                .scaledToFit()
                .frame(
                    width: ReadCalendarSettingsSheetLayout.currentMarkerSize,
                    height: ReadCalendarSettingsSheetLayout.currentMarkerSize
                )
                .accessibilityHidden(true)
        } else {
            Image(systemName: "checkmark")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textSecondary)
                .frame(
                    width: ReadCalendarSettingsSheetLayout.currentMarkerSize,
                    height: ReadCalendarSettingsSheetLayout.currentMarkerSize
                )
                .accessibilityHidden(true)
        }
    }

    private var doneMarkerStyleControls: some View {
        HStack(spacing: Spacing.half) {
            doneMarkerStyleButton(.checkmark)
            doneMarkerStyleButton(.emoji)
        }
    }

    private func doneMarkerStyleButton(_ style: ReadCalendarDoneMarkerStyle) -> some View {
        let isSelected = settings.doneMarkerStyle == style
        return ReadCalendarSettingsChoiceChip(
            style.title,
            isSelected: isSelected
        ) {
            selectDoneMarkerStyle(style)
        }
        .accessibilityHint(style == .emoji && isSelected ? "再次轻点可展开或收起图案" : "")
    }

    private var doneEmojiGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Spacing.half),
                count: ReadCalendarSettingsSheetLayout.emojiColumnCount
            ),
            spacing: Spacing.half
        ) {
            ForEach(ReadCalendarSettings.doneEmojiAssetNames, id: \.self) { assetName in
                doneEmojiButton(assetName)
            }
        }
        .padding(.top, Spacing.half)
        .padding(.bottom, Spacing.base)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("读完标识图案")
    }

    private func doneEmojiButton(_ assetName: String) -> some View {
        let isSelected = settings.doneEmojiAssetName == assetName
        return Button {
            selectDoneEmoji(assetName)
        } label: {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(
                    width: ReadCalendarSettingsSheetLayout.emojiIconSize,
                    height: ReadCalendarSettingsSheetLayout.emojiIconSize
                )
                .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget)
                .background(
                    isSelected ? Color.selectionAccent.opacity(0.14) : Color.controlFillSecondary,
                    in: RoundedRectangle(
                        cornerRadius: CornerRadius.blockSmall,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(doneEmojiAccessibilityLabel(for: assetName)))
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 为纯图像的读完标识提供可区分的 VoiceOver 名称。
    private func doneEmojiAccessibilityLabel(for assetName: String) -> LocalizedStringKey {
        switch assetName {
        case "ReadCalendarDonePartyPopper": "派对礼炮"
        case "ReadCalendarDoneConfettiBall": "彩纸球"
        case "ReadCalendarDoneGlowingStar": "闪亮星星"
        case "ReadCalendarDonePartyingFace": "派对笑脸"
        case "ReadCalendarDoneSmilingFaceWithHearts": "爱心笑脸"
        case "ReadCalendarDoneEyes": "眼睛"
        case "ReadCalendarDoneBlossom": "花朵"
        case "ReadCalendarDoneCherryBlossom": "樱花"
        case "ReadCalendarDoneBouquet": "花束"
        case "ReadCalendarDoneLollipop": "棒棒糖"
        case "ReadCalendarDoneTriangularFlag": "三角旗"
        case "ReadCalendarDoneBalloon": "气球"
        default: "读完标识图案"
        }
    }

    private var behaviorGroup: some View {
        ReadCalendarSettingsSection(title: "阅读行为") {
            XMSettingsGroup {
                VStack(spacing: Spacing.none) {
                    ForEach(ReadCalendarBehaviorSetting.allCases) { behavior in
                        XMSettingsToggleRow(
                            title: behavior.title,
                            isOn: behaviorBinding(for: behavior)
                        )

                        if behavior != ReadCalendarBehaviorSetting.allCases.last {
                            XMSettingsDivider()
                        }
                    }
                }
            }
        }
    }

    private func behaviorBinding(for behavior: ReadCalendarBehaviorSetting) -> Binding<Bool> {
        Binding(
            get: { settings.isBehaviorEnabled(behavior) },
            set: { isEnabled in
                guard settings.setBehavior(behavior, isEnabled: isEnabled) else {
                    toastCenter.warning("判定阅读行为的规则至少要选一个")
                    return
                }
            }
        )
    }

    /// 切换每日事件数量选项，并在需要时让系统弹层承接新增内容。
    private func toggleDayEventCount() {
        updateExpandedSections(
            dayEventCount: !isDayEventCountExpanded,
            emoji: isEmojiExpanded
        )
    }

    /// 保存每日事件数量并收起其行内选项。
    private func selectDayEventCount(_ count: Int) {
        updateExpandedSections(
            dayEventCount: false,
            emoji: isEmojiExpanded
        ) {
            settings.dayEventCount = count
        }
    }

    /// 切换读完标识样式；重复选择 Emoji 时只切换图案网格。
    private func selectDoneMarkerStyle(_ style: ReadCalendarDoneMarkerStyle) {
        let nextEmojiExpanded: Bool
        if style == .emoji {
            nextEmojiExpanded = settings.doneMarkerStyle == .emoji ? !isEmojiExpanded : true
        } else {
            nextEmojiExpanded = false
        }

        updateExpandedSections(
            dayEventCount: isDayEventCountExpanded,
            emoji: nextEmojiExpanded
        ) {
            settings.doneMarkerStyle = style
        }
    }

    /// 保存读完图案并收起图案网格，保留另一个独立展开区的现场。
    private func selectDoneEmoji(_ assetName: String) {
        updateExpandedSections(
            dayEventCount: isDayEventCountExpanded,
            emoji: false
        ) {
            settings.doneEmojiAssetName = assetName
        }
    }

    /// 在同一动画事务内更新卡片内容、后续分组与弹层高度，避免结构硬切。
    private func updateExpandedSections(
        dayEventCount: Bool,
        emoji: Bool,
        settingsMutation: () -> Void = { }
    ) {
        let hasExpandedContent = dayEventCount || emoji
        let shouldAutoExpand = hasExpandedContent
            && selectedDetent == ReadCalendarSettingsSheetLayout.compactDetent
        let shouldAutoCollapse = !hasExpandedContent && isAutomaticallyExpanded

        withAnimation(structuralAnimation) {
            settingsMutation()
            isDayEventCountExpanded = dayEventCount
            isEmojiExpanded = emoji

            if shouldAutoExpand {
                isAutomaticallyExpanded = true
                selectedDetent = .large
            } else if shouldAutoCollapse {
                isAutomaticallyExpanded = false
                selectedDetent = ReadCalendarSettingsSheetLayout.compactDetent
            }
        }
    }

    private var structuralAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0)
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.16)
    }

    private var expandableTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity
        )
    }
}

private enum ReadCalendarSettingsSheetLayout {
    static let compactDetent = PresentationDetent.fraction(0.72)
    static let rowMinHeight: CGFloat = 52
    static let currentMarkerSize: CGFloat = 22
    static let emojiIconSize: CGFloat = 28
    static let dayCountMaximumItemsPerRow = 4
    static let emojiColumnCount = 6
    static let choiceVisualHeight: CGFloat = 30
    static let choiceSelectedLightFillOpacity = 0.12
    static let choiceSelectedDarkFillOpacity = 0.20
    static let choicePressedOpacity = 0.78
    static let choicePressedScale = 0.98
    static let choicePressDuration = 0.12
}

/// 阅读日历离散选项胶囊，将视觉表层与最小触控区域分离。
private struct ReadCalendarSettingsChoiceChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .footnote) private var visualMinHeight =
        ReadCalendarSettingsSheetLayout.choiceVisualHeight

    /// 创建内容自适应的页面私有选项胶囊。
    init(
        _ title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.footnoteMedium)
                .foregroundStyle(isSelected ? selectedForeground : Color.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, Spacing.base)
                .frame(minHeight: visualMinHeight)
                .background(
                    isSelected
                        ? Color.selectionAccent.opacity(selectedFillOpacity)
                        : Color.controlFillSecondary,
                    in: Capsule()
                )
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(ReadCalendarSettingsChoiceChipButtonStyle())
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedForeground: Color {
        colorScheme == .dark ? Color.appTint : Color.selectionForeground
    }

    private var selectedFillOpacity: Double {
        colorScheme == .dark
            ? ReadCalendarSettingsSheetLayout.choiceSelectedDarkFillOpacity
            : ReadCalendarSettingsSheetLayout.choiceSelectedLightFillOpacity
    }
}

/// 为阅读日历选项胶囊提供可降级的局部按压反馈。
private struct ReadCalendarSettingsChoiceChipButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 在不改变布局尺寸的前提下表达按压状态。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(
                configuration.isPressed
                    ? ReadCalendarSettingsSheetLayout.choicePressedOpacity
                    : 1
            )
            .scaleEffect(
                reduceMotion || !configuration.isPressed
                    ? 1
                    : ReadCalendarSettingsSheetLayout.choicePressedScale
            )
            .animation(
                reduceMotion
                    ? nil
                    : .smooth(duration: ReadCalendarSettingsSheetLayout.choicePressDuration),
                value: configuration.isPressed
            )
    }
}

/// 为阅读日历设置卡片提供外置分组标题，让标题与卡片内文本保持同一对齐线。
private struct ReadCalendarSettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    /// 创建具有次级标题和设置内容的页面私有分组。
    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Spacing.contentEdge)
                .accessibilityAddTraits(.isHeader)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 将紧凑选项按内容宽度左对齐换行，并限制单行数量以稳定视觉节奏。
private struct ReadCalendarSettingsChoiceFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat
    let maximumItemsPerRow: Int

    /// 使用纯尺寸测量返回流式内容所需空间，不读写页面状态。
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width?.isFinite == true
            ? max(proposal.width ?? 0, 0)
            : .greatestFiniteMagnitude
        let result = makeLayout(subviews: subviews, availableWidth: availableWidth)
        return CGSize(
            width: proposal.width ?? result.contentSize.width,
            height: result.contentSize.height
        )
    }

    /// 按测量结果定位子视图，保持前导对齐和稳定的行间距。
    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = makeLayout(subviews: subviews, availableWidth: bounds.width)
        for placement in result.placements {
            subviews[placement.index].place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: placement.size.width,
                    height: placement.size.height
                )
            )
        }
    }

    /// 生成测量与摆放共享的换行结果，宽度不足时优先换行。
    private func makeLayout(
        subviews: Subviews,
        availableWidth: CGFloat
    ) -> ReadCalendarSettingsChoiceFlowResult {
        var placements: [ReadCalendarSettingsChoiceFlowPlacement] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowItemCount = 0
        var contentWidth: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let exceedsRowWidth = rowItemCount > 0 && cursorX + size.width > availableWidth
            let reachesItemLimit = rowItemCount >= max(maximumItemsPerRow, 1)

            if exceedsRowWidth || reachesItemLimit {
                cursorX = 0
                cursorY += rowHeight + verticalSpacing
                rowHeight = 0
                rowItemCount = 0
            }

            placements.append(
                ReadCalendarSettingsChoiceFlowPlacement(
                    index: index,
                    origin: CGPoint(x: cursorX, y: cursorY),
                    size: size
                )
            )
            rowHeight = max(rowHeight, size.height)
            contentWidth = max(contentWidth, cursorX + size.width)
            cursorX += size.width + horizontalSpacing
            rowItemCount += 1
        }

        return ReadCalendarSettingsChoiceFlowResult(
            placements: placements,
            contentSize: CGSize(
                width: contentWidth,
                height: placements.isEmpty ? 0 : cursorY + rowHeight
            )
        )
    }
}

/// 记录单个流式选项的坐标和测量尺寸。
private struct ReadCalendarSettingsChoiceFlowPlacement {
    let index: Int
    let origin: CGPoint
    let size: CGSize
}

/// 聚合流式布局的子视图位置和总体尺寸。
private struct ReadCalendarSettingsChoiceFlowResult {
    let placements: [ReadCalendarSettingsChoiceFlowPlacement]
    let contentSize: CGSize
}
