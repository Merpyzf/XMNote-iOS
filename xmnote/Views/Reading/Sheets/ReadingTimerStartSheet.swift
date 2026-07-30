import SwiftUI

/**
 * [INPUT]: 依赖 ReadingTimerStartDraft 输出启动计时方式与倒计时时长
 * [OUTPUT]: 对外提供 ReadingTimerStartSheet 与 ReadingTimerStartDraft，承接阅读计时开始前的正计时/倒计时选择
 * [POS]: Reading/Sheets 业务弹层，负责阅读计时启动配置，避免把倒计时设置堆叠到主计时页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读计时启动配置草稿，`countdownSeconds = 0` 表示正计时。
struct ReadingTimerStartDraft {
    let countdownSeconds: Int64
}

/// 阅读计时启动弹层，提供正计时与倒计时两种 Android 对齐的计时方式。
struct ReadingTimerStartSheet: View {
    let onStart: (ReadingTimerStartDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ReadingTimerStartMode = .countUp
    @State private var countdownMinutes = 60

    private let presetMinutes = [1, 15, 30, 45, 60, 90]

    var body: some View {
        NavigationStack {
            Form {
                Section("计时方式") {
                    Picker("计时方式", selection: $mode) {
                        ForEach(ReadingTimerStartMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .countdown {
                    Section("阅读时长") {
                        Stepper(value: $countdownMinutes, in: 1...720, step: 5) {
                            HStack {
                                Text("时长")
                                    .font(AppTypography.body)
                                Spacer(minLength: Spacing.base)
                                Text("\(countdownMinutes) 分钟")
                                    .font(AppTypography.bodyMedium)
                                    .foregroundStyle(Color.textPrimary)
                                    .monospacedDigit()
                            }
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: Spacing.cozy)], spacing: Spacing.cozy) {
                            ForEach(presetMinutes, id: \.self) { minutes in
                                Button {
                                    countdownMinutes = minutes
                                } label: {
                                    Text("\(minutes) 分钟")
                                        .font(AppTypography.captionMedium)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                        .foregroundStyle(minutes == countdownMinutes ? Color.surfacePage : Color.textPrimary)
                                        .background(
                                            Capsule()
                                                .fill(minutes == countdownMinutes ? Color.textPrimary : Color.surfaceCard)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, Spacing.tiny)
                    }
                }
            }
            .navigationTitle("开始阅读计时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") {
                        submit()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.surfacePage)
    }

    private func submit() {
        let countdownSeconds = mode == .countdown ? Int64(countdownMinutes * 60) : 0
        onStart(ReadingTimerStartDraft(countdownSeconds: countdownSeconds))
        dismiss()
    }
}

private enum ReadingTimerStartMode: CaseIterable, Hashable {
    case countUp
    case countdown

    var title: String {
        switch self {
        case .countUp:
            return "正计时"
        case .countdown:
            return "倒计时"
        }
    }
}
