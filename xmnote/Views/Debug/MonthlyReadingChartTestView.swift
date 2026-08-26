#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 MonthlyReadingChart、DesignTokens 与四组本地固定数据，接收系统 Reduce Motion 环境值
 * [OUTPUT]: 对外提供 MonthlyReadingChartTestView（月度阅读图表完整验收台）
 * [POS]: Debug 测试页，用于复现 Android 录屏并验证多月联动、零值、文本边界、配色与减少动态效果
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 月度阅读图表测试页集中承载录屏基线和边界场景，不接入正式数据仓储。
struct MonthlyReadingChartTestView: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    @State private var selectedScenario: MonthlyReadingChartDemoScenario = .recording
    @State private var selectedPalette: MonthlyReadingChartDemoPalette = .recordingRed
    @State private var expandedMonthIDs: Set<MonthlyReadingChart.MonthID> = []
    @State private var forcesReduceMotion = false

    private var effectiveReduceMotion: Bool {
        systemReduceMotion || forcesReduceMotion
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                controlsCard
                previewCard
                timelinePlaceholderCard
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("月度阅读图表")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension MonthlyReadingChartTestView {
    var controlsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("验收控制")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("测试场景")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.textSecondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.half) {
                            ForEach(MonthlyReadingChartDemoScenario.allCases) { scenario in
                                scenarioButton(scenario)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("配色")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.textSecondary)

                    Picker("配色", selection: $selectedPalette) {
                        ForEach(MonthlyReadingChartDemoPalette.allCases) { palette in
                            Text(palette.title).tag(palette)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("强制减少动态效果", isOn: $forcesReduceMotion)
                    .font(AppTypography.body)
                    .tint(Color.appTint)

                HStack(spacing: Spacing.half) {
                    Button("全部展开", action: expandAll)
                    Button("全部收起", action: collapseAll)
                    Button("重置", action: reset)
                }
                .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(selectedScenario.detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("已展开 \(expandedMonthIDs.count) / \(selectedScenario.months.count)；Reduce Motion：\(effectiveReduceMotion ? "开启" : "关闭")")
                        .font(AppTypography.caption2)
                        .foregroundStyle(Color.textHint)
                        .monospacedDigit()
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var previewCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("组件预览")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                MonthlyReadingChart(
                    months: selectedScenario.months,
                    expandedMonthIDs: $expandedMonthIDs,
                    style: selectedPalette.chartStyle
                )
                .id(selectedScenario)
                .environment(
                    \.monthlyReadingChartReduceMotionOverride,
                    forcesReduceMotion ? true : nil
                )
            }
            .padding(Spacing.contentEdge)
            .background(selectedPalette.previewSurface)
        }
    }

    var timelinePlaceholderCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("阅读历程")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                Text("观察本卡片是否随上方图表高度平滑下移与回收")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(Spacing.contentEdge)
        }
    }

    /// 渲染场景选择按钮；切换动作禁用动画，防止旧数据和新数据共享过渡帧。
    func scenarioButton(_ scenario: MonthlyReadingChartDemoScenario) -> some View {
        Button {
            selectScenario(scenario)
        } label: {
            Text(scenario.title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(
                    selectedScenario == scenario ? Color.white : Color.textPrimary
                )
                .padding(.horizontal, Spacing.tight)
                .padding(.vertical, Spacing.half)
                .background(
                    selectedScenario == scenario
                        ? Color.selectionAccent
                        : Color.controlFillSecondary,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    /// 无动画切换固定场景并清空展开集合，旧组件通过稳定场景 ID 退出并取消在途任务。
    func selectScenario(_ scenario: MonthlyReadingChartDemoScenario) {
        guard selectedScenario != scenario else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expandedMonthIDs.removeAll()
            selectedScenario = scenario
        }
    }

    /// 同时展开当前场景全部月份，组件内部仍按每月独立动画处理。
    func expandAll() {
        expandedMonthIDs = Set(selectedScenario.months.map(\.id))
    }

    /// 同时收起当前场景全部月份，用于观察每日“0秒”退出中间态。
    func collapseAll() {
        expandedMonthIDs.removeAll()
    }

    /// 无动画恢复当前场景的标准收起基线，便于重复截图和录屏。
    func reset() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expandedMonthIDs.removeAll()
            forcesReduceMotion = false
        }
    }
}

