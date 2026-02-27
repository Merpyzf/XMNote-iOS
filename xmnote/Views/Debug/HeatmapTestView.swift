#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 HeatmapTestViewModel 提供测试数据，依赖 HeatmapChart 组件
 * [OUTPUT]: 对外提供 HeatmapTestView（热力图测试页面）
 * [POS]: Debug 测试页，验证热力图 8 个场景的渲染、交互与颜色适配
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

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.double) {
                scenarioPickerSection
                heatmapSection
                selectedDaySection
                colorLegendSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.windowBackground)
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
                            withAnimation(.snappy) {
                                viewModel.loadScenario(scenario)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            viewModel.currentScenario == scenario
                                ? Color.brand : Color.bgSecondary
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

// MARK: - 热力图展示

private extension HeatmapTestContentView {

    var heatmapSection: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text("热力图")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)
            HeatmapChart(
                days: viewModel.days,
                earliestDate: viewModel.earliestDate
            ) { day in
                withAnimation(.snappy) {
                    viewModel.selectedDay = day
                }
            }
            .padding(Spacing.base)
            .background(Color.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
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
                    infoRow("等级", value: "\(day.level)")
                }
                .padding(Spacing.base)
                .background(Color.contentBackground)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
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
            .background(Color.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
        }
    }
}
#endif
