#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖生产 TopBarActionPill、HomeTopHeaderGradient、DesignTokens 与 iOS 26 原生 Glass/GlassEffectContainer/glassEffectUnion 能力
 * [OUTPUT]: 对外提供 TopBarActionStyleLabTestView，以已采用方案 A 的正式基线和 A/B/C 固定候选验证首页顶部双 action 胶囊
 * [POS]: Debug 测试页，仅用于正式方案 A 与其余候选在真实渐变上下文中的浅深色、交互、Dynamic Type 与高级参数对照，不写入生产配置
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct TopBarActionStyleLabTestView: View {
    @State private var selectedCandidate: TopBarActionLabCandidate = .baseline
    @State private var selectedContext: TopBarActionLabContext = .review
    @State private var schemeMode: TopBarActionLabScheme = .system
    @State private var drafts = TopBarActionLabDraftStore()
    @State private var showsAdvancedTuning = false

    var body: some View {
        VStack(spacing: 0) {
            TopBarActionLabPinnedPreview(
                candidate: selectedCandidate,
                context: selectedContext,
                parameters: selectedParameters,
                isModified: isSelectedCandidateModified,
                onSelectCandidate: selectCandidate
            )

            ScrollView {
                VStack(spacing: Spacing.base) {
                    TopBarActionLabContextSection(
                        selectedContext: $selectedContext,
                        schemeMode: $schemeMode
                    )

                    TopBarActionLabCandidateSection(
                        selectedCandidate: selectedCandidate,
                        context: selectedContext,
                        parametersForCandidate: parameters(for:),
                        isModified: isModified(_:),
                        onSelectCandidate: selectCandidate
                    )

                    TopBarActionLabAdvancedSection(
                        candidate: selectedCandidate,
                        parameters: selectedParametersBinding,
                        isModified: isSelectedCandidateModified,
                        isExpanded: $showsAdvancedTuning,
                        onReset: resetSelectedCandidate
                    )
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
                .safeAreaPadding(.bottom)
            }
            .scrollBounceBehavior(.always)
        }
        .background(Color.surfacePage)
        .navigationTitle("首页顶部胶囊")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(schemeMode.colorScheme)
        .accessibilityIdentifier("debug.topbar.action-pill.lab")
    }

    private var selectedParameters: TopBarActionLabParameters {
        parameters(for: selectedCandidate)
    }

    private var selectedParametersBinding: Binding<TopBarActionLabParameters> {
        Binding(
            get: { parameters(for: selectedCandidate) },
            set: { drafts[selectedCandidate] = $0 }
        )
    }

    private var isSelectedCandidateModified: Bool {
        isModified(selectedCandidate)
    }

    private func parameters(for candidate: TopBarActionLabCandidate) -> TopBarActionLabParameters {
        candidate == .baseline ? .baseline : drafts[candidate]
    }

    private func isModified(_ candidate: TopBarActionLabCandidate) -> Bool {
        guard candidate.isEditable else { return false }
        return drafts[candidate] != candidate.defaultParameters
    }

    private func selectCandidate(_ candidate: TopBarActionLabCandidate) {
        selectedCandidate = candidate
    }

    private func resetSelectedCandidate() {
        guard selectedCandidate.isEditable else { return }
        drafts[selectedCandidate] = selectedCandidate.defaultParameters
    }
}

// MARK: - Pinned Preview

private struct TopBarActionLabPinnedPreview: View {
    let candidate: TopBarActionLabCandidate
    let context: TopBarActionLabContext
    let parameters: TopBarActionLabParameters
    let isModified: Bool
    let onSelectCandidate: (TopBarActionLabCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前预览：\(candidate.displayName)")
                        .font(AppTypography.headlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Text(candidate.summary)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: Spacing.half)

                if isModified {
                    Text("已调整")
                        .font(AppTypography.caption2Semibold)
                        .foregroundStyle(Color.brandDeep)
                        .padding(.horizontal, Spacing.half)
                        .padding(.vertical, 4)
                        .background(Color.brand.opacity(0.10), in: Capsule())
                }
            }

            Picker("候选方案", selection: candidateSelection) {
                ForEach(TopBarActionLabCandidate.allCases) { option in
                    Text(option.code).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("顶部胶囊候选方案")
            .accessibilityIdentifier("debug.topbar.action-pill.candidate-picker")

            TopBarActionLabPreviewStage(
                context: context,
                candidate: candidate,
                parameters: parameters
            )
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.cozy)
        .background(Color.surfacePage)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var candidateSelection: Binding<TopBarActionLabCandidate> {
        Binding(
            get: { candidate },
            set: onSelectCandidate
        )
    }
}

private struct TopBarActionLabPreviewStage: View {
    let context: TopBarActionLabContext
    let candidate: TopBarActionLabCandidate
    let parameters: TopBarActionLabParameters

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage
            HomeTopHeaderGradient()

            VStack(spacing: 0) {
                TopBarActionLabToolbarRow(
                    context: context,
                    candidate: candidate,
                    parameters: parameters
                )
                .padding(.top, Spacing.cozy)

                TopBarActionLabContentSample(context: context)
                    .padding(.top, Spacing.base)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.screenEdge)
        }
        .frame(height: 286)
        .compositingGroup()
        .clipShape(.rect(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .accessibilityIdentifier("debug.topbar.action-pill.preview")
    }
}

// MARK: - Context Controls

private struct TopBarActionLabContextSection: View {
    @Binding var selectedContext: TopBarActionLabContext
    @Binding var schemeMode: TopBarActionLabScheme

    var body: some View {
        TopBarActionLabCard(title: "预览环境") {
            TopBarActionLabPickerRow(
                title: "首页上下文",
                selection: $selectedContext,
                values: TopBarActionLabContext.allCases
            )

            TopBarActionLabPickerRow(
                title: "外观模式",
                selection: $schemeMode,
                values: TopBarActionLabScheme.allCases
            )
        }
    }
}

private struct TopBarActionLabPickerRow<Value>: View where Value: CaseIterable & Identifiable & Hashable & TopBarActionLabTitledOption, Value.AllCases: RandomAccessCollection {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let values: Value.AllCases

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            Picker(title, selection: $selection) {
                ForEach(values) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Candidate Comparison

private struct TopBarActionLabCandidateSection: View {
    let selectedCandidate: TopBarActionLabCandidate
    let context: TopBarActionLabContext
    let parametersForCandidate: (TopBarActionLabCandidate) -> TopBarActionLabParameters
    let isModified: (TopBarActionLabCandidate) -> Bool
    let onSelectCandidate: (TopBarActionLabCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            VStack(alignment: .leading, spacing: 4) {
                Text("固定候选对比")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                Text("四版使用同一首页上下文；点击“查看”切换顶部大预览，胶囊内菜单可直接交互。")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(TopBarActionLabCandidate.allCases) { candidate in
                TopBarActionLabCandidateCard(
                    candidate: candidate,
                    context: context,
                    parameters: parametersForCandidate(candidate),
                    isSelected: selectedCandidate == candidate,
                    isModified: isModified(candidate),
                    onSelect: { onSelectCandidate(candidate) }
                )
            }
        }
    }
}

private struct TopBarActionLabCandidateCard: View {
    let candidate: TopBarActionLabCandidate
    let context: TopBarActionLabContext
    let parameters: TopBarActionLabParameters
    let isSelected: Bool
    let isModified: Bool
    let onSelect: () -> Void

    var body: some View {
        CardContainer(
            showsBorder: true,
            borderColor: isSelected ? Color.brand.opacity(0.52) : Color.surfaceBorderSubtle
        ) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                HStack(alignment: .top, spacing: Spacing.half) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: Spacing.half) {
                            Text(candidate.displayName)
                                .font(AppTypography.headlineSemibold)
                                .foregroundStyle(Color.textPrimary)

                            if candidate == .clear && !isModified {
                                Text("已采用")
                                    .font(AppTypography.caption2Semibold)
                                    .foregroundStyle(Color.brandDeep)
                                    .padding(.horizontal, Spacing.half)
                                    .padding(.vertical, 3)
                                    .background(Color.brand.opacity(0.10), in: Capsule())
                            }

                            if isModified {
                                Text("已调整")
                                    .font(AppTypography.caption2Semibold)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }

                        Text(candidate.summary)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Spacing.half)

                    Button(action: onSelect) {
                        Label(isSelected ? "正在查看" : "查看", systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                            .labelStyle(.iconOnly)
                            .font(AppTypography.body)
                            .foregroundStyle(isSelected ? Color.brand : Color.textSecondary)
                            .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isSelected ? "正在查看\(candidate.displayName)" : "查看\(candidate.displayName)")
                    .accessibilityIdentifier("debug.topbar.action-pill.candidate.\(candidate.rawValue)")
                }

                ZStack {
                    Color.surfacePage
                    HomeTopHeaderGradient()

                    TopBarActionLabToolbarRow(
                        context: context,
                        candidate: candidate,
                        parameters: parameters
                    )
                    .padding(.horizontal, Spacing.cozy)
                }
                .frame(height: 78)
                .compositingGroup()
                .clipShape(.rect(cornerRadius: CornerRadius.blockMedium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle.opacity(0.55), lineWidth: CardStyle.borderWidth)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }
}

// MARK: - Advanced Tuning

private struct TopBarActionLabAdvancedSection: View {
    let candidate: TopBarActionLabCandidate
    @Binding var parameters: TopBarActionLabParameters
    let isModified: Bool
    @Binding var isExpanded: Bool
    let onReset: () -> Void

    var body: some View {
        TopBarActionLabCard(title: "高级调参") {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    if candidate.isEditable {
                        editableControls
                    } else {
                        Text("当前正式版直接复用生产 TopBarActionPill，基线参数保持只读，避免对照被意外改写")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    Text(parameters.summary(for: candidate))
                        .font(AppTypography.caption2)
                        .monospaced()
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityLabel("当前候选参数摘要")
                }
                .padding(.top, Spacing.cozy)
            } label: {
                HStack(spacing: Spacing.half) {
                    Text(candidate.isEditable ? "调整当前候选" : "查看基线参数")
                        .font(AppTypography.bodyMedium)
                        .foregroundStyle(Color.textPrimary)

                    if isModified {
                        Text("已调整")
                            .font(AppTypography.caption2Semibold)
                            .foregroundStyle(Color.brandDeep)
                    }
                }
            }
        }
    }

    private var editableControls: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            TopBarActionLabPickerRow(
                title: "Glass 材质",
                selection: $parameters.glassVariant,
                values: TopBarActionLabGlassVariant.allCases
            )

            TopBarActionLabSliderRow(
                title: "胶囊高度",
                value: $parameters.pillHeight,
                range: 34...40,
                step: 1,
                decimals: 0,
                unit: "pt"
            )

            if candidate != .union {
                Toggle("显示分隔线", isOn: $parameters.showsDivider)
                    .font(AppTypography.body)

                TopBarActionLabSliderRow(
                    title: "分隔线高度",
                    value: $parameters.dividerHeight,
                    range: 8...16,
                    step: 1,
                    decimals: 0,
                    unit: "pt"
                )
                .disabled(!parameters.showsDivider)

                TopBarActionLabSliderRow(
                    title: "分隔线透明度",
                    value: $parameters.dividerOpacity,
                    range: 0...0.12,
                    step: 0.01,
                    decimals: 2,
                    unit: ""
                )
                .disabled(!parameters.showsDivider)
            } else {
                TopBarActionLabSliderRow(
                    title: "融合间距",
                    value: $parameters.unionSpacing,
                    range: 0...6,
                    step: 1,
                    decimals: 0,
                    unit: "pt"
                )
            }

            TopBarActionLabSliderRow(
                title: "+ 图标",
                value: $parameters.plusIconSize,
                range: 13...15,
                step: 1,
                decimals: 0,
                unit: "pt"
            )

            TopBarActionLabSliderRow(
                title: "右侧图标",
                value: $parameters.trailingIconSize,
                range: 14...16,
                step: 1,
                decimals: 0,
                unit: "pt"
            )

            TopBarActionLabSliderRow(
                title: "图标透明度",
                value: $parameters.iconOpacity,
                range: 0.72...1,
                step: 0.01,
                decimals: 2,
                unit: ""
            )

            Button("恢复该方案默认值", systemImage: "arrow.counterclockwise", action: onReset)
                .font(AppTypography.bodyMedium)
                .disabled(!isModified)
        }
    }
}

private struct TopBarActionLabSliderRow: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let decimals: Int
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.half) {
                Text(title)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: Spacing.half)

                Text(verbatim: formattedValue)
                    .font(AppTypography.caption2Semibold)
                    .foregroundStyle(Color.brandDeep)
            }

            Slider(value: $value, in: range, step: step)
                .tint(Color.brand)
        }
    }

    private var formattedValue: String {
        let number = String(format: "%.*f", decimals, value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }
}

