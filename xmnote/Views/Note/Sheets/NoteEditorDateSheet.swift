/**
 * [INPUT]: 依赖 SwiftUI DatePicker 与书摘创建时间 Binding
 * [OUTPUT]: 对外提供 NoteEditorDateSheet，承载创建日期和时间编辑
 * [POS]: Views/Note/Sheets 的书摘编辑日期业务 Sheet
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 使用系统图形日期选择器编辑书摘创建时间。
struct NoteEditorDateSheet: View {
    @Binding var selectedDate: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.base) {
                DatePicker(
                    "创建时间",
                    selection: $selectedDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)

                Spacer(minLength: 0)
            }
            .padding(Spacing.screenEdge)
            .navigationTitle("创建时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.textSecondary)
                    .accessibilityLabel("关闭")
                }
            }
        }
    }
}
