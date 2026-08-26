/**
 * [INPUT]: 依赖 SwiftUI、RichTextEditor/HighlightColors 色值映射
 * [OUTPUT]: 对外提供 HighlightColorPicker 高亮色板选择组件
 * [POS]: RichTextEditor 的高亮格式选择子视图，被 NoteDetailView 与富文本调试页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 高亮色板组件，展示 13 个 ARGB 色值供选择
struct HighlightColorPicker: View {

    @Binding var selectedARGB: UInt32

    private let colors: [UInt32] = Array(HighlightColors.lightToDark.keys).sorted()
    private let columns = Array(repeating: GridItem(.fixed(32), spacing: Spacing.tight), count: 7)

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.tight) {
            ForEach(Array(colors.enumerated()), id: \.element) { index, argb in
                colorDot(argb, index: index)
            }
        }
    }

    // MARK: - Color Dot

    private func colorDot(_ argb: UInt32, index: Int) -> some View {
        let isSelected = argb == selectedARGB
        return Circle()
            .fill(Color.xmResolved(HighlightColors.color(from: argb)))
            .frame(width: 28, height: 28)
            .overlay {
                if isSelected {
                    Circle()
                        .stroke(Color.selectionAccent, lineWidth: 2.5)
                        .frame(width: 34, height: 34)
                }
            }
            .onTapGesture {
                select(argb)
            }
            .accessibilityLabel("高亮颜色 \(index + 1)")
            .accessibilityValue(isSelected ? "已选择" : "未选择")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction {
                select(argb)
            }
    }

    /// 更新选择并保留既有选中色动效；VoiceOver 与触控共用同一动作入口。
    private func select(_ argb: UInt32) {
        withAnimation(.snappy) {
            selectedARGB = argb
        }
    }
}

#Preview {
    @Previewable @State var selected: UInt32 = HighlightColors.defaultHighlightColor
    HighlightColorPicker(selectedARGB: $selected)
        .padding(Spacing.screenEdge)
}