/// 测试中心提供的四组确定性数据场景。
private enum MonthlyReadingChartDemoScenario: String, CaseIterable, Identifiable {
    case recording
    case multiMonth
    case zero
    case textBoundary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: "录屏同款"
        case .multiMonth: "多月联动"
        case .zero: "零时长"
        case .textBoundary: "文本边界"
        }
    }

    var detail: String {
        switch self {
        case .recording:
            "一月八条记录合计恰好 2小时47分钟，行内按 Android 规则省略分钟后的秒数"
        case .multiMonth:
            "三个自然月可同时展开；任一月份展开后，全部月份头部铺满并共用每日最大值。"
        case .zero:
            "所有时长均为零，用于检查月条全宽以及每日柱体回落到文本最小宽度"
        case .textBoundary:
            "跨年摘要、长日期和百小时数据用于检查文本测量、尾部对齐与箭头覆盖关系"
        }
    }

    var months: [MonthlyReadingChart.Month] {
        switch self {
        case .recording:
            Self.recordingMonths
        case .multiMonth:
            Self.multiMonthMonths
        case .zero:
            Self.zeroMonths
        case .textBoundary:
            Self.textBoundaryMonths
        }
    }
}

private extension MonthlyReadingChartDemoScenario {
    static let recordingMonths: [MonthlyReadingChart.Month] = [
        .init(
            id: .init(year: 2026, month: 1),
            summaryText: "1月 · 2小时47分钟",
            days: [
                .init(id: 1019, dateText: "19日", durationSeconds: 17 * 60 + 40),
                .init(id: 1014, dateText: "14日", durationSeconds: 32 * 60 + 38),
                .init(id: 1013, dateText: "13日", durationSeconds: 30 * 60 + 35),
                .init(id: 1012, dateText: "12日", durationSeconds: 51 * 60 + 39),
                .init(id: 1011, dateText: "11日", durationSeconds: 42),
                .init(id: 1008, dateText: "8日", durationSeconds: 29 * 60 + 42),
                .init(id: 1006, dateText: "6日", durationSeconds: 2 * 60 + 34),
                .init(id: 1004, dateText: "4日", durationSeconds: 1 * 60 + 30),
            ]
        ),
    ]

    static let multiMonthMonths: [MonthlyReadingChart.Month] = [
        .init(
            id: .init(year: 2026, month: 3),
            summaryText: "3月 · 1小时45分钟",
            days: [
                .init(id: 3003, dateText: "23日", durationSeconds: 3_600),
                .init(id: 3002, dateText: "18日", durationSeconds: 1_800),
                .init(id: 3001, dateText: "2日", durationSeconds: 900),
            ]
        ),
        .init(
            id: .init(year: 2026, month: 2),
            summaryText: "2月 · 2小时11分钟",
            days: [
                .init(id: 2003, dateText: "28日", durationSeconds: 7_200),
                .init(id: 2002, dateText: "16日", durationSeconds: 600),
                .init(id: 2001, dateText: "1日", durationSeconds: 60),
            ]
        ),
        .init(
            id: .init(year: 2025, month: 12),
            summaryText: "2025年12月 · 1小时",
            days: [
                .init(id: 1202, dateText: "31日", durationSeconds: 2_400),
                .init(id: 1201, dateText: "3日", durationSeconds: 1_200),
            ]
        ),
    ]