private struct TopBarActionLabCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        CardContainer(showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                content
            }
            .padding(Spacing.contentEdge)
        }
    }
}

// MARK: - Toolbar Preview

private struct TopBarActionLabToolbarRow: View {
    let context: TopBarActionLabContext
    let candidate: TopBarActionLabCandidate
    let parameters: TopBarActionLabParameters

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            TopBarActionLabTitleGroup(context: context)
            Spacer(minLength: Spacing.base)
            TopBarActionLabActionGroup(candidate: candidate, context: context, parameters: parameters)
        }
        .frame(minHeight: 56)
    }
}

private struct TopBarActionLabTitleGroup: View {
    let context: TopBarActionLabContext

    var body: some View {
        Group {
            switch context {
            case .review:
                pairedTitles(first: "笔记", second: "回顾", selectsFirst: false)
            case .notes:
                pairedTitles(first: "笔记", second: "回顾", selectsFirst: true)
            case .personal:
                Text("我的")
                    .font(BookshelfTypography.topSelected)
                    .foregroundStyle(Color.textPrimary)
            case .collection:
                pairedTitles(first: "书籍", second: "书单", selectsFirst: false)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.86)
        .accessibilityElement(children: .combine)
    }

    private func pairedTitles(first: LocalizedStringKey, second: LocalizedStringKey, selectsFirst: Bool) -> some View {
        HStack(spacing: Spacing.double) {
            Text(first)
                .font(selectsFirst ? BookshelfTypography.topSelected : BookshelfTypography.topUnselected)
                .foregroundStyle(selectsFirst ? Color.textPrimary : Color.textHint)
            Text(second)
                .font(selectsFirst ? BookshelfTypography.topUnselected : BookshelfTypography.topSelected)
                .foregroundStyle(selectsFirst ? Color.textHint : Color.textPrimary)
        }
    }
}

private struct TopBarActionLabActionGroup: View {
    let candidate: TopBarActionLabCandidate
    let context: TopBarActionLabContext
    let parameters: TopBarActionLabParameters
    @Namespace private var unionNamespace

