/**
 * [INPUT]: 依赖 AppTypography、SemanticColors、XMMenuStyle 与 SwiftUI Menu/Toggle，接收本地化标题和业务值
 * [OUTPUT]: 对外提供 XMSettingsValueMenuRow 与 XMSettingsToggleRow 两类已验证复用的设置行
 * [POS]: UIComponents/Settings 的标准行族；不提供万能行，避免把业务布局压入参数集合
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

private enum XMSettingsRowLayout {
    static let minimumHeight: CGFloat = 52
    static let menuValueMinWidth: CGFloat = 88
    static let regularValueScale = 0.82
    static let valueTransitionDuration = 0.13
}

/// 行内值菜单设置项，适合排序、规则、配色等离散选项。
struct XMSettingsValueMenuRow<Option: Hashable>: View {
    let title: LocalizedStringResource
    let value: String
    let options: [Option]
    let selection: Option
    let optionTitle: (Option) -> String
    let optionImage: (Option) -> String?
    let onSelect: (Option) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.base)

            Menu {
                Picker(String(localized: title), selection: selectionBinding) {
                    ForEach(options, id: \.self) { option in
                        menuItemLabel(for: option)
                            .tag(option)
                    }
                }
            } label: {
                valueControl
            }
            .buttonStyle(.plain)
            .xmMenuNeutralTint()
            .accessibilityLabel("\(String(localized: title))，当前\(value)")
            .accessibilityHint("打开选项菜单")
        }
        .frame(minHeight: XMSettingsRowLayout.minimumHeight)
    }

    private var valueControl: some View {
        HStack(spacing: Spacing.half) {
            Text(value)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(valueLineLimit)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : XMSettingsRowLayout.regularValueScale)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)

            Image(systemName: "chevron.down")
                .font(AppTypography.caption)
                .foregroundStyle(Color.iconSecondary)
        }
        .padding(.leading, Spacing.base)
        .frame(
            minWidth: XMSettingsRowLayout.menuValueMinWidth,
            minHeight: InteractionMetrics.minimumTouchTarget,
            alignment: .trailing
        )
        .contentShape(Rectangle())
        .animation(menuValueAnimation, value: value)
    }

    private var selectionBinding: Binding<Option> {
        Binding(
            get: { selection },
            set: { newValue in
                guard newValue != selection else { return }
                onSelect(newValue)
            }
        )
    }

    private var menuValueAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: XMSettingsRowLayout.valueTransitionDuration)
    }

    private var valueLineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 1
    }

    @ViewBuilder
    private func menuItemLabel(for option: Option) -> some View {
        if let image = optionImage(option) {
            Label(optionTitle(option), systemImage: image)
        } else {
            Text(optionTitle(option))
        }
    }
}

/// 右侧开关设置行，保持偏好设置的紧凑行高与本地化入口。
struct XMSettingsToggleRow: View {
    let title: LocalizedStringResource
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Color.appTint)
        .frame(minHeight: XMSettingsRowLayout.minimumHeight)
    }
}

#Preview("设置行") {
    @Previewable @State var isEnabled = true
    @Previewable @State var selection = 0

    XMSettingsGroup {
        XMSettingsToggleRow(title: "显示阅读进度", isOn: $isEnabled)
        XMSettingsDivider()
        XMSettingsValueMenuRow(
            title: "默认排序",
            value: selection == 0 ? "最近阅读" : "书名",
            options: [0, 1],
            selection: selection,
            optionTitle: { $0 == 0 ? "最近阅读" : "书名" },
            optionImage: { $0 == 0 ? "clock" : "textformat" },
            onSelect: { selection = $0 }
        )
    }
    .padding()
    .background(Color.surfacePage)
}
