#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 SwiftUI、SF Symbols Magic Replace / drawOn / drawOff Symbol Effect 与项目 DesignTokens
 * [OUTPUT]: 对外提供 SelectionMotionTestView（选择动效测试页）
 * [POS]: Debug 测试页，用于验证自定义选择指示器 Magic Replace 与无底座绘制动效
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct SelectionMotionTestView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var baseSelection = false
    @State private var drawFallbackSelection = false
    @State private var styleSelections: Set<XMSelectionIndicatorStyle> = [.checkbox]
    @State private var radioSelection: SelectionMotionDemoOption = .first
    @State private var multipleSelections: Set<SelectionMotionDemoOption> = [.first, .third]
    @State private var stressSelection = false
    @State private var stressTick = 0
    @State private var stressTask: Task<Void, Never>?
    @State private var businessSelection = true

    private static let selectionAnimation = Animation.snappy(duration: 0.18)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                reduceMotionStatus

                cardSection("基础勾选") {
                    SelectionMotionDemoRow(
                        title: "Magic Replace 勾选",
                        subtitle: "单个符号从空圆替换为绿底勾选，取消时反向替换。",
                        style: .checkbox,
                        isSelected: baseSelection,
                        indicatorFont: AppTypography.title3,
                        action: { toggleBaseSelection() }
                    )
                }

                cardSection("Draw On / Off 对照") {
                    SelectionMotionDemoRow(
                        title: "纯勾号无底座",
                        subtitle: "用于无占位选择标记，选中插入 drawOn，取消移除 drawOff。",
                        style: .checkmarkOnly,
                        isSelected: drawFallbackSelection,
                        indicatorFont: AppTypography.title3,
                        action: { toggleDrawFallbackSelection() }
                    )
                }

                cardSection("单选 / 多选对照") {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        styleComparison
                        Divider()
                        radioComparison
                        Divider()
                        multipleComparison
                    }
                    .padding(Spacing.contentEdge)
                }

                cardSection("高频交互") {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        SelectionMotionDemoRow(
                            title: "连点观察项",
                            subtitle: "连续切换次数：\(stressTick)",
                            style: .checkbox,
                            isSelected: stressSelection,
                            indicatorFont: AppTypography.title3,
                            action: { toggleStressSelection() }
                        )

                        HStack(spacing: Spacing.cozy) {
                            stressButton("切换一次", action: toggleStressSelection)
                            stressButton("连续切换", action: runStressSequence)
                            stressButton("重置", action: resetStressState)
                        }
                    }
                    .padding(Spacing.contentEdge)
                }

                cardSection("业务尺寸预览") {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        businessPreview
                        SelectionMotionDemoRow(
                            title: "列表行尾部",
                            subtitle: "模拟 BookPicker / 搜索结果行的尾部选择指示。",
                            style: .checkbox,
                            isSelected: businessSelection,
                            indicatorFont: AppTypography.body,
                            action: { toggleBusinessSelection() }
                        )
                        batchOptionPreview
                    }
                    .padding(Spacing.contentEdge)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .background(Color.surfacePage)
        .navigationTitle("选择动效")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            stressTask?.cancel()
        }
    }

    private var reduceMotionStatus: some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: reduceMotion ? "figure.walk.motion.trianglebadge.exclamationmark" : "figure.walk.motion")
                .font(AppTypography.body)
                .foregroundStyle(reduceMotion ? Color.textSecondary : Color.brand)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(reduceMotion ? "减少动态效果：已开启" : "减少动态效果：未开启")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                Text(reduceMotion ? "当前只保留即时状态变化。" : "当前会执行 Magic Replace；无底座场景保留绘制动效。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(Spacing.contentEdge)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
    }

    private var styleComparison: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text("形态对照")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)

            HStack(spacing: Spacing.cozy) {
                ForEach(XMSelectionIndicatorStyle.allCases) { style in
                    Button {
                        toggleStyleSelection(style)
                    } label: {
                        VStack(spacing: Spacing.half) {
                            XMSelectionIndicator(
                                style: style,
                                isSelected: styleSelections.contains(style),
                                font: AppTypography.title3
                            )
                            Text(style.title)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, minHeight: 70)
                        .background(
                            styleSelections.contains(style) ? Color.brand.opacity(0.08) : Color.controlFillSecondary.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                                .stroke(
                                    styleSelections.contains(style) ? Color.brand.opacity(0.28) : Color.surfaceBorderSubtle,
                                    lineWidth: CardStyle.borderWidth
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(styleSelections.contains(style) ? .isSelected : [])
                }
            }
        }
    }

    private var radioComparison: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text("单选")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)

            ForEach(SelectionMotionDemoOption.allCases) { option in
                SelectionMotionDemoRow(
                    title: option.title,
                    subtitle: option.radioSubtitle,
                    style: .radio,
                    isSelected: radioSelection == option,
                    indicatorFont: AppTypography.body,
                    action: { selectRadioOption(option) }
                )
            }
        }
    }

    private var multipleComparison: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text("多选")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)

            ForEach(SelectionMotionDemoOption.allCases) { option in
                SelectionMotionDemoRow(
                    title: option.title,
                    subtitle: option.multipleSubtitle,
                    style: .checkbox,
                    isSelected: multipleSelections.contains(option),
                    indicatorFont: AppTypography.body,
                    action: { toggleMultipleOption(option) }
                )
            }
        }
    }

    private var businessPreview: some View {
        Button {
            toggleBusinessSelection()
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .fill(Color.controlFillSecondary)
                        .frame(height: 116)
                        .overlay {
                            Image(systemName: "book.closed")
                                .font(AppTypography.title2)
                                .foregroundStyle(Color.textHint)
                        }

                    Text("书架角标")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Text(businessSelection ? "已选中" : "未选中")
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textSecondary)
                }

                XMSelectionIndicator(
                    style: .checkbox,
                    isSelected: businessSelection,
                    font: AppTypography.title3
                )
                .padding(Spacing.half)
                .background(Color.surfaceCard.opacity(businessSelection ? 0.90 : 0.48), in: Circle())
                .shadow(color: Color.black.opacity(businessSelection ? 0.12 : 0.04), radius: businessSelection ? 3 : 2, y: 1)
            }
            .padding(Spacing.base)
            .background(
                businessSelection ? Color.brand.opacity(0.06) : Color.surfaceCard,
                in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .stroke(
                        businessSelection ? Color.brand.opacity(0.30) : Color.surfaceBorderSubtle,
                        lineWidth: CardStyle.borderWidth
                    )
            }
            .animation(containerAnimation, value: businessSelection)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(businessSelection ? .isSelected : [])
    }

    private var batchOptionPreview: some View {
        Button {
            toggleBusinessSelection()
        } label: {
            HStack(spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text("批量 Sheet 选项")
                        .font(AppTypography.bodyMedium)
                        .foregroundStyle(Color.textPrimary)
                    Text("模拟紧凑选项行的右侧勾选反馈。")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer(minLength: Spacing.compact)

                XMSelectionIndicator(
                    style: .checkbox,
                    isSelected: businessSelection,
                    font: AppTypography.body
                )
            }
            .padding(Spacing.base)
            .background(Color.controlFillSecondary.opacity(0.72), in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(businessSelection ? .isSelected : [])
    }

    private var containerAnimation: Animation? {
        reduceMotion ? nil : Self.selectionAnimation
    }

    private func cardSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.footnoteSemibold)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Spacing.compact)

            CardContainer {
                content()
            }
        }
    }

    private func stressButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.brand)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Color.brand.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggleBaseSelection() {
        withSelectionAnimation {
            baseSelection.toggle()
        }
    }

    private func toggleDrawFallbackSelection() {
        withSelectionAnimation {
            drawFallbackSelection.toggle()
        }
    }

    private func toggleStyleSelection(_ style: XMSelectionIndicatorStyle) {
        withSelectionAnimation {
            if styleSelections.contains(style) {
                styleSelections.remove(style)
            } else {
                styleSelections.insert(style)
            }
        }
    }

    private func selectRadioOption(_ option: SelectionMotionDemoOption) {
        guard radioSelection != option else { return }
        withSelectionAnimation {
            radioSelection = option
        }
    }

    private func toggleMultipleOption(_ option: SelectionMotionDemoOption) {
        withSelectionAnimation {
            if multipleSelections.contains(option) {
                multipleSelections.remove(option)
            } else {
                multipleSelections.insert(option)
            }
        }
    }

    private func toggleStressSelection() {
        stressTask?.cancel()
        withSelectionAnimation {
            stressSelection.toggle()
            stressTick += 1
        }
    }

    private func resetStressState() {
        stressTask?.cancel()
        withSelectionAnimation {
            stressSelection = false
            stressTick = 0
        }
    }

    /// 连续切换只在主 actor 更新调试态；新一轮触发会取消旧任务，避免并发写入造成错层判断噪声。
    private func runStressSequence() {
        stressTask?.cancel()
        stressTask = Task { @MainActor in
            let animation = reduceMotion ? nil : Self.selectionAnimation
            for _ in 0..<8 {
                guard !Task.isCancelled else { return }
                withAnimation(animation) {
                    stressSelection.toggle()
                    stressTick += 1
                }
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    private func toggleBusinessSelection() {
        withSelectionAnimation {
            businessSelection.toggle()
        }
    }

    private func withSelectionAnimation(_ updates: () -> Void) {
        withAnimation(containerAnimation) {
            updates()
        }
    }
}

private struct SelectionMotionDemoRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let subtitle: String
    let style: XMSelectionIndicatorStyle
    let isSelected: Bool
    let indicatorFont: Font
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text(title)
                        .font(AppTypography.bodyMedium)
                        .foregroundStyle(Color.textPrimary)
                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Spacing.compact)

                XMSelectionIndicator(
                    style: style,
                    isSelected: isSelected,
                    font: indicatorFont
                )
            }
            .padding(Spacing.base)
            .background(
                isSelected ? Color.brand.opacity(0.06) : Color.controlFillSecondary.opacity(0.70),
                in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    .stroke(
                        isSelected ? Color.brand.opacity(0.26) : Color.surfaceBorderSubtle,
                        lineWidth: CardStyle.borderWidth
                    )
            }
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension XMSelectionIndicatorStyle {
    var title: String {
        switch self {
        case .checkbox:
            return "勾选框"
        case .radio:
            return "单选圆点"
        case .checkmarkOnly:
            return "纯勾号"
        }
    }
}

private enum SelectionMotionDemoOption: String, CaseIterable, Identifiable {
    case first
    case second
    case third

    var id: String { rawValue }

    var title: String {
        switch self {
        case .first:
            return "样例一"
        case .second:
            return "样例二"
        case .third:
            return "样例三"
        }
    }

    var radioSubtitle: String {
        switch self {
        case .first:
            return "当前默认项，切换时观察圆点的 Magic Replace。"
        case .second:
            return "单选只允许一个选中层存在。"
        case .third:
            return "连续切换时不应出现残影。"
        }
    }

    var multipleSubtitle: String {
        switch self {
        case .first:
            return "多选项从空圆魔术替换为勾选。"
        case .second:
            return "取消时反向替换，底座不跳变。"
        case .third:
            return "容器反馈只做轻量颜色变化。"
        }
    }
}

#Preview {
    NavigationStack {
        SelectionMotionTestView()
    }
}
#endif