    var body: some View {
        switch candidate {
        case .baseline:
            baselineGroup
        case .clear, .regular:
            singleGlassGroup
        case .union:
            unionGlassGroup
        }
    }

    private var baselineGroup: some View {
        TopBarActionPill {
            TopBarActionLabMenuControl(
                role: .add,
                context: context,
                iconSize: parameters.plusIconSize,
                iconOpacity: parameters.iconOpacity,
                labelHeight: Spacing.actionReserved,
                style: .productionSegment
            )
        } trailing: {
            TopBarActionLabMenuControl(
                role: .trailing,
                context: context,
                iconSize: parameters.trailingIconSize,
                iconOpacity: parameters.iconOpacity,
                labelHeight: Spacing.actionReserved,
                style: .productionSegment
            )
        }
    }

    private var singleGlassGroup: some View {
        HStack(spacing: 0) {
            TopBarActionLabMenuControl(
                role: .add,
                context: context,
                iconSize: parameters.plusIconSize,
                iconOpacity: parameters.iconOpacity,
                labelHeight: Spacing.actionReserved,
                style: .plain
            )

            if parameters.showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(parameters.dividerOpacity))
                    .frame(width: CardStyle.borderWidth, height: CGFloat(parameters.dividerHeight))
                    .accessibilityHidden(true)
            }

