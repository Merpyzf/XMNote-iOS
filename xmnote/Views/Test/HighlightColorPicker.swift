//
//  HighlightColorPicker.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/12.
//

import SwiftUI

/// 高亮色板组件，展示 13 个 ARGB 色值供选择
/// 可复用于正式书摘编辑页
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
