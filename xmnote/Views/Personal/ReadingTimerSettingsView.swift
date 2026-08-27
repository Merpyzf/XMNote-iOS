/**
 * [INPUT]: 依赖环境注入的 ReadingTimerSettingsStore、canonical 设置组件与 Android 对齐的 ReadingTimerStartPreference
 * [OUTPUT]: 对外提供 ReadingTimerSettingsView，以统一设置结构配置每次询问、正计时或固定倒计时
 * [POS]: Views/Personal 页面壳层，作为个人设置内的阅读计时偏好页面
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 阅读计时设置页；固定模式会在用户点击开始时直接启动，保持 Android 当前行为。
struct ReadingTimerSettingsView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case askEveryTime
        case countUp
        case countdown

        var id: Self { self }

        var title: String {
            switch self {
            case .askEveryTime:
                return "每次询问"
            case .countUp:
                return "正计时"
            case .countdown:
                return "倒计时"
            }
        }
    }

    @Environment(ReadingTimerSettingsStore.self) private var settings
    @State private var mode: Mode = .askEveryTime
    @State private var countdownMinutes = 60

    var body: some View {
        XMSettingsPage {
            XMSettingsSection("默认计时方式") {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    XMSettingsGroup(presentation: mode == .countdown ? .grouped : .singleItem) {
                        XMSettingsValueMenuRow(
                            title: "计时方式",
                            value: mode.title,
                            options: Mode.allCases,
                            selection: mode,
                            optionTitle: { $0.title },
                            optionImage: { option in
                                switch option {
                                case .askEveryTime: "questionmark.circle"
                                case .countUp: "stopwatch"
                                case .countdown: "timer"
                                }
                            },
                            onSelect: { newMode in
                                mode = newMode
                                persist(mode: newMode)
                            }
                        )

                        if mode == .countdown {
                            XMSettingsDivider()
                            countdownStepper
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    Text("选择固定方式后，点击“开始阅读”会直接进入计时")
                        .font(SettingsTypography.rowDescription)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.contentEdge)
                }
            }
        }
        .navigationTitle("阅读计时")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadPreference)
        .animation(.snappy, value: mode)
    }

    /// 倒计时步进器保留业务范围和步长，仅把行视觉对齐设置系统层级。
    private var countdownStepper: some View {
        Stepper(value: $countdownMinutes, in: 1...720, step: 5) {
            HStack(spacing: Spacing.base) {
                Text("默认倒计时")
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)

                Spacer(minLength: Spacing.base)

                Text("\(countdownMinutes) 分钟")
                    .font(SettingsTypography.rowValue)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                }
            .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
        }
        .onChange(of: countdownMinutes) { _, minutes in
            settings.setPreference(.countdown(seconds: Int64(minutes * 60)))
        }
    }

    /// 将持久化偏好投影为页面控件状态，倒计时时长按分钟展示。
    private func loadPreference() {
        switch settings.preference {
        case .askEveryTime:
            mode = .askEveryTime
        case .countUp:
            mode = .countUp
        case .countdown(let seconds):
            countdownMinutes = max(1, Int(seconds / 60))
            mode = .countdown
        }
    }

    /// 根据选择写入 Android 同义 timingWay 值。
    private func persist(mode: Mode) {
        switch mode {
        case .askEveryTime:
            settings.setPreference(.askEveryTime)
        case .countUp:
            settings.setPreference(.countUp)
        case .countdown:
            settings.setPreference(.countdown(seconds: Int64(countdownMinutes * 60)))
        }
    }
}