            TopBarActionLabMenuControl(
                role: .trailing,
                context: context,
                iconSize: parameters.trailingIconSize,
                iconOpacity: parameters.iconOpacity,
                labelHeight: Spacing.actionReserved,
                style: .plain
            )
        }
        .padding(.horizontal, 2)
        .frame(height: Spacing.actionReserved)
        .background {
            TopBarActionLabSingleGlassBackground(parameters: parameters)
        }
    }

    private var unionGlassGroup: some View {
        GlassEffectContainer(spacing: CGFloat(parameters.unionSpacing)) {
            HStack(spacing: CGFloat(parameters.unionSpacing)) {
                unionControl(role: .add, iconSize: parameters.plusIconSize)
                unionControl(role: .trailing, iconSize: parameters.trailingIconSize)
            }
        }
        .frame(height: Spacing.actionReserved)
    }

    private func unionControl(role: TopBarActionLabMenuRole, iconSize: Double) -> some View {
        TopBarActionLabMenuControl(
            role: role,
            context: context,
            iconSize: iconSize,
            iconOpacity: parameters.iconOpacity,
            labelHeight: parameters.pillHeight,
            style: .plain
        )
        .frame(width: Spacing.actionReserved, height: CGFloat(parameters.pillHeight))
        .modifier(TopBarActionLabInteractiveGlassModifier(variant: parameters.glassVariant))
        .glassEffectUnion(id: "top-bar-action-pill", namespace: unionNamespace)
        .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
    }
}

