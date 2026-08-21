/**
 * [INPUT]: 依赖 BookReadingDetailSetting 与设置变更闭包
 * [OUTPUT]: 对外提供 BookReadingDetailSettingSheet，以紧凑自定义面板编辑封面色渐变背景和月图默认展开偏好
 * [POS]: Views/Book/Sheets 阅读详情业务 Sheet，不直接访问 UserDefaults
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 页面显示设置；每次开关变化立即交给 ViewModel 持久化，关闭时无需二次确认。
struct BookReadingDetailSettingSheet: View {
    let onChange: (BookReadingDetailSetting) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var setting: BookReadingDetailSetting

    /// 注入已持久化偏好与单向变更回调。
    init(
        setting: BookReadingDetailSetting,
        onChange: @escaping (BookReadingDetailSetting) -> Void
    ) {
        self.onChange = onChange
        _setting = State(initialValue: setting)
    }

    var body: some View {
        XMSettingsPageScaffold(title: "自定义", onClose: { dismiss() }) {
            XMSettingsGroupCard {
                settingRow(
                    title: "渐变背景",
                    systemImage: "circle.hexagongrid",
                    isOn: binding(\.isCoverBackgroundEnabled)
                )

                XMSettingsDivider()
                    .padding(.leading, Spacing.actionReserved)

                settingRow(
                    title: "图表默认收起",
                    systemImage: "chart.bar.xaxis",
                    isOn: binding(\.isMonthlyChartCollapsedByDefault)
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
        }
        .presentationDetents([.height(236)])
        .presentationDragIndicator(.hidden)
    }

    /// 复用系统 Toggle 语义，并补齐 Android 同状态面板的图标化信息识别。
    private func settingRow(
        title: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            Label {
                Text(title)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
            } icon: {
                Image(systemName: systemImage)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.iconPrimary)
                    .frame(width: Spacing.double)
            }
        }
        .tint(Color.brand)
        .frame(minHeight: 52)
    }

    /// 把局部布尔绑定收敛为完整设置值，避免页面层分别持久化多个键。
    private func binding(
        _ keyPath: WritableKeyPath<BookReadingDetailSetting, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { setting[keyPath: keyPath] },
            set: { value in
                setting[keyPath: keyPath] = value
                onChange(setting)
            }
        )
    }
}
