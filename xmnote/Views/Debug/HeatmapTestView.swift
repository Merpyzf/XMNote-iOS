#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 HeatmapTestViewModel 提供测试数据，依赖 HeatmapChart/CalendarHeatmap/HeatmapLegend 组件，依赖 RepositoryContainer 提供真实仓储数据
 * [OUTPUT]: 对外提供 HeatmapTestView（周热力图与 Android 阅读详情月历热力图测试页面）
 * [POS]: Debug 测试页，验证两类热力图的渲染、交互、初始定位、分段颜色与配色适配，并支持真实数据集成测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - 外壳

struct HeatmapTestView: View {
    @State private var viewModel = HeatmapTestViewModel()

    var body: some View {
        HeatmapTestContentView(viewModel: viewModel)
    }
}

// MARK: - 内容子视图

private struct HeatmapTestContentView: View {
    @Bindable var viewModel: HeatmapTestViewModel
    @Environment(RepositoryContainer.self) private var repositories

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                scenarioPickerSection
                realDataControlSection
                heatmapSection
                calendarHeatmapSection
                selectedDaySection
                colorLegendSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("热力图测试")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 场景选择器

private extension HeatmapTestContentView {

    var scenarioPickerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("测试场景")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.half) {
                    ForEach(HeatmapTestScenario.allCases) { scenario in
                        Button(scenario.rawValue) {
                            if scenario == .realData {
                                Task {
                                    await viewModel.loadRealData(using: repositories.statisticsRepository)
                                }
                            } else {
                                withAnimation(.snappy) {
                                    viewModel.loadScenario(scenario)
                                }
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.currentScenario == scenario
                                ? Color.brand : Color.controlFillSecondary
                        )
                        .foregroundStyle(
                            viewModel.currentScenario == scenario
                                ? .white : Color.textPrimary
                        )
                        .clipShape(Capsule())
                    }
                }
            }
        }
    }
}

// MARK: - 真实数据控制

private extension HeatmapTestContentView {

    @ViewBuilder
    var realDataControlSection: some View {
        if viewModel.currentScenario == .realData {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("真实数据集成测试")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                HStack(spacing: Spacing.half) {
                    Picker("统计类型", selection: $viewModel.realDataType) {
                        ForEach(HeatmapStatisticsDataType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("年份", selection: $viewModel.realDataYear) {
                        ForEach(viewModel.candidateYears, id: \.self) { year in
                            Text(year == 0 ? "全部年份" : "\(year)年").tag(year)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack(spacing: Spacing.half) {
                    Button("重新加载真实数据") {
                        Task {
                            await viewModel.loadRealData(using: repositories.statisticsRepository)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isLoadingRealData)

                    if viewModel.isLoadingRealData {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let error = viewModel.realDataError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color.feedbackWarning)
                }
            }
            .padding(Spacing.base)
            .background(Color.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        }
    }
}

// MARK: - 热力图展示

private extension HeatmapTestContentView {

    var heatmapSection: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text("热力图")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            HeatmapChart(
                days: viewModel.days,
                earliestDate: viewModel.earliestDate,
                latestDate: viewModel.latestDate,
                statisticsDataType: viewModel.statisticsDataType,
                style: .readingCard
            ) { day in
                withAnimation(.snappy) {
                    viewModel.selectedDay = day
                }
            }
            .padding(Spacing.base)
            .background(Color.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        }
    }
}

// MARK: - Android 阅读详情月历

private extension HeatmapTestContentView {
    var calendarHeatmapSection: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text("Android 阅读详情月历热力图")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            HStack(spacing: Spacing.base) {
                HStack(spacing: Spacing.compact) {
                    Text("场景")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    Picker(
                        "月历场景",
                        selection: Binding(
                            get: { viewModel.calendarScenario },
                            set: { scenario in
                                withAnimation(.snappy) {
                                    viewModel.loadCalendarScenario(scenario)
                                }
                            }
                        )
                    ) {
                        ForEach(CalendarHeatmapTestScenario.allCases) { scenario in
                            Text(scenario.rawValue).tag(scenario)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Spacer(minLength: Spacing.compact)

                HStack(spacing: Spacing.compact) {
                    Text("配色")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                    Picker("月历配色", selection: $viewModel.calendarPalette) {
                        ForEach(CalendarHeatmapTestPalette.allCases) { palette in
                            Text(palette.rawValue).tag(palette)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Text(viewModel.calendarScenario.positioningDescription)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

            VStack(spacing: Spacing.cozy) {
                if viewModel.calendarMonths.isEmpty {
                    Text("测试中心提示：CalendarHeatmap 自身未输出内容")
                        .font(.caption)
                        .foregroundStyle(Color.textHint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    CalendarHeatmap(
                        months: viewModel.calendarMonths,
                        statisticsDataType: .all,
                        style: calendarStyle
                    )
                    .transition(.opacity)
                }

                HeatmapLegend(
                    palette: calendarColorPalette,
                    style: .calendarReadingDetail
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(Spacing.base)
            .background(calendarCardBackground)
            .clipShape(
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
            )
        }
    }

    var calendarColorPalette: HeatmapColorPalette {
        switch viewModel.calendarPalette {
        case .appDefault:
            .appDefault
        case .coverRed:
            HeatmapColorPalette(
                none: Color.xmAdaptive(
                    light: Color.xmHex(0xF9EAE8),
                    dark: Color.xmHex(0x3D2928)
                ),
                veryLess: Color.xmHex(0xE4AAA5),
                less: Color.xmHex(0xD27C75),
                more: Color.xmHex(0xB64138),
                veryMore: Color.xmHex(0x8E100D)
            )
        }
    }

    var calendarStyle: CalendarHeatmapStyle {
        CalendarHeatmapStyle(
            palette: calendarColorPalette,
            monthTitleColor: .textSecondary,
            emptyDayTextColor: .textSecondary,
            activeDayTextColor: .white
        )
    }

    var calendarCardBackground: Color {
        switch viewModel.calendarPalette {
        case .appDefault:
            .surfaceCard
        case .coverRed:
            Color.xmAdaptive(
                light: Color.xmHex(0xF2D5D2),
                dark: Color.xmHex(0x312120)
            )
        }
    }
}

// MARK: - 选中日详情

private extension HeatmapTestContentView {

    @ViewBuilder
    var selectedDaySection: some View {
        if let day = viewModel.selectedDay {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text("点击反馈")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                VStack(alignment: .leading, spacing: 4) {
                    infoRow("日期", value: formatDate(day.id))
                    infoRow("阅读", value: "\(day.readSeconds)秒（\(day.readSeconds / 60)分钟）")
                    infoRow("笔记", value: "\(day.noteCount)条")
                    infoRow("打卡", value: "\(day.checkInCount)次")
                    infoRow("打卡时长", value: "\(day.checkInSeconds)秒（\(day.checkInSeconds / 60)分钟）")
                    infoRow("状态", value: day.bookStateTitles)
                    infoRow("等级", value: "\(day.level)")
                }
                .padding(Spacing.base)
                .background(Color.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(Color.textPrimary)
        }
    }

    func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - 图例验证

private extension HeatmapTestContentView {

    var colorLegendSection: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text("颜色图例")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            HStack {
                HeatmapChart.legend
                Spacer()
            }
            .padding(Spacing.base)
            .background(Color.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        }
    }
}
#endif
