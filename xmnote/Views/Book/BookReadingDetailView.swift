/**
 * [INPUT]: 依赖 RepositoryContainer、BookReadingDetailViewModel、HeatmapChart、XMBookCover、XMRatingBar 与系统分享桥接
 * [OUTPUT]: 对外提供 BookReadingDetailView，展示支持短内容回弹的单书跨月阅读数据、分析、状态历程及编辑/长图分享入口
 * [POS]: Views/Book 独立二级页面，不复用当日记录页，也不膨胀现有 BookDetailView
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 单书阅读数据页；页头使用克制的封面色背景，正文继续保持系统分组页面语义。
struct BookReadingDetailView: View {
    let onOpenBookRoute: (BookRoute) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: BookReadingDetailViewModel
    @State private var loadingGate = LoadingGate()
    @State private var isProgressPresented = false
    @State private var isStatusPresented = false
    @State private var isSettingPresented = false
    @State private var isSharePresented = false
    @State private var isCoverPresented = false
    @State private var isMonthlyExpanded = false
    @State private var didApplyMonthlyDefault = false
    @State private var toastCenter = XMToastCenter()

    /// 注入书籍主键与书籍模块路由回调。
    init(bookID: Int64, onOpenBookRoute: @escaping (BookRoute) -> Void) {
        self.onOpenBookRoute = onOpenBookRoute
        _viewModel = State(initialValue: BookReadingDetailViewModel(bookID: bookID))
    }

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            content
        }
        .navigationTitle("阅读详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { isSharePresented = true } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享阅读详情")
                .disabled(viewModel.snapshot == nil)

                Menu {
                    Button("编辑书籍", systemImage: "pencil") {
                        onOpenBookRoute(.edit(bookId: viewModel.bookID))
                    }
                    Button("显示设置", systemImage: "slider.horizontal.3") {
                        isSettingPresented = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(AppTypography.bodyMedium)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("阅读详情更多操作")
            }
        }
        .sheet(isPresented: $isProgressPresented) {
            if let snapshot = viewModel.snapshot {
                BookReadingProgressSheet(
                    progress: snapshot.analytics.progress,
                    isSaving: viewModel.isWriting,
                    onSave: { current, total in
                        try await viewModel.updateProgress(
                            currentValue: current,
                            totalValue: total,
                            using: repositories.bookReadingDetailRepository
                        )
                    }
                )
            }
        }
        .sheet(isPresented: $isStatusPresented) {
            if let snapshot = viewModel.snapshot {
                BookReadingStatusSheet(
                    currentStatusID: snapshot.book.readStatusID,
                    currentDate: Self.date(from: snapshot.book.readStatusChangedAt) ?? Date(),
                    options: snapshot.statusOptions,
                    isSaving: viewModel.isWriting,
                    onSave: { statusID, date in
                        try await viewModel.updateReadingStatus(
                            statusID: statusID,
                            changedAt: date,
                            using: repositories.bookReadingDetailRepository
                        )
                    }
                )
            }
        }
        .sheet(isPresented: $isSettingPresented) {
            BookReadingDetailSettingSheet(
                setting: viewModel.setting,
                onChange: { value in
                    viewModel.saveSetting(value, using: repositories.bookReadingDetailRepository)
                    if !value.isMonthlyChartCollapsedByDefault {
                        isMonthlyExpanded = true
                    }
                }
            )
        }
        .sheet(isPresented: $isSharePresented) {
            if let snapshot = viewModel.snapshot {
                BookReadingDetailShareSheet(
                    snapshot: snapshot,
                    setting: viewModel.shareSetting,
                    onSettingChange: {
                        viewModel.saveShareSetting($0, using: repositories.bookReadingDetailRepository)
                    }
                )
            }
        }
        .sheet(isPresented: $isCoverPresented) {
            if let book = viewModel.snapshot?.book {
                BookReadingCoverPreview(book: book)
            }
        }
        .xmToastHost(center: toastCenter)
        .task {
            syncLoadingGate()
            await viewModel.observe(using: repositories.bookReadingDetailRepository)
        }
        .task(id: viewModel.snapshot?.book.coverURL) {
            guard viewModel.snapshot != nil else { return }
            await viewModel.resolveHeaderColor(using: repositories.readCalendarColorRepository)
        }
        .onChange(of: viewModel.loadPhase) { _, _ in syncLoadingGate() }
        .onChange(of: viewModel.snapshot?.book.id) { _, newValue in
            guard newValue != nil, !didApplyMonthlyDefault else { return }
            didApplyMonthlyDefault = true
            isMonthlyExpanded = !viewModel.setting.isMonthlyChartCollapsedByDefault
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message else { return }
            toastCenter.error(message)
            viewModel.consumeError()
        }
        .onDisappear { loadingGate.hideImmediately() }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = viewModel.snapshot {
            loadedContent(snapshot)
        } else if viewModel.loadPhase == .failed {
            ContentUnavailableView(
                "无法加载阅读详情",
                systemImage: "exclamationmark.triangle",
                description: Text(viewModel.errorMessage ?? "书籍不存在或已被删除")
            )
        } else if loadingGate.isVisible {
            LoadingStateView("正在整理阅读数据…", style: .card)
        }
    }

    private func loadedContent(_ snapshot: BookReadingDetailSnapshot) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.screenEdge) {
                header(snapshot)
                attributesSection(snapshot.book)
                if TimelineMeaningfulText.hasMeaningfulHTML(snapshot.book.summary) {
                    summarySection(snapshot.book.summary)
                }
                heatmapSection(snapshot)
                analyticsSection(snapshot)
                monthlySection(snapshot.monthlyDurations)
                timelineSection(snapshot.statusHistory)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .padding(.bottom, Spacing.double)
        }
        .scrollBounceBehavior(.always)
        .safeAreaPadding(.bottom, Spacing.base)
    }

    private func header(_ snapshot: BookReadingDetailSnapshot) -> some View {
        HStack(alignment: .top, spacing: Spacing.screenEdge) {
            Button { isCoverPresented = true } label: {
                XMBookCover.fixedWidth(
                    92,
                    urlString: snapshot.book.coverURL,
                    border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("预览《\(snapshot.book.name)》封面")

            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(snapshot.book.name)
                    .font(AppTypography.title3Semibold)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !snapshot.book.author.isEmpty {
                    Text(snapshot.book.author)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                }

                XMRatingBar(
                    value: Binding(
                        get: { viewModel.ratingValue },
                        set: { viewModel.ratingValue = $0 }
                    ),
                    preset: .form,
                    onRatingChanged: { value in
                        Task { await viewModel.updateRating(value, using: repositories.bookReadingDetailRepository) }
                    }
                )
                .disabled(viewModel.isWriting)

                HStack(spacing: Spacing.base) {
                    Button(snapshot.book.readStatusName) { isStatusPresented = true }
                    Button(progressLabel(snapshot.analytics.progress)) { isProgressPresented = true }
                }
                .font(AppTypography.footnoteMedium)
                .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Spacing.contentEdge)
        .background {
            RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous)
                .fill(headerBackgroundColor)
        }
        .accessibilityElement(children: .contain)
    }

    private var headerBackgroundColor: Color {
        guard viewModel.setting.isCoverBackgroundEnabled,
              viewModel.headerColor.state != .pending else {
            return Color.surfaceCard
        }
        return Color(rgbaHex: viewModel.headerColor.backgroundRGBAHex).opacity(0.16)
    }

    @ViewBuilder
    private func attributesSection(_ book: BookReadingDetailBook) -> some View {
        let rows = attributeRows(book)
        if !rows.isEmpty {
            detailSection(title: "书籍资料") {
                VStack(spacing: Spacing.none) {
                    ForEach(Array(rows.enumerated()), id: \.element.0) { index, row in
                        LabeledContent(row.0, value: row.1)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textPrimary)
                            .padding(.vertical, Spacing.cozy)
                        if index < rows.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private func summarySection(_ summary: String) -> some View {
        detailSection(title: "简介") {
            ExpandableRichText(
                html: summary,
                baseFont: AppTypography.uiSemantic(.body),
                lineSpacing: Spacing.half
            )
            .equatable()
            .padding(.vertical, Spacing.cozy)
        }
    }

    private func heatmapSection(_ snapshot: BookReadingDetailSnapshot) -> some View {
        detailSection(title: "阅读热力图") {
            HeatmapChart(
                days: snapshot.heatmapDays,
                earliestDate: snapshot.heatmapEarliestDate,
                latestDate: snapshot.heatmapLatestDate,
                statisticsDataType: .all,
                style: .readingCard
            )
            .padding(.vertical, Spacing.cozy)
        }
    }

    private func analyticsSection(_ snapshot: BookReadingDetailSnapshot) -> some View {
        let analytics = snapshot.analytics
        let items: [(String, String)] = [
            ("阅读天数", "\(analytics.readingDayCount) 天"),
            ("最后阅读", formatOptionalDate(analytics.lastReadingAt)),
            ("阅读进度", progressLabel(analytics.progress)),
            ("总时长", ReadDurationFormatter.format(seconds: analytics.totalReadingSeconds)),
            ("实际开始", formatOptionalDate(analytics.actualStartAt)),
            ("设为在读", formatOptionalDate(analytics.statusStartAt)),
            ("书摘", "\(analytics.noteCount) 条"),
            ("想法", "\(analytics.ideaCount) 条")
        ]
        return detailSection(title: "阅读分析") {
            Grid(horizontalSpacing: Spacing.screenEdge, verticalSpacing: Spacing.base) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index.isMultiple(of: 2) {
                        GridRow {
                            analyticsItem(items[index])
                            if items.indices.contains(index + 1) {
                                analyticsItem(items[index + 1])
                            } else {
                                Color.clear
                            }
                        }
                    }
                }
            }
            .padding(.vertical, Spacing.cozy)
        }
    }

    private func analyticsItem(_ item: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(item.0)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
            Text(item.1)
                .font(AppTypography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func monthlySection(_ months: [BookReadingMonthDuration]) -> some View {
        if !months.isEmpty {
            detailSection(title: "月度阅读时长") {
                Button {
                    withAnimation(.snappy) { isMonthlyExpanded.toggle() }
                } label: {
                    HStack {
                        Text(isMonthlyExpanded ? "收起每日时长" : "展开每日时长")
                            .font(AppTypography.subheadlineMedium)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(AppTypography.captionMedium)
                            .rotationEffect(.degrees(isMonthlyExpanded ? 180 : 0))
                    }
                    .foregroundStyle(Color.textSecondary)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)

                VStack(spacing: Spacing.base) {
                    ForEach(months) { month in
                        BookReadingMonthRow(month: month, showsDays: isMonthlyExpanded)
                    }
                }
                .padding(.bottom, Spacing.cozy)
            }
        }
    }

    private func timelineSection(_ items: [BookReadingStatusHistoryItem]) -> some View {
        detailSection(title: "阅读历程") {
            VStack(spacing: Spacing.none) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: Spacing.base) {
                        VStack(spacing: Spacing.compact) {
                            Circle()
                                .fill(item.isSyntheticShelfNode ? Color.textHint : Color.brand)
                                .frame(width: 8, height: 8)
                            if index < items.count - 1 {
                                Rectangle()
                                    .fill(Color.surfaceBorderDefault)
                                    .frame(width: 1, height: 32)
                            }
                        }
                        .padding(.top, Spacing.half)

                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text(item.statusName)
                                .font(AppTypography.subheadlineMedium)
                                .foregroundStyle(Color.textPrimary)
                            Text(formatDate(item.changedAt))
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, Spacing.cozy)
                }
            }
        }
    }

    private func detailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(title)
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Spacing.compact)
            CardContainer(cornerRadius: CornerRadius.containerMedium) {
                content()
                    .padding(.horizontal, Spacing.contentEdge)
            }
        }
    }

    private func attributeRows(_ book: BookReadingDetailBook) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("类型", bookTypeLabel(book)),
            ("来源", book.sourceName),
            ("分组", book.groupNames.joined(separator: "、")),
            ("标签", book.tagNames.joined(separator: "、")),
            ("字数", formattedWordCount(book.wordCount)),
            ("价格", book.price > 0 ? String(format: "%.2f 元", book.price) : ""),
            ("作者", book.author),
            ("译者", book.translator),
            ("出版社", book.press),
            ("出版时间", book.publicationDate),
            ("ISBN", book.isbn)
        ]
        rows.removeAll { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return rows
    }

    private func bookTypeLabel(_ book: BookReadingDetailBook) -> String {
        let type = book.bookType == 1 ? "电子书" : "纸质书"
        let unit: String
        switch book.positionUnit {
        case 0: unit = "进度"
        case 1: unit = "位置"
        default: unit = "页码"
        }
        return "\(type) · \(unit)"
    }

    private func formattedWordCount(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "" }
        if value >= 10_000 {
            return String(format: "%.1f 万字", Double(value) / 10_000)
        }
        return "\(value) 字"
    }

    private func progressLabel(_ progress: BookReadingProgress) -> String {
        switch progress.unit {
        case 0:
            return "\(Int(progress.currentValue.rounded()))%"
        case 1:
            guard let total = progress.totalValue, total > 0 else { return "位置不可用" }
            return "\(Int(progress.currentValue.rounded())) / \(total)"
        default:
            guard let total = progress.totalValue, total > 0 else { return "页码不可用" }
            return "第 \(Int(progress.currentValue.rounded())) / \(total) 页"
        }
    }

    private func formatOptionalDate(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "暂无" }
        return formatDate(value)
    }

    private func formatDate(_ value: Int64) -> String {
        guard value > 0 else { return "暂无" }
        return Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double(value) / 1_000))
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.loadPhase == .loading ? .read : .none)
    }

    private static func date(from milliseconds: Int64) -> Date? {
        milliseconds > 0 ? Date(timeIntervalSince1970: Double(milliseconds) / 1_000) : nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()
}

private struct BookReadingMonthRow: View {
    let month: BookReadingMonthDuration
    let showsDays: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            HStack {
                Text("\(month.year)年\(month.month)月")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(ReadDurationFormatter.format(seconds: month.totalSeconds))
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
            }
            if showsDays {
                let maximum = max(1, month.days.map(\.seconds).max() ?? 1)
                ForEach(month.days) { day in
                    HStack(spacing: Spacing.cozy) {
                        Text(Self.dayFormatter.string(from: day.date))
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .frame(width: 34, alignment: .leading)
                        ProgressView(value: Double(day.seconds), total: Double(maximum))
                            .tint(Color.brand)
                        Text(ReadDurationFormatter.format(seconds: day.seconds))
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d日"
        return formatter
    }()
}

private struct BookReadingProgressSheet: View {
    let progress: BookReadingProgress
    let isSaving: Bool
    let onSave: (Double, Int64?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentText: String
    @State private var totalText: String
    @State private var errorMessage: String?

    init(
        progress: BookReadingProgress,
        isSaving: Bool,
        onSave: @escaping (Double, Int64?) async throws -> Void
    ) {
        self.progress = progress
        self.isSaving = isSaving
        self.onSave = onSave
        _currentText = State(initialValue: String(format: "%g", progress.currentValue))
        _totalText = State(initialValue: progress.totalValue.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(progress.unit == 0 ? "阅读进度" : "当前位置") {
                    TextField(progress.unit == 0 ? "0–100" : "当前值", text: $currentText)
                        .keyboardType(.decimalPad)
                }
                if progress.unit != 0 {
                    Section(progress.unit == 1 ? "总位置" : "总页数") {
                        TextField("总值", text: $totalText)
                            .keyboardType(.numberPad)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.feedbackError)
                }
            }
            .navigationTitle("更新阅读进度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isSaving || Double(currentText) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        guard let current = Double(currentText) else { return }
        do {
            let total = progress.unit == 0 ? nil : Int64(totalText)
            try await onSave(current, total)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BookReadingStatusSheet: View {
    let options: [BookReadingStatusOption]
    let isSaving: Bool
    let onSave: (Int64, Date) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedStatusID: Int64
    @State private var changedAt: Date
    @State private var errorMessage: String?

    init(
        currentStatusID: Int64,
        currentDate: Date,
        options: [BookReadingStatusOption],
        isSaving: Bool,
        onSave: @escaping (Int64, Date) async throws -> Void
    ) {
        self.options = options
        self.isSaving = isSaving
        self.onSave = onSave
        _selectedStatusID = State(initialValue: currentStatusID)
        _changedAt = State(initialValue: currentDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("阅读状态", selection: $selectedStatusID) {
                    ForEach(options) { Text($0.title).tag($0.id) }
                }
                DatePicker("变更日期", selection: $changedAt, in: ...Date(), displayedComponents: .date)
                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.feedbackError)
                }
            }
            .navigationTitle("更新阅读状态")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        do {
            try await onSave(selectedStatusID, changedAt)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct BookReadingDetailSettingSheet: View {
    let onChange: (BookReadingDetailSetting) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var setting: BookReadingDetailSetting

    init(setting: BookReadingDetailSetting, onChange: @escaping (BookReadingDetailSetting) -> Void) {
        self.onChange = onChange
        _setting = State(initialValue: setting)
    }

    var body: some View {
        NavigationStack {
            Form {
                Toggle("封面色背景", isOn: binding(\.isCoverBackgroundEnabled))
                Toggle("月度图表默认收起", isOn: binding(\.isMonthlyChartCollapsedByDefault))
            }
            .navigationTitle("显示设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }

    private func binding(_ keyPath: WritableKeyPath<BookReadingDetailSetting, Bool>) -> Binding<Bool> {
        Binding(
            get: { setting[keyPath: keyPath] },
            set: { value in
                setting[keyPath: keyPath] = value
                onChange(setting)
            }
        )
    }
}

private struct BookReadingDetailShareSheet: View {
    let snapshot: BookReadingDetailSnapshot
    let onSettingChange: (BookReadingDetailShareSetting) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var setting: BookReadingDetailShareSetting
    @State private var generatedURL: URL?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    init(
        snapshot: BookReadingDetailSnapshot,
        setting: BookReadingDetailShareSetting,
        onSettingChange: @escaping (BookReadingDetailShareSetting) -> Void
    ) {
        self.snapshot = snapshot
        self.onSettingChange = onSettingChange
        _setting = State(initialValue: setting)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("分享内容") {
                    Toggle("书籍属性", isOn: binding(\.showsBookAttributes))
                    Toggle("简介", isOn: binding(\.showsBookSummary))
                    Toggle("热力图", isOn: binding(\.showsHeatmap))
                    Toggle("阅读分析", isOn: binding(\.showsReadingAnalytics))
                    Toggle("月度图表", isOn: binding(\.showsMonthlyChart))
                    Toggle("阅读历程", isOn: binding(\.showsReadingTimeline))
                    Toggle("应用标识", isOn: binding(\.showsAppIdentity))
                }

                Section {
                    Button {
                        generate()
                    } label: {
                        HStack {
                            Spacer()
                            Label(isGenerating ? "正在生成…" : "生成并分享长图", systemImage: "square.and.arrow.up")
                            Spacer()
                        }
                    }
                    .disabled(isGenerating)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(AppTypography.footnote)
                            .foregroundStyle(Color.feedbackError)
                    }
                }
            }
            .navigationTitle("分享阅读详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .sheet(isPresented: Binding(
            get: { generatedURL != nil },
            set: { if !$0 { discardGeneratedFile() } }
        )) {
            if let generatedURL {
                ActivityShareSheet(activityItems: [generatedURL])
            }
        }
        .onDisappear { discardGeneratedFile() }
    }

    private func binding(_ keyPath: WritableKeyPath<BookReadingDetailShareSetting, Bool>) -> Binding<Bool> {
        Binding(
            get: { setting[keyPath: keyPath] },
            set: { value in
                setting[keyPath: keyPath] = value
                onSettingChange(setting)
            }
        )
    }

    private func generate() {
        guard !isGenerating else { return }
        isGenerating = true
        errorMessage = nil
        Task { @MainActor in
            defer { isGenerating = false }
            do {
                discardGeneratedFile()
                generatedURL = try ReadCalendarShareImageRenderer.renderPNG(
                    content: BookReadingDetailShareContent(snapshot: snapshot, setting: setting)
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func discardGeneratedFile() {
        guard let generatedURL else { return }
        ReadCalendarShareImageRenderer.discardTemporaryFile(generatedURL)
        self.generatedURL = nil
    }
}

private struct BookReadingDetailShareContent: View {
    let snapshot: BookReadingDetailSnapshot
    let setting: BookReadingDetailShareSetting

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.screenEdge) {
            HStack(alignment: .top, spacing: Spacing.screenEdge) {
                XMBookCover.fixedWidth(
                    82,
                    urlString: snapshot.book.coverURL,
                    border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                )
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(snapshot.book.name)
                        .font(AppTypography.title3Semibold)
                        .foregroundStyle(Color.textPrimary)
                    Text(snapshot.book.author)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                    XMRatingBar(score: snapshot.book.score, preset: .listSmall)
                }
            }

            if setting.showsBookAttributes {
                shareSection("书籍资料") {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        ForEach(shareAttributeRows, id: \.0) { row in
                            Text("\(row.0)：\(row.1)")
                                .font(AppTypography.footnote)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                }
            }
            if setting.showsBookSummary, TimelineMeaningfulText.hasMeaningfulHTML(snapshot.book.summary) {
                shareSection("简介") {
                    Text(TimelineMeaningfulText.strippedHTML(snapshot.book.summary))
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(8)
                }
            }
            if setting.showsHeatmap {
                shareSection("阅读热力图") {
                    HeatmapChart(
                        days: snapshot.heatmapDays,
                        earliestDate: snapshot.heatmapEarliestDate,
                        latestDate: snapshot.heatmapLatestDate,
                        statisticsDataType: .all,
                        style: .readingCard
                    )
                }
            }
            if setting.showsReadingAnalytics {
                shareSection("阅读分析") {
                    Text("阅读 \(snapshot.analytics.readingDayCount) 天 · \(ReadDurationFormatter.format(seconds: snapshot.analytics.totalReadingSeconds)) · \(snapshot.analytics.noteCount) 条书摘 · \(snapshot.analytics.ideaCount) 条想法")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textPrimary)
                }
            }
            if setting.showsMonthlyChart {
                shareSection("月度阅读") {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        ForEach(snapshot.monthlyDurations) { month in
                            HStack {
                                Text("\(month.year)年\(month.month)月")
                                Spacer()
                                Text(ReadDurationFormatter.format(seconds: month.totalSeconds))
                                    .monospacedDigit()
                            }
                            .font(AppTypography.footnote)
                        }
                    }
                }
            }
            if setting.showsReadingTimeline {
                shareSection("阅读历程") {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        ForEach(snapshot.statusHistory) { item in
                            Text("\(item.statusName) · \(Self.dateFormatter.string(from: Date(timeIntervalSince1970: Double(item.changedAt) / 1_000)))")
                                .font(AppTypography.footnote)
                                .foregroundStyle(Color.textPrimary)
                        }
                    }
                }
            }
            if setting.showsAppIdentity {
                Text("XMNote · 阅读")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(Spacing.double)
        .frame(width: 390, alignment: .leading)
        .background(Color.surfacePage)
    }

    private func shareSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            Text(title)
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
            content()
        }
    }

    private var shareAttributeRows: [(String, String)] {
        let book = snapshot.book
        let type = book.bookType == 1 ? "电子书" : "纸质书"
        let unit: String
        switch book.positionUnit {
        case 0: unit = "进度"
        case 1: unit = "位置"
        default: unit = "页码"
        }
        let wordCount: String
        if let value = book.wordCount, value > 0 {
            wordCount = value >= 10_000
                ? String(format: "%.1f 万字", Double(value) / 10_000)
                : "\(value) 字"
        } else {
            wordCount = ""
        }
        return [
            ("类型", "\(type) · \(unit)"),
            ("来源", book.sourceName),
            ("分组", book.groupNames.joined(separator: "、")),
            ("标签", book.tagNames.joined(separator: "、")),
            ("作者", book.author),
            ("译者", book.translator),
            ("出版社", book.press),
            ("出版时间", book.publicationDate),
            ("ISBN", book.isbn),
            ("字数", wordCount),
            ("价格", book.price > 0 ? String(format: "%.2f 元", book.price) : "")
        ].filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.M.d"
        return formatter
    }()
}

private struct BookReadingCoverPreview: View {
    let book: BookReadingDetailBook
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.screenEdge) {
                Spacer()
                XMBookCover.fixedWidth(
                    260,
                    urlString: book.coverURL,
                    border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                )
                Text(book.name)
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding(Spacing.screenEdge)
            .background(Color.surfacePage.ignoresSafeArea())
            .navigationTitle("封面预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }
}