private struct TopBarActionLabSingleGlassBackground: View {
    let parameters: TopBarActionLabParameters

    var body: some View {
        Color.clear
            .frame(height: CGFloat(parameters.pillHeight))
            .modifier(TopBarActionLabInteractiveGlassModifier(variant: parameters.glassVariant))
    }
}

private struct TopBarActionLabInteractiveGlassModifier: ViewModifier {
    let variant: TopBarActionLabGlassVariant

    func body(content: Content) -> some View {
        switch variant {
        case .clear:
            content.glassEffect(.clear.interactive(), in: .capsule)
        case .regular:
            content.glassEffect(.regular.interactive(), in: .capsule)
        }
    }
}

private struct TopBarActionLabMenuControl: View {
    let role: TopBarActionLabMenuRole
    let context: TopBarActionLabContext
    let iconSize: Double
    let iconOpacity: Double
    let labelHeight: Double
    let style: TopBarActionLabControlStyle

    var body: some View {
        switch style {
        case .productionSegment:
            menu.topBarActionPillSegmentStyle(true)
        case .plain:
            menu.buttonStyle(.plain)
        }
    }

    private var menu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: CGFloat(iconSize), weight: .medium))
                .foregroundStyle(Color.iconPrimary.opacity(iconOpacity))
                .frame(width: Spacing.actionReserved, height: CGFloat(labelHeight))
                .contentShape(Rectangle())
        }
        .xmMenuNeutralTint()
        .menuOrder(.fixed)
        .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var menuItems: some View {
        switch role {
        case .add:
            Button(action: {}) {
                XMMenuLabel("添加书籍", systemImage: "book.badge.plus")
            }
            Button(action: {}) {
                XMMenuLabel("添加书摘", systemImage: "square.and.pencil")
            }
        case .trailing:
            switch context {
            case .review:
                Button(action: {}) {
                    XMMenuLabel("回顾设置", systemImage: "slider.horizontal.3")
                }
            case .notes:
                Button(action: {}) {
                    XMMenuLabel("最新优先", systemImage: "clock")
                }
                Button(action: {}) {
                    XMMenuLabel("按书籍分组", systemImage: "books.vertical")
                }
            case .personal:
                Button(action: {}) {
                    XMMenuLabel("设置", systemImage: "slider.horizontal.3")
                }
            case .collection:
                Button(action: {}) {
                    XMMenuLabel("调整排序", systemImage: "arrow.up.arrow.down")
                }
                Button(action: {}) {
                    XMMenuLabel("显示设置", systemImage: "slider.horizontal.3")
                }
            }
        }
    }

    private var systemImage: String {
        role == .add ? "plus" : context.trailingSystemImage
    }

    private var accessibilityLabel: String {
        role == .add ? "添加" : context.trailingAccessibilityLabel
    }
}

// MARK: - Preview Content

private struct TopBarActionLabContentSample: View {
    let context: TopBarActionLabContext

