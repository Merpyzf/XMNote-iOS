/**
 * [INPUT]: 依赖 AppNavigationCoordinator、微信读书导入 ViewModel、WebView、BookPickerView、Photos 与统一反馈组件
 * [OUTPUT]: 对外提供书摘导入入口、授权、分批、导入预览和单书内容预览页面
 * [POS]: Views/Personal/DataImport 的完整微信读书扫码授权导入交互流
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Photos
import SwiftUI
import UIKit

struct DataImportView: View {
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @State private var quickOrder: [String]
    @State private var fileOrder: [String]
    @State private var clipboardOrder: [String]

    init() {
        _quickOrder = State(initialValue: Self.savedOrder(key: "noteImportQuickOrder", defaults: Self.defaultQuickOrder))
        _fileOrder = State(initialValue: Self.savedOrder(key: "noteImportFileOrder", defaults: Self.defaultFileOrder))
        _clipboardOrder = State(initialValue: Self.savedOrder(key: "noteImportClipboardOrder", defaults: Self.defaultClipboardOrder))
    }

    var body: some View {
        List {
            Section("快捷导入") {
                ForEach(quickOrder, id: \.self) { sourceRow($0) }.onMove { move(&quickOrder, from: $0, to: $1, key: "noteImportQuickOrder") }
            }
            Section("API 导入") {
                taskButton("API 导入", destination: .api)
            }
            Section("本地文件") {
                ForEach(fileOrder, id: \.self) { sourceRow($0) }.onMove { move(&fileOrder, from: $0, to: $1, key: "noteImportFileOrder") }
            }
            Section("剪贴板") {
                ForEach(clipboardOrder, id: \.self) { sourceRow($0) }.onMove { move(&clipboardOrder, from: $0, to: $1, key: "noteImportClipboardOrder") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.surfacePage)
        .navigationTitle("书摘导入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
    }

    private func fileLink(_ title: String, _ parserID: NoteImportParserID) -> some View {
        taskButton(title, destination: .file(title: title, parserID: parserID))
    }

    private func clipboardLink(_ title: String, _ parserID: NoteImportParserID) -> some View {
        taskButton(title, destination: .clipboard(title: title, parserID: parserID))
    }

    @ViewBuilder private func sourceRow(_ id: String) -> some View {
        switch id {
        case "computer": taskButton("从电脑导入", destination: .desktopComputer)
        case "lifeweek": taskButton("三联生活周刊", destination: .lifeWeek)
        case "weread-auth": taskButton("微信读书授权导入", destination: .wereadAuthorization)
        case "kindle": taskButton("Kindle", destination: .kindle)
        case "koreader": fileLink("KOReader", .koreader)
        case "boox": taskButton("BOOX", destination: .fileCandidates(title: "BOOX", parserIDs: [.booxOld, .booxNew]))
        case "legado": fileLink("阅读", .legado)
        case "apple-books": fileLink("Apple Books", .appleBooks)
        case "douban-read": fileLink("豆瓣阅读", .doubanRead)
        case "jd-reader": fileLink("京东读书", .jdReader)
        case "ireader-file": fileLink("掌阅", .ireaderFile)
        case "ireader-epub": fileLink("iReader 笔记成书", .ireaderEpub)
        case "neat": fileLink("Neat Reader", .neatReader)
        case "koodo": fileLink("Koodo Reader", .koodo)
        case "hanwang": taskButton("汉王", destination: .hanwang)
        case "dimo": fileLink("滴墨", .dimo)
        case "reeden": fileLink("Reeden", .reeden)
        case "weread-clipboard": taskButton("微信读书", destination: .clipboardCandidates(title: "微信读书", parserIDs: [.wereadOld, .wereadPre830, .weread830]))
        case "dedao": clipboardLink("得到", .dedao)
        case "ireader-selected": clipboardLink("掌阅精选", .ireaderSelected)
        case "moon": clipboardLink("静读天下", .moonReader)
        case "duokan": clipboardLink("多看", .duokan)
        case "dangdang": clipboardLink("当当", .dangdang)
        case "douban-app": clipboardLink("豆瓣阅读 App", .doubanApp)
        case "reader163": clipboardLink("网易蜗牛", .reader163)
        case "fanqie": clipboardLink("番茄小说", .fanqie)
        case "readingo": clipboardLink("Readingo", .readingo)
        default: EmptyView()
        }
    }

    /// 以列表行样式启动独立导入任务，保留目录页与 Tab 的浏览现场。
    private func taskButton(
        _ title: String,
        destination: DataImportTaskDestination
    ) -> some View {
        Button {
            navigationCoordinator.present(.dataImport(destination))
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.iconSecondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开导入任务")
    }

    private func move(_ order: inout [String], from source: IndexSet, to destination: Int, key: String) {
        order.move(fromOffsets: source, toOffset: destination)
        UserDefaults.standard.set(order, forKey: key)
    }

    private static func savedOrder(key: String, defaults: [String]) -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
        return saved.filter(defaults.contains) + defaults.filter { !saved.contains($0) }
    }

    private static let defaultQuickOrder = ["computer", "lifeweek", "weread-auth"]
    private static let defaultFileOrder = ["kindle", "koreader", "boox", "legado", "apple-books", "douban-read", "jd-reader", "ireader-file", "ireader-epub", "neat", "koodo", "hanwang", "dimo", "reeden"]
    private static let defaultClipboardOrder = ["weread-clipboard", "dedao", "ireader-selected", "moon", "duokan", "dangdang", "douban-app", "reader163", "fanqie", "readingo"]
}

struct WereadImportAuthView: View {
    @Environment(AppState.self) private var appState
    @Environment(XMToastCenter.self) private var toastCenter
    @State private var viewModel: WereadImportAuthViewModel
    @State private var showsError = false
    @State private var showsPremium = false
    @State private var showsBackfillPrompt = false
    let onOpenPremium: () -> Void

    init(repository: any WereadImportRepositoryProtocol, onOpenPremium: @escaping () -> Void) {
        _viewModel = State(initialValue: WereadImportAuthViewModel(repository: repository)); self.onOpenPremium = onOpenPremium
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.section) {
                WereadAuthorizationWebView(
                    reloadToken: viewModel.webReloadToken,
                    onQRCode: viewModel.receiveQRCode,
                    onCookie: viewModel.receiveCookie,
                    onExpired: viewModel.markExpired,
                    onFailed: viewModel.markFailed
                )
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge))

                VStack(alignment: .leading, spacing: Spacing.base) {
                    Text("自定义导入").font(AppTypography.title3)
                    Picker("导入书籍", selection: Binding(get: { viewModel.preferences.recentBookCount }, set: { value in viewModel.updatePreferences { $0.recentBookCount = value } })) {
                        Text("全部").tag(-1)
                        ForEach(Self.recentBookOptions, id: \.self) { count in
                            Text("最近 \(count) 本").tag(count)
                        }
                    }
                    Toggle("导入阅读时长", isOn: Binding(get: { viewModel.preferences.importsReadingTime }, set: { value in
                        viewModel.updatePreferences { $0.importsReadingTime = value }
                        if value { toastCenter.info("微信阅读时长不会覆盖已有手工计时记录") }
                    }))
                    Toggle("仅导入包含笔记的书籍", isOn: Binding(get: { viewModel.preferences.onlyBooksWithNotes }, set: { value in viewModel.updatePreferences { $0.onlyBooksWithNotes = value } }))

                    Button(action: primaryAction) {
                        HStack { Spacer(); if viewModel.isWorking { ProgressView().controlSize(.small) }; Text(primaryTitle); Spacer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isWorking || phaseIsLoading)

                    Button("导入遇到问题？点击获取帮助") { toastCenter.info("请刷新二维码，确认微信读书已登录，并保持网络连接") }
                        .font(AppTypography.caption)
                        .frame(maxWidth: .infinity)
                }
                .padding(Spacing.contentEdge)
                .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge))
            }
            .padding(Spacing.screenEdge)
        }
        .background(Color.surfacePage)
        .navigationTitle("授权导入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { refresh() } label: { Image(systemName: "arrow.clockwise") }.disabled(viewModel.isWorking) } }
        .task { await viewModel.load() }
        .onDisappear { viewModel.cancel() }
        .onChange(of: viewModel.errorMessage) { _, value in showsError = value != nil }
        .onChange(of: viewModel.showsUsageTips) { _, value in if value { showsUsageTipsAlert = true } }
        .onChange(of: viewModel.requestsAutomaticImport) { _, requested in
            guard requested else { return }
            viewModel.consumeAutomaticImportRequest()
            guard appState.isPremium else { showsPremium = true; return }
            viewModel.beginImport()
        }
        .onChange(of: viewModel.backfillPrompt) { _, prompt in showsBackfillPrompt = prompt != nil }
        .navigationDestination(item: $viewModel.destination) { destination in
            switch destination {
            case .batches(let route): WereadBatchView(route: route)
            case .preview(let route): WereadImportPreviewView(route: route)
            }
        }
        .xmSystemAlert(isPresented: $showsError, descriptor: errorDescriptor)
        .xmSystemAlert(isPresented: $showsPremium, descriptor: premiumDescriptor)
        .xmSystemAlert(isPresented: $showsUsageTipsAlert, descriptor: tipsDescriptor)
        .xmSystemAlert(isPresented: $showsBackfillPrompt, descriptor: backfillDescriptor)
    }

    @State private var showsUsageTipsAlert = false
    private static let recentBookOptions = [5, 10, 20, 30, 60, 100]
    private var phaseIsLoading: Bool { if case .loading = viewModel.phase { return true }; return false }
    private var primaryTitle: String {
        if viewModel.isWorking { return viewModel.progressText.isEmpty ? "加载中" : viewModel.progressText }
        switch viewModel.phase {
        case .loading: return "加载中"
        case .available: return "保存二维码"
        case .expired: return "二维码已失效"
        case .failed: return "加载失败"
        case .authorized: return "开始导入"
        }
    }

    private func primaryAction() {
        switch viewModel.phase {
        case .available: saveQRCode()
        case .expired, .failed: refresh()
        case .authorized:
            guard appState.isPremium else { showsPremium = true; return }
            viewModel.beginImport()
        case .loading: break
        }
    }

    private func refresh() { viewModel.beginRefresh() }

    private func saveQRCode() {
        guard let data = viewModel.qrCodeData, let image = UIImage(data: data) else { toastCenter.error("二维码保存失败"); return }
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { toastCenter.error(WereadImportError.photoPermissionDenied.localizedDescription); return }
            let size = CGSize(width: image.size.width + 100, height: image.size.height + 100)
            let renderer = UIGraphicsImageRenderer(size: size)
            let padded = renderer.image { context in UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)); image.draw(at: CGPoint(x: 50, y: 50)) }
            do { try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: padded) }; toastCenter.success("二维码已保存到照片") }
            catch { toastCenter.error("二维码保存失败：\(error.localizedDescription)") }
        }
    }

    private var errorDescriptor: XMSystemAlertDescriptor? {
        guard let message = viewModel.errorMessage else { return nil }
        return .init(title: "导入失败", message: message, actions: [.init(title: "知道了") { viewModel.errorMessage = nil }])
    }
    private var premiumDescriptor: XMSystemAlertDescriptor { .init(title: "会员功能", message: "微信读书授权导入是会员功能。", actions: [.init(title: "取消", role: .cancel) {}, .init(title: "升级会员") { onOpenPremium() }]) }
    private var tipsDescriptor: XMSystemAlertDescriptor { .init(title: "导入提示", message: "1. 在微信中扫描或识别二维码完成授权。\n2. 导入期间请保持网络连接。\n3. 重复导入会自动合并已有内容。", actions: [.init(title: "不再提示") { viewModel.dismissTips(permanently: true) }, .init(title: "知道了", role: .cancel) { viewModel.dismissTips(permanently: false) }]) }
    private var backfillDescriptor: XMSystemAlertDescriptor? {
        guard let prompt = viewModel.backfillPrompt else { return nil }
        return .init(title: "关联历史微信数据", message: "发现 \(prompt.pendingCount) 本历史导入书籍缺少微信关联信息，是否现在补全？", actions: [.init(title: "稍后", role: .cancel) { viewModel.postponeBackfill() }, .init(title: "开始") { viewModel.beginBackfill() }])
    }
}

private struct WereadBatchView: View {
    @State private var viewModel: WereadBatchViewModel
    @State private var showsError = false
    init(route: WereadBatchRoute) { _viewModel = State(initialValue: WereadBatchViewModel(route: route)) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("共 \(viewModel.batches.reduce(0) { $0 + $1.bookIDs.count }) 本书，分为 \(viewModel.batches.count) 批").font(AppTypography.headline)
                    ProgressView(value: Double(viewModel.completedPercent), total: 100)
                    Text("已完成 \(viewModel.completedPercent)% · 每批最多 100 本，完成度按已成功加载批次计算").font(AppTypography.caption).foregroundStyle(Color.textSecondary)
                }.padding(.vertical, Spacing.half)
            }
            Section {
                ForEach(viewModel.batches) { batch in
                    Button { viewModel.beginOpen(batch.id) } label: {
                        HStack {
                            VStack(alignment: .leading) { Text("第 \(batch.number) 批"); Text("第 \(batch.start)–\(batch.end) 本").font(AppTypography.caption).foregroundStyle(Color.textSecondary) }
                            Spacer(); batchStatus(batch.status)
                        }
                    }.disabled(viewModel.isLoading && { if case .loading = batch.status { return false }; return true }())
                }
            }
        }
        .navigationTitle("分批导入")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $viewModel.preview) { WereadImportPreviewView(route: $0) }
        .onDisappear { viewModel.cancel() }
        .onChange(of: viewModel.errorMessage) { _, value in showsError = value != nil }
        .xmSystemAlert(isPresented: $showsError, descriptor: viewModel.errorMessage.map { message in .init(title: "本批加载失败", message: message, actions: [.init(title: "知道了") { viewModel.errorMessage = nil }]) })
    }

    @ViewBuilder private func batchStatus(_ status: WereadImportBatchStatus) -> some View {
        switch status { case .notStarted: Text("未开始"); case .loading(let percent): ProgressView(value: Double(percent), total: 100).frame(width: 72); case .failed: Text("重试").foregroundStyle(Color.red); case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green) }
    }
}

private struct WereadImportPreviewView: View {
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @State private var viewModel: WereadPreviewViewModel
    @State private var contentBook: WereadImportBook?
    @State private var mappingBook: WereadImportBook?
    @State private var editingBook: WereadImportBook?
    @State private var editTitle = ""
    @State private var editAuthor = ""
    @State private var showsError = false

    init(route: WereadPreviewRoute) { _viewModel = State(initialValue: WereadPreviewViewModel(route: route)) }

    var body: some View {
        List {
            Section {
                HStack { Button("全选") { viewModel.selectAll(true) }; Spacer(); Button("取消全选") { viewModel.selectAll(false) } }
            }
            ForEach(viewModel.visibleBooks) { book in
                bookSection(book)
            }
        }
        .searchable(text: $viewModel.query, prompt: "搜索书名或作者")
        .navigationTitle("导入预览")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { viewModel.beginCommit() } label: { HStack { Spacer(); if viewModel.isCommitting { ProgressView().controlSize(.small) }; Text(viewModel.isCommitting ? viewModel.progressText : "导入（\(viewModel.selectedCount)/\(viewModel.books.count)）"); Spacer() } }
                .buttonStyle(.borderedProminent).padding(Spacing.screenEdge).background(.ultraThinMaterial).disabled(viewModel.isCommitting)
        }
        .navigationDestination(item: $contentBook) { book in WereadBookContentPreviewView(book: binding(for: book.id)) }
        .sheet(item: $mappingBook) { book in
            BookPickerView(configuration: .init(title: "映射到已有书籍", scope: .local, selectionMode: .single, defaultQuery: book.title)) { result in
                if case .single(.local(let selected)) = result { viewModel.map(book.id, to: selected) }
                mappingBook = nil
            }
        }
        .onChange(of: viewModel.errorMessage) { _, value in showsError = value != nil }
        .onChange(of: viewModel.didCommit) { _, done in
            if done {
                navigationCoordinator.dismissTask()
            }
        }
        .onDisappear { viewModel.cancel() }
        .xmSystemAlert(isPresented: $showsError, descriptor: viewModel.errorMessage.map { message in .init(title: "无法导入", message: message, actions: [.init(title: "知道了") { viewModel.errorMessage = nil }]) })
        .xmSystemAlert(item: $editingBook) { book in
            .init(title: "编辑新书资料", actions: [.init(title: "取消", role: .cancel) {}, .init(title: "保存", isEnabled: !editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { var updated = book; updated.title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines); updated.rawTitle = updated.title; updated.author = editAuthor.trimmingCharacters(in: .whitespacesAndNewlines); viewModel.updateBook(updated) }], textFields: [.init(text: $editTitle, placeholder: "书名"), .init(text: $editAuthor, placeholder: "作者")])
        }
    }

    private func binding(for id: UUID) -> Binding<WereadImportBook> { Binding(get: { viewModel.books.first { $0.id == id }! }, set: viewModel.updateBook) }

    /// 打开含书摘或书评的单书预览；空内容保持无操作。
    private func openBookContentIfAvailable(_ book: WereadImportBook) {
        guard book.hasBrowsableContent else { return }
        contentBook = book
    }

    /// 进入未映射书籍的信息编辑态，已映射书籍保持原有阻断语义。
    private func beginEditing(_ book: WereadImportBook) {
        guard book.targetBookID == nil else { return }
        editingBook = book
        editTitle = book.title
        editAuthor = book.author
    }

    @ViewBuilder
    private func bookSection(_ book: WereadImportBook) -> some View {
        Section {
            HStack(alignment: .top, spacing: Spacing.base) {
                selectionButton(book)
                AsyncImage(url: URL(string: book.coverURL)) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.surfaceNested }
                .frame(width: 48, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.inlaySmall))
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(book.title).font(AppTypography.headline)
                    Text(book.author).font(AppTypography.caption).foregroundStyle(Color.textSecondary)
                    Text(summaryText(for: book)).font(AppTypography.caption).foregroundStyle(Color.textSecondary)
                    if let target = book.targetBookTitle { Text("导入到：\(target)").font(AppTypography.caption).foregroundStyle(Color.selectionAccent) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                openBookContentIfAvailable(book)
            }
            .onLongPressGesture {
                beginEditing(book)
            }
            .accessibilityActions {
                if book.hasBrowsableContent {
                    Button("预览导入内容") {
                        openBookContentIfAvailable(book)
                    }
                }
                if book.targetBookID == nil {
                    Button("编辑书籍信息") {
                        beginEditing(book)
                    }
                }
            }
            HStack {
                Button(book.targetBookID == nil ? "映射已有书籍" : "更换映射") { mappingBook = book }
                if book.targetBookID != nil { Spacer(); Button("清除映射", role: .destructive) { viewModel.map(book.id, to: nil) } }
            }
        }
    }

    private func selectionButton(_ book: WereadImportBook) -> some View {
        Button { viewModel.toggleBook(book.id) } label: {
            Image(systemName: book.isSelected ? "checkmark.circle.fill" : "circle").font(.title2)
        }
        .buttonStyle(.plain)
    }

    private func summaryText(for book: WereadImportBook) -> String {
        "\(book.readStatusID == 3 ? "已读完" : "阅读中") · \(book.notes.count) 条书摘 · \(book.reviews.count) 条书评"
    }
}

private struct WereadBookContentPreviewView: View {
    @Binding var book: WereadImportBook
    var body: some View {
        List {
            if !book.notes.isEmpty {
                Section { HStack { Button("全选") { selectNotes(true) }; Spacer(); Button("取消全选") { selectNotes(false) } } } header: { Text("书摘") }
                ForEach($book.notes) { $note in
                    HStack(alignment: .top) { Button { note.isSelected.toggle() } label: { Image(systemName: note.isSelected ? "checkmark.circle.fill" : "circle") }.buttonStyle(.plain); VStack(alignment: .leading) { Text(note.content); if !note.idea.isEmpty { Text(note.idea).font(AppTypography.caption).foregroundStyle(Color.textSecondary) } } }
                }
            }
            if !book.reviews.isEmpty { Section("书评（随书导入）") { ForEach(book.reviews) { review in VStack(alignment: .leading) { if !review.title.isEmpty { Text(review.title).font(AppTypography.headline) }; Text(review.content) } } } }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: book.notes.map(\.isSelected)) { _, values in book.isSelected = values.contains(true) || (!book.reviews.isEmpty && book.isSelected) }
    }
    private func selectNotes(_ selected: Bool) { book.notes.indices.forEach { book.notes[$0].isSelected = selected }; book.isSelected = selected || (!book.reviews.isEmpty && book.isSelected) }
}
