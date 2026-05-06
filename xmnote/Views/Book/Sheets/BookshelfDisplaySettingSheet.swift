/**
 * [INPUT]: 依赖 BookshelfDisplaySetting 内存态配置和 SwiftUI Sheet 展示能力
 * [OUTPUT]: 对外提供 BookshelfDisplaySettingSheet，只调整书架只读展示偏好
 * [POS]: Book 模块业务 Sheet，服务首页书架显示设置入口，不承担数据库读写
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书架显示设置 Sheet，本轮只修改内存态 UI 偏好，不写入数据库或同步字段。
struct BookshelfDisplaySettingSheet: View {
    @Binding var setting: BookshelfDisplaySetting
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("显示方式") {
                    Picker("布局", selection: $setting.layoutMode) {
                        ForEach(BookshelfLayoutMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper(value: $setting.columnCount, in: 2...4) {
                        HStack {
                            Text("网格列数")
                            Spacer()
                            Text("\(setting.columnCount)列")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(setting.layoutMode == .list)

                    Toggle("显示书摘数量", isOn: $setting.showsNoteCount)
                }

                Section("排序") {
                    HStack {
                        Text("当前模式")
                        Spacer()
                        Text(setting.sortMode.title)
                            .foregroundStyle(.secondary)
                    }
                    Text("本轮只读骨架不启用拖拽排序；搜索态与聚合维度也不会提交排序写入。")
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("显示设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}