    var body: some View {
        Group {
            switch context {
            case .review: reviewCard
            case .notes: notesCard
            case .personal: personalCard
            case .collection: collectionCard
            }
        }
        .frame(maxWidth: .infinity, minHeight: 172, maxHeight: 172, alignment: .topLeading)
        .background(Color.surfaceCard)
        .compositingGroup()
        .clipShape(.rect(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle.opacity(0.58), lineWidth: CardStyle.borderWidth)
        }
    }

    private var reviewCard: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text("我们往往会陷入一种奇怪的期待：一个人在某一方面登峰造极，于是就幻想他在各方面都无可挑剔。")
                .font(NoteExcerptTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(3)
            Text("🧐 观点")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Spacing.half)
                .padding(.vertical, 4)
                .background(Color.controlFillSecondary.opacity(0.48), in: Capsule())
            Spacer(minLength: 0)
            Text("《历史的温度》 · 张玮")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(Spacing.contentEdge)
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text("书摘正文是列表中的第一阅读层级，想法与来源信息保持克制。")
                .font(NoteExcerptTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
            Text("想法：好的工具应该帮助我们更快回到内容本身。")
                .font(NoteExcerptTypography.idea)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("今天 00:29 · 纸间书摘")
                .font(NoteExcerptTypography.footer)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(Spacing.contentEdge)
    }

    private var personalCard: some View {
        VStack(spacing: 0) {
            sampleRow(icon: "sparkles", title: "AI 配置")
            Divider().padding(.leading, 42)
            sampleRow(icon: "calendar", title: "阅读数据")
            Divider().padding(.leading, 42)
            sampleRow(icon: "slider.horizontal.3", title: "设置")
        }
        .padding(.horizontal, Spacing.contentEdge)
    }

