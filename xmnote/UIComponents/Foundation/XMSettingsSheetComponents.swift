/**
 * [INPUT]: 依赖 DesignTokens、TopBarActionIcon 与 SwiftUI Menu/Toggle/Button 等系统控件
 * [OUTPUT]: 对外提供 XMSettingsPageScaffold、XMSettingsGroupCard 与通用设置行组件
 * [POS]: UIComponents/Foundation 的通用设置 Sheet 组件，统一业务设置页标题栏、分组卡片与行样式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 通用设置 Sheet 布局常量，和现有书架显示设置保持同一体量。
enum XMSettingsSheetLayout {
    static let titleHorizontalReserve: CGFloat = Spacing.actionReserved + Spacing.base
    static let closeVisualSize: CGFloat = 32
    static let chromeMinHeight: CGFloat = Spacing.actionReserved
    static let menuValueMinWidth: CGFloat = Spacing.actionReserved * 2
}

/// 通用设置 Sheet 页面骨架，提供居中标题、可选副标题与右侧关闭按钮。
struct XMSettingsPageScaffold<Content: View>: View {
    let title: String
    let subtitle: String?
    let onClose: () -> Void
    let content: Content

    /// 注入标题、关闭动作与页面内容。
    init(
        title: String,
        subtitle: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        VStack(spacing: Spacing.none) {
            topChrome

            ScrollView {
                content
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceSheet.ignoresSafeArea())
    }

    private var topChrome: some View {
        ZStack {
            HStack {
                Color.clear
                    .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)

                Spacer(minLength: Spacing.none)

                closeButton
            }
            .frame(minHeight: XMSettingsSheetLayout.chromeMinHeight)

            VStack(spacing: Spacing.micro) {
                Text(title)
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, XMSettingsSheetLayout.titleHorizontalReserve)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.comfortable)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            TopBarActionIcon(
                systemName: "xmark",
                iconSize: 13,
                containerSize: XMSettingsSheetLayout.closeVisualSize,
                weight: .bold,
                foregroundColor: .textSecondary
            )
            .background(Color.controlFillSecondary.opacity(0.82), in: Circle())
            .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭")
    }
}

/// 设置分组卡片，统一业务设置页的表层、圆角与内部边距。
struct XMSettingsGroupCard<Content: View>: View {
    let content: Content

    /// 注入设置行内容，构造无描边分组卡片。
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.half)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
    }
}

/// 行内值菜单设置项，适合排序、规则、配色等离散选项。
struct XMSettingsValueMenuRow<Option: Hashable>: View {
    let title: String
    let value: String
    let options: [Option]
    let selection: Option
    let optionTitle: (Option) -> String
    let optionImage: (Option) -> String?
    let onSelect: (Option) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Spacing.base)

            Menu {
                Picker(title, selection: selectionBinding) {
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
            .accessibilityLabel("\(title)，当前\(value)")
            .accessibilityHint("打开选项菜单")
        }
        .frame(minHeight: 52)
    }

    private var valueControl: some View {
        HStack(spacing: Spacing.half) {
            Text(value)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textHint)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .contentTransition(.opacity)

            Image(systemName: "chevron.down")
                .font(AppTypography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.textHint)
        }
        .padding(.leading, Spacing.base)
        .frame(
            minWidth: XMSettingsSheetLayout.menuValueMinWidth,
            minHeight: Spacing.actionReserved,
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
        reduceMotion ? nil : .smooth(duration: 0.13)
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

/// 右侧开关设置行，保持偏好设置的紧凑行高。
struct XMSettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(Color.brand)
        .frame(minHeight: 52)
    }
}

/// 可跳转/弹出子选择器的设置行，右侧展示当前摘要与 chevron。
struct XMSettingsNavigationRow: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: Spacing.base)

                Text(value)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textHint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.textHint)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，当前\(value)")
    }
}
