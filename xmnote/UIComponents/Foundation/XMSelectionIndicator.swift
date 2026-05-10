/**
 * [INPUT]: 依赖 SwiftUI、SF Symbols Magic Replace / drawOn / drawOff Symbol Effect 与项目 DesignTokens
 * [OUTPUT]: 对外提供 XMSelectionIndicator 与 XMSelectionIndicatorStyle，统一自定义选择指示器替换与绘制动效
 * [POS]: UIComponents/Foundation 的选择状态指示组件，被书架、选书、批量编辑与调试页复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 自定义选择指示器的语义形态，对应多选、单选与纯勾选三类视觉。
enum XMSelectionIndicatorStyle: String, CaseIterable, Identifiable {
    case checkbox
    case radio
    case checkmarkOnly

    var id: String { rawValue }
}

/// 稳定底座 + 选中符号替换动效的选择指示器。
struct XMSelectionIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let style: XMSelectionIndicatorStyle
    let isSelected: Bool
    let font: Font
    let showsUnselectedBase: Bool

    /// 组装选择指示器；Reduce Motion 开启时禁用符号动效，仅保留即时状态变化。
    init(
        style: XMSelectionIndicatorStyle,
        isSelected: Bool,
        font: Font,
        showsUnselectedBase: Bool? = nil
    ) {
        self.style = style
        self.isSelected = isSelected
        self.font = font
        self.showsUnselectedBase = showsUnselectedBase ?? style.defaultShowsUnselectedBase
    }

    var body: some View {
        indicator
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var indicator: some View {
        if usesMagicReplace {
            replacementIndicator
        } else if showsLayeredIndicator {
            layeredIndicator
        }
    }

    private var replacementIndicator: some View {
        Image(systemName: replacementSystemName)
            .font(font)
            .fontWeight(isSelected ? .semibold : .medium)
            .symbolRenderingMode(.palette)
            .foregroundStyle(replacementPrimaryStyle, replacementSecondaryStyle)
            .contentTransition(replacementTransition)
            .frame(width: Layout.visualSize, height: Layout.visualSize)
            .contentShape(Circle())
            .animation(reduceMotion ? nil : Layout.replacementAnimation, value: isSelected)
    }

    private var layeredIndicator: some View {
        ZStack {
            if showsBaseSymbol {
                baseSymbol
            }

            if isSelected {
                selectedSymbol
                    .transition(selectionTransition)
            }
        }
        .font(font)
        .frame(width: Layout.visualSize, height: Layout.visualSize)
        .contentShape(Circle())
        .transition(selectionTransition)
        .animation(reduceMotion ? nil : Layout.layeredAnimation, value: isSelected)
    }

    @ViewBuilder
    private var baseSymbol: some View {
        switch style {
        case .checkbox, .radio:
            Image(systemName: "circle")
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? Color.brand.opacity(0.24) : Color.textHint)
        case .checkmarkOnly:
            Image(systemName: "circle.fill")
                .fontWeight(.medium)
                .foregroundStyle(isSelected ? Color.brand.opacity(0.12) : Color.controlFillSecondary)
        }
    }

    @ViewBuilder
    private var selectedSymbol: some View {
        switch style {
        case .checkbox:
            Image(systemName: "checkmark.circle.fill")
                .fontWeight(.semibold)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.brand)
        case .radio:
            Image(systemName: "largecircle.fill.circle")
                .fontWeight(.semibold)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.brand, Color.brand.opacity(0.16))
        case .checkmarkOnly:
            Image(systemName: "checkmark")
                .fontWeight(.bold)
                .foregroundStyle(Color.brand)
        }
    }

    private var selectionTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: AnyTransition(.symbolEffect(.drawOn.byLayer)),
            removal: AnyTransition(.symbolEffect(.drawOff.byLayer))
        )
    }

    private var replacementTransition: ContentTransition {
        guard !reduceMotion else { return .identity }
        return .symbolEffect(.replace.magic(fallback: .downUp))
    }

    private var usesMagicReplace: Bool {
        showsUnselectedBase && (style == .checkbox || style == .radio)
    }

    private var showsLayeredIndicator: Bool {
        showsBaseSymbol || isSelected
    }

    private var showsBaseSymbol: Bool {
        if style == .checkmarkOnly, !showsUnselectedBase {
            return false
        }
        return showsUnselectedBase || isSelected
    }

    private var replacementSystemName: String {
        guard isSelected else { return "circle" }
        switch style {
        case .checkbox:
            return "checkmark.circle.fill"
        case .radio:
            return "largecircle.fill.circle"
        case .checkmarkOnly:
            return "checkmark"
        }
    }

    private var replacementPrimaryStyle: Color {
        guard isSelected else { return Color.textHint }
        switch style {
        case .checkbox:
            return Color.white
        case .radio:
            return Color.brand
        case .checkmarkOnly:
            return Color.brand
        }
    }

    private var replacementSecondaryStyle: Color {
        guard isSelected else { return Color.textHint }
        switch style {
        case .checkbox:
            return Color.brand
        case .radio:
            return Color.brand.opacity(0.16)
        case .checkmarkOnly:
            return Color.brand
        }
    }
}

private extension XMSelectionIndicatorStyle {
    var defaultShowsUnselectedBase: Bool {
        switch self {
        case .checkbox, .radio:
            return true
        case .checkmarkOnly:
            return false
        }
    }
}

private extension XMSelectionIndicator {
    enum Layout {
        static let visualSize: CGFloat = 30
        static let replacementAnimation = Animation.snappy(duration: 0.22)
        static let layeredAnimation = Animation.snappy(duration: 0.18)
    }
}
