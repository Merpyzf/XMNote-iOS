/**
 * [INPUT]: 依赖 RepositoryContainer/AppState、ReadCalendarShareViewModel、分享卡与系统年月选择/弹窗/XMActivityShareSheet
 * [OUTPUT]: 对外提供 ReadCalendarShareView，完成支持短内容回弹的三类预览、48 模板、排行、书籍排除重算、会员拦截、保存与分享
 * [POS]: ReadCalendar 分享页面壳层，采用 iOS 原生 push、Sheet 与系统分享/相册能力表达 Android 业务规则
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 阅读日历分享页；所有会员能力均允许在预览阶段探索，只在受限选择或导出动作处明确说明。
struct ReadCalendarShareView: View {
    let onOpenPremium: () -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: ReadCalendarShareViewModel
    @State private var loadingGate = LoadingGate()
    @State private var activeSheet: SheetDestination?
    @State private var pendingMonth: Date?
    @State private var premiumBlock: PremiumBlock?
    @State private var pendingShareFileURL: URL?
    @State private var isExporting = false
    @State private var toastCenter = XMToastCenter()

    /// 注入入口月份、初始成品类型与会员页导航回调。
    init(
        monthStart: Date,
        initialType: ReadCalendarShareType,
        onOpenPremium: @escaping () -> Void
    ) {
        self.onOpenPremium = onOpenPremium
        _viewModel = State(initialValue: ReadCalendarShareViewModel(
            monthStart: monthStart,
            initialType: initialType
        ))
    }

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            content
        }
        .navigationTitle("分享阅读日历")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { exportBar }
        .sheet(item: $activeSheet, onDismiss: handleSheetDismiss) { destination in
            sheetContent(destination)
        }
        .xmSystemAlert(item: $premiumBlock) { block in
            premiumDescriptor(for: block)
        }
        .xmToastHost(center: toastCenter)
        .task {
            viewModel.updateAccessBoundary(
                minimumAccessibleMonthStart: shareMinimumAccessibleMonthStart
            )
            syncLoadingGate()
            await viewModel.loadIfNeeded(using: repositories.readCalendarRepository)
            syncLoadingGate()
        }
        .onChange(of: viewModel.isLoading) { _, _ in syncLoadingGate() }
        .onChange(of: appState.shouldEnforcePremiumRestrictions) { _, shouldEnforce in
            if !shouldEnforce {
                premiumBlock = nil
            }
            viewModel.updateAccessBoundary(
                minimumAccessibleMonthStart: shareMinimumAccessibleMonthStart
            )
            Task {
                await viewModel.reload(using: repositories.readCalendarRepository)
            }
        }
        .onDisappear {
            viewModel.cancel()
            loadingGate.hideImmediately()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = viewModel.snapshot {
            ScrollView {
                VStack(spacing: Spacing.double) {
                    preview(snapshot)
                    typeControl
                    optionControls
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.base)
                .padding(.bottom, Spacing.double)
            }
            .scrollBounceBehavior(.always)
        } else if viewModel.isLoading {
            if loadingGate.isVisible {
                LoadingStateView("正在生成日历预览…", style: .card)
            } else {
                Color.clear
            }
        } else {
            ContentUnavailableView {
                Label("无法生成预览", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text(viewModel.errorMessage ?? "请稍后重试")
            } actions: {
                Button("重试") {
                    Task { await viewModel.reload(using: repositories.readCalendarRepository) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func preview(_ snapshot: ReadCalendarShareSnapshot) -> some View {
        ReadCalendarShareCard(
            type: viewModel.shareType,
            template: viewModel.template,
            snapshot: snapshot,
            rankingBooks: viewModel.visibleTopBooks,
            excludedBookIDs: viewModel.excludedBookIDs,
            doneMarkerStyle: viewModel.settings.doneMarkerStyle,
            doneEmojiAssetName: viewModel.settings.doneEmojiAssetName
        )
        .aspectRatio(4 / 5, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous)
                .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 18, y: 8)
        .overlay {
            if viewModel.isLoading {
                Color.black.opacity(0.08)
                    .overlay { LoadingStateView(style: .inline) }
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.24), value: viewModel.shareType)
        .animation(.smooth(duration: 0.24), value: viewModel.template)
    }

    private var typeControl: some View {
        Picker("分享样式", selection: $viewModel.shareType) {
            ForEach(ReadCalendarShareType.allCases) { type in
                Text(type.title).tag(type)
            }
        }
        .pickerStyle(.segmented)
    }

    private var optionControls: some View {
        VStack(spacing: Spacing.none) {
            optionButton(
                title: "时间范围",
                value: monthButtonTitle,
                systemImage: "calendar"
            ) {
                pendingMonth = nil
                activeSheet = .monthPicker
            }
            Divider().padding(.leading, Spacing.actionReserved)
            optionButton(
                title: "卡片模板",
                value: viewModel.template.title,
                systemImage: "paintpalette"
            ) {
                activeSheet = .templatePicker
            }
            Divider().padding(.leading, Spacing.actionReserved)
            rankingControl
            Divider().padding(.leading, Spacing.actionReserved)
            optionButton(
                title: "排除书籍",
                value: viewModel.excludedBookIDs.isEmpty ? "未排除" : "已排除 \(viewModel.excludedBookIDs.count) 本",
                systemImage: "books.vertical"
            ) {
                if appState.shouldEnforcePremiumRestrictions {
                    premiumBlock = .excludedBooks
                } else {
                    activeSheet = .bookFilter
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: CornerRadius.containerMedium, style: .continuous))
    }

    private var rankingControl: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "list.number")
                .foregroundStyle(Color.iconSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text("排行榜数量")
                    .font(AppTypography.body)
                Text("最多展示 10 本")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Stepper(value: rankingBinding, in: 1...10) {
                Text("\(viewModel.rankingDisplayCount)")
                    .font(AppTypography.subheadlineMedium)
                    .monospacedDigit()
                    .frame(minWidth: 22)
            }
            .labelsHidden()
        }
        .padding(Spacing.base)
    }

    private var rankingBinding: Binding<Int> {
        Binding(
            get: { viewModel.rankingDisplayCount },
            set: { value in
                if appState.shouldEnforcePremiumRestrictions, value > 5 {
                    premiumBlock = .ranking
                    return
                }
                viewModel.rankingDisplayCount = value
            }
        )
    }

    private func optionButton(
        title: String,
        value: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(width: 24)
                Text(title)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Text(value)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textHint)
            }
            .padding(Spacing.base)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var exportBar: some View {
        HStack(spacing: Spacing.base) {
            Button {
                beginExport(mode: .save)
            } label: {
                Label("保存图片", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.snapshot == nil || isExporting)

            Button {
                beginExport(mode: .share)
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.snapshot == nil || isExporting)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.base)
        .background(.bar)
    }

    private var monthPicker: some View {
        XMYearMonthPickerSheet(
            title: "选择分享月份",
            availableMonths: viewModel.availableMonths,
            selectedMonth: viewModel.selectedMonth,
            currentMonth: Date(),
            calendar: Calendar.current,
            onSelectMonth: { pendingMonth = $0 },
            onCancel: { pendingMonth = nil }
        )
        .presentationDetents([.height(XMYearMonthPickerSheet.preferredPresentationHeight(for: dynamicTypeSize, mode: .yearMonth))])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.regularMaterial)
    }

    private var templatePicker: some View {
        NavigationStack {
            ScrollView {
                let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: 3)
                LazyVGrid(columns: columns, spacing: Spacing.base) {
                    ForEach(ReadCalendarShareTemplate.allCases) { template in
                        Button {
                            viewModel.template = template
                            activeSheet = nil
                        } label: {
                            VStack(spacing: Spacing.half) {
                                RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                                    .fill(templateBackground(template))
                                    .frame(height: 72)
                                    .overlay(alignment: .topTrailing) {
                                        if !template.isFree {
                                            Image(systemName: "crown.fill")
                                                .font(.caption2)
                                                .foregroundStyle(templateAccent(template))
                                                .padding(Spacing.half)
                                        }
                                    }
                                    .overlay {
                                        if template == viewModel.template {
                                            RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                                                .stroke(Color.brand, lineWidth: 2)
                                        }
                                    }
                                Text(template.title)
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Spacing.screenEdge)
            }
            .navigationTitle("卡片模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var bookFilter: some View {
        NavigationStack {
            List(viewModel.filterBooks) { book in
                Button {
                    Task {
                        await viewModel.toggleExcludedBook(
                            book.bookId,
                            using: repositories.readCalendarRepository
                        )
                    }
                } label: {
                    HStack(spacing: Spacing.base) {
                        XMBookCover.fixedWidth(
                            34,
                            urlString: book.coverURL,
                            border: .init(color: .surfaceBorderDefault, width: CardStyle.borderWidth)
                        )
                        Text(book.name)
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        if viewModel.excludedBookIDs.contains(book.bookId) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.brand)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("排除书籍")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { activeSheet = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func commitPendingMonth() {
        guard let pendingMonth else { return }
        self.pendingMonth = nil
        if isMonthPremiumLocked(pendingMonth) {
            premiumBlock = .historicalMonth
            return
        }
        Task {
            await viewModel.selectMonth(pendingMonth, using: repositories.readCalendarRepository)
        }
    }

    private func beginExport(mode: ExportMode) {
        if appState.shouldEnforcePremiumRestrictions, !viewModel.template.isFree {
            premiumBlock = .template
            return
        }
        if appState.shouldEnforcePremiumRestrictions, viewModel.rankingDisplayCount > 5 {
            premiumBlock = .ranking
            return
        }
        if appState.shouldEnforcePremiumRestrictions, !viewModel.excludedBookIDs.isEmpty {
            premiumBlock = .excludedBooks
            return
        }
        guard let snapshot = viewModel.snapshot else { return }
        isExporting = true
        Task { @MainActor in
            var generatedURL: URL?
            do {
                let card = ReadCalendarShareCard(
                    type: viewModel.shareType,
                    template: viewModel.template,
                    snapshot: snapshot,
                    rankingBooks: viewModel.visibleTopBooks,
                    excludedBookIDs: viewModel.excludedBookIDs,
                    doneMarkerStyle: viewModel.settings.doneMarkerStyle,
                    doneEmojiAssetName: viewModel.settings.doneEmojiAssetName
                )
                let url = try ReadCalendarShareImageRenderer.renderPNG(content: card)
                generatedURL = url
                switch mode {
                case .save:
                    try await ReadCalendarShareImageRenderer.saveToPhotoLibrary(fileURL: url)
                    ReadCalendarShareImageRenderer.discardTemporaryFile(url)
                    generatedURL = nil
                    toastCenter.success("图片已保存到相册")
                case .share:
                    pendingShareFileURL = url
                    activeSheet = .activity(SharePayload(fileURL: url))
                    generatedURL = nil
                }
            } catch {
                if let generatedURL {
                    ReadCalendarShareImageRenderer.discardTemporaryFile(generatedURL)
                }
                toastCenter.error(error.localizedDescription)
            }
            isExporting = false
        }
    }

    private func handleSheetDismiss() {
        commitPendingMonth()
        if let pendingShareFileURL {
            ReadCalendarShareImageRenderer.discardTemporaryFile(pendingShareFileURL)
        }
        pendingShareFileURL = nil
    }

    @ViewBuilder
    private func sheetContent(_ destination: SheetDestination) -> some View {
        switch destination {
        case .monthPicker:
            monthPicker
        case .templatePicker:
            templatePicker
        case .bookFilter:
            bookFilter
        case .activity(let payload):
            XMActivityShareSheet(activityItems: [payload.fileURL])
                .presentationDetents([.medium, .large])
        }
    }

    private func premiumDescriptor(for block: PremiumBlock) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: block.title,
            message: block.message,
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "了解会员") { onOpenPremium() }
            ]
        )
    }

    private func isMonthPremiumLocked(_ date: Date) -> Bool {
        guard let shareMinimumAccessibleMonthStart else { return false }
        let calendar = Calendar.current
        let normalized = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return normalized < shareMinimumAccessibleMonthStart
    }

    /// 免费版分享与主日历复用当前月向前五个月的查询下界。
    private var shareMinimumAccessibleMonthStart: Date? {
        guard appState.shouldEnforcePremiumRestrictions else { return nil }
        let calendar = Calendar.current
        let current = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return calendar.date(byAdding: .month, value: -5, to: current) ?? current
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.isLoading && viewModel.snapshot == nil ? .read : .none)
    }

    private var monthButtonTitle: String {
        if viewModel.shareType == .yearHeatmap {
            return "\(viewModel.selectedYear)年"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: viewModel.selectedMonth)
    }

    private func templateBackground(_ template: ReadCalendarShareTemplate) -> Color {
        Color.xmHex(UInt(template.palette.backgroundARGB & 0x00FF_FFFF))
    }

    private func templateAccent(_ template: ReadCalendarShareTemplate) -> Color {
        Color.xmHex(UInt(template.palette.accentARGB & 0x00FF_FFFF))
    }
}

private extension ReadCalendarShareView {
    enum ExportMode { case save, share }

    enum SheetDestination: Identifiable {
        case monthPicker
        case templatePicker
        case bookFilter
        case activity(SharePayload)

        var id: String {
            switch self {
            case .monthPicker: "monthPicker"
            case .templatePicker: "templatePicker"
            case .bookFilter: "bookFilter"
            case .activity(let payload): "activity-\(payload.id.uuidString)"
            }
        }
    }

    struct SharePayload: Identifiable {
        let id = UUID()
        let fileURL: URL
    }

    enum PremiumBlock: String, Identifiable {
        case historicalMonth
        case template
        case ranking
        case excludedBooks

        var id: String { rawValue }

        var title: String {
            switch self {
            case .historicalMonth: "查看更早的阅读日历"
            case .template: "导出这套会员模板"
            case .ranking: "展示更多排行书籍"
            case .excludedBooks: "自定义排除书籍"
            }
        }

        var message: String {
            switch self {
            case .historicalMonth: "免费版可查看并分享最近 6 个自然月，会员可访问全部历史。"
            case .template: "这套模板可以免费预览，导出需要会员。你也可以改用 6 套免费模板。"
            case .ranking: "免费版排行榜最多展示 5 本，会员最多展示 10 本。"
            case .excludedBooks: "按书籍排除分享内容是会员功能。"
            }
        }
    }
}
