/**
 * [INPUT]: 依赖 SwiftUI Menu/Label 渲染能力与 DesignTokens 菜单前景语义色
 * [OUTPUT]: 对外提供 XMMenuLabel 与 View.xmMenuNeutralTint()，统一普通菜单项与选中菜单项的中性色视觉表达
 * [POS]: UIComponents/Foundation 的菜单视觉样式入口，被生产路径 Menu、contextMenu 与设置值菜单复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 统一菜单项标签，用中性色承接普通动作，并在保留语义图标前提下用尾部 checkmark 表达选中状态。
struct XMMenuLabel: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool

    /// 注入菜单标题、普通图标与选中态，生成与系统菜单对齐的中性 Label。
    init(
        _ title: String,
        systemImage: String? = nil,
        isSelected: Bool = false
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
    }

    var body: some View {
        HStack(spacing: Spacing.base) {
            if let systemImage {
                Image(systemName: systemImage)
            }

            Text(title)
                .fontWeight(fontWeight)

            if isSelected {
                Spacer(minLength: Spacing.base)
                Image(systemName: "checkmark")
            }
        }
        .foregroundStyle(foregroundStyle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fontWeight: Font.Weight {
        isSelected ? .semibold : .medium
    }

    private var foregroundStyle: Color {
        isSelected ? Color.menuSelectedForeground : Color.menuActionForeground
    }
}

extension View {
    /// 将菜单局部 tint 收敛为中性色，避免继承根视图品牌色导致所有菜单图标泛绿。
    func xmMenuNeutralTint() -> some View {
        tint(Color.menuActionForeground)
    }
}
