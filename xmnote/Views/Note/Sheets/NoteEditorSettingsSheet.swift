/**
 * [INPUT]: 依赖 NoteEditorSettings 提供书摘编辑设置状态，依赖 DesignTokens 与 TopBarBackButton 承接 iOS 原生设置面板样式
 * [OUTPUT]: 对外提供 NoteEditorSettingsSheet，统一承载书摘编辑设置项
 * [POS]: Views/Note/Sheets 的业务设置弹层，替代顶部二级菜单直选行为
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书摘编辑设置面板，集中承载布局、OCR 入口与屏幕行为配置。
struct NoteEditorSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: NoteEditorSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("布局模式", selection: $settings.layoutModeRawValue) {
                        ForEach(NoteEditorLayoutMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)

                    Toggle("连续编辑（保存后继续下一条）", isOn: $settings.continueEditEnabled)
                } header: {
                    Text("编辑模式")
                } footer: {
                    let mode = NoteEditorLayoutMode(rawValue: settings.layoutModeRawValue) ?? .classic
                    Text(mode.subtitle)
                }

                Section("OCR 入口") {
                    Picker("入口样式", selection: $settings.ocrEntryModeRawValue) {
                        ForEach(NoteEditorOCREntryMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                }

                Section("屏幕行为") {
                    Toggle("保持屏幕常亮", isOn: $settings.keepScreenOnEnabled)

                    Picker("自动调暗", selection: $settings.autoDimSeconds) {
                        ForEach(NoteEditorSettings.autoDimSecondOptions, id: \.self) { seconds in
                            Text(NoteEditorSettings.autoDimDisplayTitle(seconds: seconds))
                                .tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                    .xmMenuNeutralTint()

                    if settings.autoDimSeconds > 0 {
                        VStack(alignment: .leading, spacing: Spacing.cozy) {
                            Text("调暗亮度 \(Int(settings.autoDimBrightness * 100))%")
                                .font(AppTypography.footnote)
                                .foregroundStyle(Color.textSecondary)
                            Slider(
                                value: $settings.autoDimBrightness,
                                in: 0.1...1.0,
                                step: 0.05
                            )
                        }
                        .padding(.vertical, Spacing.half)
                    }
                }
            }
            .navigationTitle("编辑设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    TopBarBackButton {
                        dismiss()
                    }
                }
            }
        }
    }
}
