#if DEBUG
/**
 * [INPUT]: 依赖 SwiftUI 原生 Tab(role: .search)、searchable、searchFocused 与 Debug 页面基础容器，提供可调延迟和静态搜索结果样本
 * [OUTPUT]: 对外提供 SearchableSystemBugReproView，集中复现 iOS 26 Search Tab 在收焦点后延迟写入 text 时的系统搜索框布局跳变
 * [POS]: Debug 测试页，仅用于测试中心验证系统 searchable 控件行为，不接入正式搜索仓储或业务 ViewModel
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 系统 searchable 最小复现入口，通过独立 fullScreenCover 隔离测试中心外层导航环境。
struct SearchableSystemBugReproView: View {
    @State private var isExperimentPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.double) {
                summarySection
                checklistSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .background(Color.surfacePage)
        .navigationTitle("Searchable 系统复现")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isExperimentPresented) {
            SearchableSystemBugExperimentShell {
                isExperimentPresented = false
            }
        }
    }

    private var summarySection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Label("iOS 26 Search Tab 最小复现", systemImage: "magnifyingglass.circle")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Text("独立壳层只保留 Tab(role: .search)、.searchable、.searchFocused 和延迟写入 text，用来判断底部系统搜索框的图标与文字 inset 是否跨帧重建。")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    isExperimentPresented = true
                } label: {
                    Label("打开独立复现壳", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .font(AppTypography.captionMedium)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var checklistSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("观察目标")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                ReproBulletRow(text: "点击“自动复现”，观察底部搜索框从占位到“打印机”的瞬间")
                ReproBulletRow(text: "如果文字先出现，放大镜随后插入并推动文字右移，即可证明系统控件内部布局跨帧重建")
                ReproBulletRow(text: "切换不同延迟，判断延迟只能缓解还是能完全消除")
            }
            .padding(Spacing.contentEdge)
        }
    }
}

private struct SearchableSystemBugExperimentShell: View {
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab: ReproTab = .control
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var selectedDelay: ReproDelay = .milliseconds260
    @State private var isShowingResults = false
    @State private var eventLog: [String] = []
    @State private var eventSequence = 0
    @State private var reproTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("控制", systemImage: "slider.horizontal.3", value: .control) {
                NavigationStack {
                    controlTab
                        .navigationTitle("系统搜索复现")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }

            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack {
                    searchTab
                        .navigationTitle("搜索")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .searchable(text: $searchText, isPresented: $isSearchPresented, prompt: "搜索本地内容")
        .searchFocused($isSearchFieldFocused)
        .onSubmit(of: .search) {
            showResults(for: searchText, reason: "键盘 Search 提交")
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(AppTypography.title3)
                    .foregroundStyle(Color.iconSecondary, Color.controlFillSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭系统搜索复现")
            .padding(.top, Spacing.cozy)
            .padding(.trailing, Spacing.screenEdge)
        }
        .onDisappear {
            reproTask?.cancel()
        }
    }

    private var controlTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.double) {
                controlsSection
                stateSection
                eventLogSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom, Spacing.actionReserved)
        }
        .background(Color.surfacePage)
    }

    private var searchTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.double) {
                historySection
                resultSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom, Spacing.actionReserved * 3)
        }
        .scrollDismissesKeyboard(.never)
        .background(Color.surfacePage)
    }
}

private extension SearchableSystemBugExperimentShell {
    var controlsSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("复现控制")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                Picker("写入延迟", selection: $selectedDelay) {
                    ForEach(ReproDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: Spacing.base) {
                    Button {
                        runScenario(keyword: "打印机", reason: "自动复现")
                    } label: {
                        Label("自动复现", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        resetExperiment()
                    } label: {
                        Label("重置", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .font(AppTypography.captionMedium)

                Text("自动复现会切到搜索 Tab，先呈现并聚焦系统搜索框，600ms 后收焦点，再按当前延迟写入关键词")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.contentEdge)
        }
    }

    var stateSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("当前状态")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                VStack(spacing: Spacing.half) {
                    stateRow(title: "searchText", value: searchText.isEmpty ? "空" : searchText)
                    stateRow(title: "isSearchPresented", value: isSearchPresented ? "true" : "false")
                    stateRow(title: "isSearchFieldFocused", value: isSearchFieldFocused ? "true" : "false")
                    stateRow(title: "延迟", value: selectedDelay.title)
                    stateRow(title: "Reduce Motion", value: reduceMotion ? "开启" : "关闭")
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var eventLogSection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("事件日志")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                if eventLog.isEmpty {
                    Text("暂无事件")
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    ForEach(eventLog, id: \.self) { event in
                        Text(event)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    var historySection: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("历史词按钮")
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: Spacing.half) {
                    keywordButton("打印机")
                    keywordButton("打")
                }

                Text("按钮只触发系统焦点释放与延迟写入，不执行真实搜索")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(Spacing.contentEdge)
        }
    }

    @ViewBuilder
    var resultSection: some View {
        if isShowingResults {
            LazyVStack(alignment: .leading, spacing: Spacing.base) {
                ForEach(SearchableSystemBugSampleResult.samples) { result in
                    resultRow(result)
                }
            }
        } else {
            CardContainer {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("等待复现")
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Text("点击历史词或在控制 Tab 点击自动复现后，这里会显示静态结果")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.contentEdge)
            }
        }
    }

    func stateRow(title: String, value: String) -> some View {
        HStack(spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
    }

    func keywordButton(_ keyword: String) -> some View {
        Button {
            runScenario(keyword: keyword, reason: "历史词按钮")
        } label: {
            Text(keyword)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Spacing.base)
                .frame(minHeight: 34)
                .background(Color.controlFillSecondary.opacity(0.58), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复现关键词 \(keyword)")
    }

    func resultRow(_ result: SearchableSystemBugSampleResult) -> some View {
        Button { } label: {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Text(result.excerpt)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)

                HStack {
                    Text(result.source)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(result.date)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .padding(Spacing.contentEdge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(result.excerpt)
    }

    /// 运行一次最小复现序列；任务固定在 MainActor，连续触发会取消旧序列以避免日志和状态交错。
    func runScenario(keyword: String, reason: String) {
        reproTask?.cancel()
        resetSearchStateForNextRun()
        selectedTab = .search
        isSearchPresented = true
        isSearchFieldFocused = true
        record("\(reason)：切到 Search Tab 并聚焦系统搜索框")

        reproTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
                try Task.checkCancellation()
                isSearchFieldFocused = false
                record("收焦点：isSearchFieldFocused = false")

                try await sleepIfNeeded(nanoseconds: selectedDelay.nanoseconds)
                try Task.checkCancellation()
                searchText = keyword
                record("写入 text：\(keyword)")

                isShowingResults = true
                record("展示静态结果")
                reproTask = nil
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    /// 清空本轮状态，但保留用户选择的延迟参数，方便重复对照。
    func resetExperiment() {
        reproTask?.cancel()
        resetSearchStateForNextRun()
        selectedTab = .search
        isSearchPresented = true
        record("重置：清空 text 和结果")
    }

    func resetSearchStateForNextRun() {
        searchText = ""
        isShowingResults = false
    }

    func showResults(for rawKeyword: String, reason: String) {
        let keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        isSearchFieldFocused = false
        isShowingResults = true
        record("\(reason)：\(keyword)")
    }

    func sleepIfNeeded(nanoseconds: UInt64) async throws {
        guard nanoseconds > 0 else { return }
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    func record(_ message: String) {
        eventSequence += 1
        eventLog.insert("#\(eventSequence) \(message)", at: 0)
        if eventLog.count > 8 {
            eventLog.removeLast(eventLog.count - 8)
        }
    }
}

private struct ReproBulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            Image(systemName: "checkmark.circle")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.brand)
                .padding(.top, 2)

            Text(text)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum ReproTab: Hashable {
    case control
    case search
}

private enum ReproDelay: Int, CaseIterable, Identifiable {
    case milliseconds0 = 0
    case milliseconds60 = 60
    case milliseconds180 = 180
    case milliseconds260 = 260
    case milliseconds320 = 320

    var id: Int { rawValue }

    var title: String {
        "\(rawValue)ms"
    }

    var nanoseconds: UInt64 {
        UInt64(rawValue) * 1_000_000
    }
}

private struct SearchableSystemBugSampleResult: Identifiable {
    let id: Int
    let excerpt: String
    let source: String
    let date: String

    static let samples: [SearchableSystemBugSampleResult] = [
        .init(
            id: 1,
            excerpt: "要把重心放在办公输出设备（如复印机、打印机等）上。具体来说，我们想让它推出第一台台式激光打印机。",
            source: "《定位》",
            date: "2025/01/16"
        ),
        .init(
            id: 2,
            excerpt: "对于公司来说，打印机的消费者是采购部门，用户则是员工，这往往导致成本比品质拥有更高权重。",
            source: "《这才是用户体验设计》",
            date: "2024/03/24"
        ),
        .init(
            id: 3,
            excerpt: "她的父亲在惠普创立了打印机部门，曾有出任首席执行官的机会。",
            source: "《安卓传奇》",
            date: "2023/09/30"
        )
    ]
}

#Preview {
    NavigationStack {
        SearchableSystemBugReproView()
    }
}
#endif
