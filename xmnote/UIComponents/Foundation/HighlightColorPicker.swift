/**
 * [INPUT]: 依赖 SwiftUI、UIComponents/Foundation/HighlightColors 色值映射
 * [OUTPUT]: 对外提供 HighlightColorPicker 高亮色板选择组件
 * [POS]: UIComponents/Foundation 的可复用色板选择器，被 NoteDetailView 与调试页消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 高亮色板组件，展示 13 个 ARGB 色值供选择
struct HighlightColorPicker: View {

    @Binding var selectedARGB: UInt32

    private let colors: [UInt32] = Array(HighlightColors.lightToDark.keys).sorted()
    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 10), count: 7)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(colors, id: \.self) { argb in
                colorDot(argb)
            }
        }
    }

    // MARK: - Color Dot

    private func colorDot(_ argb: UInt32) -> some View {
        let isSelected = argb == selectedARGB
        return Circle()
            .fill(Color(uiColor: HighlightColors.color(from: argb)))
            .frame(width: 28, height: 28)
            .overlay {
                if isSelected {
                    Circle()
                        .stroke(Color.brand, lineWidth: 2.5)
                        .frame(width: 34, height: 34)
                }
            }
            .onTapGesture {
                withAnimation(.snappy) {
                    selectedARGB = argb
                }
            }
    }
}

#Preview {
    @Previewable @State var selected: UInt32 = HighlightColors.defaultHighlightColor
    HighlightColorPicker(selectedARGB: $selected)
        .padding()
}