    static let zeroMonths: [MonthlyReadingChart.Month] = [
        .init(
            id: .init(year: 2026, month: 2),
            summaryText: "2月 · 0秒",
            days: [
                .init(id: 2202, dateText: "2日", durationSeconds: 0),
                .init(id: 2201, dateText: "1日", durationSeconds: 0),
            ]
        ),
    ]

    static let textBoundaryMonths: [MonthlyReadingChart.Month] = [
        .init(
            id: .init(year: 2024, month: 12),
            summaryText: "2024年12月 · 123小时59分钟",
            days: [
                .init(id: 2412, dateText: "12月31日（周二）", durationSeconds: 100 * 3_600),
                .init(id: 2411, dateText: "12月30日（周一）", durationSeconds: 23 * 3_600 + 58 * 60 + 18),
                .init(id: 2410, dateText: "12月29日（周日）", durationSeconds: 42),
            ]
        ),
    ]
}

/// 演示页配色只负责验证样式注入，不进入正式业务主题映射。
private enum MonthlyReadingChartDemoPalette: String, CaseIterable, Identifiable {
    case recordingRed
    case coolBlue

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordingRed: "录屏红"
        case .coolBlue: "冷色"
        }
    }

    var previewSurface: Color {
        switch self {
        case .recordingRed:
            Color.xmAdaptive(
                light: Color.xmHex(0xF4DEDE),
                dark: Color.xmHex(0x302426)
            )
        case .coolBlue:
            Color.xmAdaptive(
                light: Color.xmHex(0xE5EEF8),
                dark: Color.xmHex(0x202932)
            )
        }
    }

    var chartStyle: MonthlyReadingChartStyle {
        switch self {
        case .recordingRed:
            MonthlyReadingChartStyle(
                monthTrackColor: Color.xmAdaptive(
                    light: Color.xmHex(0xE9C7C8),
                    dark: Color.xmHex(0x4A3033)
                ),
                monthBarColors: [
                    Color.xmAdaptive(light: Color.xmHex(0xEAA4A6), dark: Color.xmHex(0x9C5559)),
                    Color.xmAdaptive(light: Color.xmHex(0xD96569), dark: Color.xmHex(0xB85A5F)),
                ],
                collapsedSummaryColor: .white,
                expandedSummaryColor: .textSecondary,
                collapsedArrowColor: .white,
                expandedArrowColor: .iconSecondary,
                dailyBarColors: [
                    Color.xmAdaptive(light: Color.xmHex(0xF1BFC0), dark: Color.xmHex(0x7D484C)),
                    Color.xmAdaptive(light: Color.xmHex(0xDE7477), dark: Color.xmHex(0xA95459)),
                ],
                dailyDateColor: .white,
                dailyDurationColor: .white
            )
        case .coolBlue:
            MonthlyReadingChartStyle(
                monthTrackColor: Color.xmAdaptive(
                    light: Color.xmHex(0xC7D7E8),
                    dark: Color.xmHex(0x2B3A49)
                ),
                monthBarColors: [
                    Color.xmAdaptive(light: Color.xmHex(0x8FC6E8), dark: Color.xmHex(0x366D91)),
                    Color.xmAdaptive(light: Color.xmHex(0x397FB4), dark: Color.xmHex(0x3D87B9)),
                ],
                collapsedSummaryColor: .white,
                expandedSummaryColor: .textSecondary,
                collapsedArrowColor: .white,
                expandedArrowColor: .iconSecondary,
                dailyBarColors: [
                    Color.xmAdaptive(light: Color.xmHex(0xB6D9EF), dark: Color.xmHex(0x31566F)),
                    Color.xmAdaptive(light: Color.xmHex(0x559AC8), dark: Color.xmHex(0x3E7EA8)),
                ],
                dailyDateColor: .white,
                dailyDurationColor: .white
            )
        }
    }
}

#Preview {
    NavigationStack {
        MonthlyReadingChartTestView()
    }
}
#endif
