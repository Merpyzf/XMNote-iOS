/**
 * [INPUT]: 依赖 BookshelfDisplaySetting 持久化配置、BookshelfDimension 与 SwiftUI Sheet 展示能力
 * [OUTPUT]: 对外提供 BookshelfDisplaySettingSheet，按书架维度调整布局、排序、分区与标题展示偏好
 * [POS]: Book 模块业务 Sheet，服务首页书架显示设置入口，不直接承担数据库读写
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书架显示设置 Sheet，按当前维度调整显示偏好，写入动作由外层 ViewModel 经 Repository 持久化。
struct BookshelfDisplaySettingSheet: View {
    let dimension: BookshelfDimension
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

                    Stepper(value: $setting.columnCount, in: 2...6) {
                        HStack {
                            Text("网格列数")
                            Spacer()
                            Text("\(setting.columnCount)列")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(setting.layoutMode == .list)

                    Toggle("显示书摘数量", isOn: $setting.showsNoteCount)

                    Picker("书名展示", selection: $setting.titleDisplayMode) {
                        ForEach(BookshelfTitleDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Section("排序") {
                    Picker("排序依据", selection: $setting.sortCriteria) {
                        ForEach(BookshelfSortCriteria.available(for: dimension), id: \.self) { criteria in
                            Text(criteria.title).tag(criteria)
                        }
                    }

                    if setting.sortCriteria != .custom {
                        Picker("排序方向", selection: $setting.sortOrder) {
                            ForEach(BookshelfSortOrder.allCases, id: \.self) { order in
                                Text(order.title).tag(order)
                            }
                        }
                    }

                    Toggle("按首字母分区", isOn: $setting.isSectionEnabled)
                        .disabled(!supportsSectionToggle)

                    Text(footerText)
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

    private var supportsSectionToggle: Bool {
        switch dimension {
        case .default, .author:
            return true
        case .status, .tag, .source, .rating, .press:
            return false
        }
    }

    private var footerText: String {
        if [.status, .tag, .source].contains(dimension), setting.sortCriteria == .custom {
            return "当前维度支持整项长按拖拽排序，结束后一次性写入顺序。"
        }
        if dimension == .default, setting.sortCriteria == .custom {
            return "默认书架支持编辑态整项长按拖拽排序。"
        }
        return "条件排序仅影响当前维度展示，不启用拖拽排序。"
    }
}
