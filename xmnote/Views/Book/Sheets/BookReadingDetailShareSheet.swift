/**
 * [INPUT]: 依赖 BookReadingDetailContent、七项分享设置、ReadCalendarShareImageRenderer、XMActivityShareSheet 与 InteractionMetrics
 * [OUTPUT]: 对外提供随内容滚动的单向氛围背景 BookReadingDetailShareSheet 和 BookReadingDetailShareContent，预览并生成同构阅读详情长图
 * [POS]: Views/Book/Sheets 阅读详情分享业务 Sheet，临时文件生命周期在此收口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 阅读详情长图 Sheet；七项开关即时持久化，预览和最终导出消费同一个内容组件。
struct BookReadingDetailShareSheet: View {
    let snapshot: BookReadingDetailSnapshot
    let theme: BookReadingDetailTheme
    let onSettingChange: (BookReadingDetailShareSetting) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var setting: BookReadingDetailShareSetting
    @State private var expandedMonthIDs: Set<MonthlyReadingChart.MonthID>
    @State private var generatedURL: URL?
    @State private var isGenerating = false
    @State private var isShowingOptions = false
    @State private var errorMessage: String?

    /// 注入页面当前显示状态，使长图保留月图已展开月份和封面主题背景。
    init(
        snapshot: BookReadingDetailSnapshot,
        theme: BookReadingDetailTheme,
        setting: BookReadingDetailShareSetting,
        expandedMonthIDs: Set<MonthlyReadingChart.MonthID>,
        onSettingChange: @escaping (BookReadingDetailShareSetting) -> Void
    ) {
        self.snapshot = snapshot
        self.theme = theme
        self.onSettingChange = onSettingChange
        _setting = State(initialValue: setting)
        _expandedMonthIDs = State(initialValue: expandedMonthIDs)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.neutralBackground
                    .ignoresSafeArea()

                GeometryReader { geometry in
                    let topSafeAreaExtent = max(geometry.safeAreaInsets.top, 0)

                    ScrollView {
                        VStack(spacing: Spacing.none) {
                            BookReadingDetailContent(
                                snapshot: snapshot,
                                mode: .share(setting),
                                theme: theme,
                                ratingValue: .constant(Double(snapshot.book.score) / 10),
                                expandedMonthIDs: $expandedMonthIDs
                            )
                            .padding(.horizontal, Spacing.screenEdge)
                            .padding(.top, Spacing.cozy + topSafeAreaExtent)
                            .padding(.bottom, Spacing.double)
                            .frame(maxWidth: .infinity)

                            if let errorMessage {
                                Text(errorMessage)
                                    .font(AppTypography.footnote)
                                    .foregroundStyle(Color.feedbackError)
                                    .padding(.horizontal, Spacing.screenEdge)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .background(alignment: .top) {
                            BookReadingDetailAtmosphere(theme: theme)
                        }
                    }
                    .scrollBounceBehavior(.always)
                    .ignoresSafeArea(.container, edges: [.top, .bottom])
                }
            }
            .safeAreaInset(edge: .bottom, spacing: Spacing.none) {
                bottomBar
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.vertical, Spacing.cozy)
            }
            .navigationTitle("分享阅读详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(isGenerating)
                }
            }
        }
        .interactiveDismissDisabled(isGenerating)
        .sheet(isPresented: $isShowingOptions) {
            optionsSheet
        }
        .sheet(
            isPresented: Binding(
                get: { generatedURL != nil },
                set: { if !$0 { discardGeneratedFile() } }
            )
        ) {
            if let generatedURL {
                XMActivityShareSheet(activityItems: [generatedURL])
            }
        }
        .onDisappear { discardGeneratedFile() }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if #available(iOS 26.0, *) {
            bottomBarContent
                .glassEffect(.regular, in: .capsule)
        } else {
            bottomBarContent
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var bottomBarContent: some View {
        HStack(spacing: Spacing.cozy) {
            Button {
                isShowingOptions = true
            } label: {
                Label("内容", systemImage: "slider.horizontal.3")
                    .font(AppTypography.subheadlineMedium)
                    .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            Button(action: generate) {
                Label(
                    isGenerating ? "正在生成…" : "分享长图",
                    systemImage: isGenerating ? "photo.badge.arrow.down" : "square.and.arrow.up"
                )
                .font(AppTypography.subheadlineSemibold)
                .frame(
                    maxWidth: .infinity,
                    minHeight: InteractionMetrics.minimumTouchTarget
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGenerating)
        }
        .padding(Spacing.half)
    }

    private var optionsSheet: some View {
        NavigationStack {
            Form {
                Section("分享内容") {
                    Toggle("书籍属性", isOn: binding(\.showsBookAttributes))
                    Toggle("书籍简介", isOn: binding(\.showsBookSummary))
                    Toggle("热力图", isOn: binding(\.showsHeatmap))
                    Toggle("阅读分析", isOn: binding(\.showsReadingAnalytics))
                    Toggle("月度图表", isOn: binding(\.showsMonthlyChart))
                    Toggle("阅读历程", isOn: binding(\.showsReadingTimeline))
                    Toggle("应用标识", isOn: binding(\.showsAppIdentity))
                }
            }
            .navigationTitle("分享内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { isShowingOptions = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// 将单项开关合并回完整设置，预览和持久化在同一变更帧更新。
    private func binding(
        _ keyPath: WritableKeyPath<BookReadingDetailShareSetting, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { setting[keyPath: keyPath] },
            set: { value in
                setting[keyPath: keyPath] = value
                onSettingChange(setting)
            }
        )
    }

    /// 主 Actor 上快照 SwiftUI 内容并写入独立临时文件；重复生成前先回收上一文件。
    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        Task { @MainActor in
            defer { isGenerating = false }
            do {
                discardGeneratedFile()
                generatedURL = try ReadCalendarShareImageRenderer.renderPNG(
                    content: BookReadingDetailShareContent(
                        snapshot: snapshot,
                        setting: setting,
                        theme: theme,
                        expandedMonthIDs: expandedMonthIDs
                    )
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 删除本 Sheet 创建的单个临时长图，不扩大到其他缓存或分享任务。
    private func discardGeneratedFile() {
        guard let generatedURL else { return }
        ReadCalendarShareImageRenderer.discardTemporaryFile(generatedURL)
        self.generatedURL = nil
    }
}

/// 固定 390pt 内容宽度的分享载体；高度由同构内容自然撑开，避免截断简介与展开月份。
struct BookReadingDetailShareContent: View {
    let snapshot: BookReadingDetailSnapshot
    let setting: BookReadingDetailShareSetting
    let theme: BookReadingDetailTheme
    let expandedMonthIDs: Set<MonthlyReadingChart.MonthID>

    var body: some View {
        BookReadingDetailContent(
            snapshot: snapshot,
            mode: .share(setting),
            theme: theme,
            ratingValue: .constant(Double(snapshot.book.score) / 10),
            expandedMonthIDs: .constant(expandedMonthIDs)
        )
        .padding(Spacing.double)
        .frame(width: 390, alignment: .top)
        .background(alignment: .top) {
            BookReadingDetailAtmosphere(theme: theme)
        }
    }
}