    private var collectionCard: some View {
        HStack(spacing: Spacing.base) {
            ForEach(["文学", "历史", "认知"], id: \.self) { title in
                VStack(spacing: Spacing.half) {
                    RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                        .fill(Color.controlFillSecondary.opacity(0.72))
                        .frame(height: 92)
                        .overlay {
                            Image(systemName: "books.vertical")
                                .font(AppTypography.title3)
                                .foregroundStyle(Color.textSecondary)
                        }
                    Text(title)
                        .font(BookshelfTypography.gridTitle)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(Spacing.contentEdge)
    }

    private func sampleRow(icon: String, title: LocalizedStringKey) -> some View {
        HStack(spacing: Spacing.cozy) {
            Image(systemName: icon)
                .font(AppTypography.body)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 24)
            Text(title)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
        }
        .frame(minHeight: 54)
    }
}

// MARK: - Models

private enum TopBarActionLabCandidate: String, CaseIterable, Identifiable, Hashable {
    case baseline
    case clear
    case regular
    case union

    var id: String { rawValue }

    var code: String {
        switch self {
        case .baseline: return "0"
        case .clear: return "A"
        case .regular: return "B"
        case .union: return "C"
        }
    }

    var displayName: String {
        switch self {
        case .baseline: return "0 · 正式版（A）"
        case .clear: return "A · 清透减重"
        case .regular: return "B · 标准层次"
        case .union: return "C · 原生融合"
        }
    }

    var summary: String {
        switch self {
        case .baseline: return "直接复用生产 TopBarActionPill，采用 clear interactive 玻璃、12pt 弱分隔线与系统交互反馈。"
        case .clear: return "单层 clear interactive 玻璃，缩短并弱化分隔线，取消自定义缩放"
        case .regular: return "保持 A 的几何参数，仅用 regular interactive 增强浅色背景下的材质层次"
        case .union: return "两个原生交互玻璃分区通过 union 合并为静止态单胶囊，不绘制人工分隔线"
        }
    }

    var isEditable: Bool { self != .baseline }

    var defaultParameters: TopBarActionLabParameters {
        switch self {
        case .baseline: return .baseline
        case .clear: return .clearCandidate
        case .regular: return .regularCandidate
        case .union: return .unionCandidate
        }
    }
}

private struct TopBarActionLabDraftStore: Equatable {
    private var clear = TopBarActionLabParameters.clearCandidate
    private var regular = TopBarActionLabParameters.regularCandidate
    private var union = TopBarActionLabParameters.unionCandidate

    subscript(candidate: TopBarActionLabCandidate) -> TopBarActionLabParameters {
        get {
            switch candidate {
            case .baseline: return .baseline
            case .clear: return clear
            case .regular: return regular
            case .union: return union
            }
        }
        set {
            switch candidate {
            case .baseline: break
            case .clear: clear = newValue
            case .regular: regular = newValue
            case .union: union = newValue
            }
        }
    }
}

private struct TopBarActionLabParameters: Equatable {
    var glassVariant: TopBarActionLabGlassVariant
    var pillHeight: Double
    var showsDivider: Bool
    var dividerHeight: Double
    var dividerOpacity: Double
    var plusIconSize: Double
    var trailingIconSize: Double
    var iconOpacity: Double
    var unionSpacing: Double

    static let baseline = TopBarActionLabParameters(
        glassVariant: .clear, pillHeight: 36, showsDivider: true,
        dividerHeight: 12, dividerOpacity: 0.06, plusIconSize: 14,
        trailingIconSize: 15, iconOpacity: 0.88, unionSpacing: 0
    )
    static let clearCandidate = TopBarActionLabParameters(
        glassVariant: .clear, pillHeight: 36, showsDivider: true,
        dividerHeight: 12, dividerOpacity: 0.06, plusIconSize: 14,
        trailingIconSize: 15, iconOpacity: 0.88, unionSpacing: 0
    )
    static let regularCandidate = TopBarActionLabParameters(
        glassVariant: .regular, pillHeight: 36, showsDivider: true,
        dividerHeight: 12, dividerOpacity: 0.06, plusIconSize: 14,
        trailingIconSize: 15, iconOpacity: 0.88, unionSpacing: 0
    )
    static let unionCandidate = TopBarActionLabParameters(
        glassVariant: .regular, pillHeight: 36, showsDivider: false,
        dividerHeight: 12, dividerOpacity: 0, plusIconSize: 14,
        trailingIconSize: 15, iconOpacity: 0.88, unionSpacing: 0
    )

    func summary(for candidate: TopBarActionLabCandidate) -> String {
        let dividerSummary = candidate == .union
            ? "unionSpacing = \(formatted(unionSpacing, decimals: 0))pt"
            : "divider = \(showsDivider ? "on" : "off"), \(formatted(dividerHeight, decimals: 0))pt @ \(formatted(dividerOpacity, decimals: 2))"
        return """
        candidate = \(candidate.code)
        glass = \(glassVariant.rawValue)
        pillHeight = \(formatted(pillHeight, decimals: 0))pt
        hitSize = 44pt
        \(dividerSummary)
        plusIcon = \(formatted(plusIconSize, decimals: 0))pt
        trailingIcon = \(formatted(trailingIconSize, decimals: 0))pt
        iconOpacity = \(formatted(iconOpacity, decimals: 2))
        """
    }

    private func formatted(_ value: Double, decimals: Int) -> String {
        String(format: "%.*f", decimals, value)
    }
}

private enum TopBarActionLabGlassVariant: String, CaseIterable, Identifiable, Hashable, TopBarActionLabTitledOption {
    case clear
    case regular
    var id: String { rawValue }
    var title: String { self == .clear ? "Clear" : "Regular" }
}

private enum TopBarActionLabContext: String, CaseIterable, Identifiable, Hashable, TopBarActionLabTitledOption {
    case review
    case notes
    case personal
    case collection
    var id: String { rawValue }
    var title: String {
        switch self {
        case .review: return "回顾"
        case .notes: return "笔记"
        case .personal: return "我的"
        case .collection: return "书单"
        }
    }
    var trailingSystemImage: String { self == .notes ? "arrow.up.arrow.down" : "ellipsis" }
    var trailingAccessibilityLabel: String {
        switch self {
        case .review: return "回顾更多操作"
        case .notes: return "排序"
        case .personal: return "我的更多操作"
        case .collection: return "书单更多操作"
        }
    }
}

private enum TopBarActionLabScheme: String, CaseIterable, Identifiable, Hashable, TopBarActionLabTitledOption {
    case system
    case light
    case dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private enum TopBarActionLabMenuRole: Equatable { case add, trailing }
private enum TopBarActionLabControlStyle { case productionSegment, plain }
private protocol TopBarActionLabTitledOption { var title: String { get } }

#Preview {
    NavigationStack {
        TopBarActionStyleLabTestView()
    }
}
#endif
