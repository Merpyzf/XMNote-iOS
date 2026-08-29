/**
 * [INPUT]: 依赖 BookReadingDetailContent、七项分享设置、ReadCalendarShareImageRenderer、XMActivityShareSheet、XMScrollEdgeChrome 与 XMSheetConfirmationAction
 * [OUTPUT]: 对外提供系统关闭/顶部异步确认、上下 soft 滚动边缘及随内容滚动氛围背景的 BookReadingDetailShareSheet 和 BookReadingDetailShareContent，预览并生成同构阅读详情长图
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
            XMScrollEdgeChrome(
                presentation: .overlaySoft,
                edges: [.top, .bottom]
            ) {
                ScrollView {
                    VStack(spacing: Spacing.none) {
                        shareOptionsControl
                            .padding(.horizontal, Spacing.screenEdge)
                            .padding(.top, Spacing.cozy)
                            .padding(.bottom, Spacing.cozy)

                        BookReadingDetailContent(
                            snapshot: snapshot,
                            mode: .share(setting),
                            theme: theme,
                            ratingValue: .constant(Double(snapshot.book.score) / 10),
                            expandedMonthIDs: $expandedMonthIDs
                        )
                        .padding(.horizontal, Spacing.screenEdge)
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
            }
            .background(theme.neutralBackground.ignoresSafeArea())
            .navigationTitle("分享阅读详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.textSecondary)
                    .disabled(isGenerating)
                    .accessibilityLabel("关闭")
                }

                ToolbarItem(placement: .confirmationAction) {
                    XMSheetConfirmationAction(
                        isDisabled: false,
                        isConfirming: isGenerating,
                        action: generate
                    )
                    .accessibilityHint("生成阅读详情长图并打开系统分享")
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

    private var shareOptionsControl: some View {
        HStack {
            Button {
                isShowingOptions = true
            } label: {
                Label("分享内容", systemImage: "slider.horizontal.3")
                    .font(AppTypography.subheadlineMedium)
            }
            .buttonStyle(.bordered)
            .tint(Color.textSecondary)
            .disabled(isGenerating)

            Spacer(minLength: Spacing.none)
        }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        isShowingOptions = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.textSecondary)
                    .accessibilityLabel("关闭")
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
