/**
 * [INPUT]: 依赖 AppNavigationCoordinator、Kindle 导入方式选择、DataImportCollectionView、系统 scrollEdgeEffectStyle、微信读书导入 ViewModel、全屏 WebView、浮动操作面板、BookPickerView、Photos、导入交互式玻璃主按钮与面板内统一反馈组件
 * [OUTPUT]: 对外提供支持系统上下滚动边缘过渡、分组/组内排序的书摘导入入口、非模态授权面板、分批、WereadImportBatchStatusView、导入预览和单书内容预览页面
 * [POS]: Views/Personal/DataImport 的完整微信读书扫码授权导入交互流
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Photos
import SwiftUI
import UIKit

struct DataImportView: View {
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var groups: [DataImportGroup]
    @State private var isEditing = false
    @State private var showsKindleMethods = false
    @State private var pendingKindleEntryPoint: KindleImportEntryPoint?

    init() {
        _groups = State(initialValue: DataImportOrderingStore.loadGroups())
    }

    var body: some View {
        DataImportCollectionView(
            groups: groups,
            isEditing: isEditing,
            reducesMotion: accessibilityReduceMotion,
            onOpen: openImportTask,
            onCommitGroupOrder: commitGroupOrder,
            onCommitEntryOrder: commitEntryOrder
        )
        .background(Color.surfacePage)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("书摘导入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "完成" : "编辑", action: toggleEditing)
                    .xmToolbarNeutralTint()
            }
        }
        .sheet(isPresented: $showsKindleMethods, onDismiss: kindleMethodsDidDismiss) {
            KindleImportMethodSheet(onSelect: selectKindleMethod)
        }
    }

    /// 在不改变当前 Tab 浏览栈的前提下启动任务；Kindle 先选择导入方式。
    private func openImportTask(_ destination: DataImportTaskDestination) {
        guard !isEditing else { return }
        if case .kindle = destination {
            pendingKindleEntryPoint = nil
            showsKindleMethods = true
        } else {
            navigationCoordinator.present(.dataImport(destination))
        }
    }

    /// 主线程仅记录选择并关闭弹层，避免与全屏任务争用呈现时机。
    private func selectKindleMethod(_ entryPoint: KindleImportEntryPoint) {
        guard pendingKindleEntryPoint == nil else { return }
        pendingKindleEntryPoint = entryPoint
        showsKindleMethods = false
    }

    /// 弹层完全退出后消费一次选择；手势关闭或取消不会启动任务。
    private func kindleMethodsDidDismiss() {
        guard let entryPoint = pendingKindleEntryPoint else { return }
        pendingKindleEntryPoint = nil
        navigationCoordinator.present(.dataImport(.kindle(entryPoint)))
    }

    /// 切换目录编辑状态；实际拖拽过程与收起动画由 UIKit 列表 owner 管理。
    private func toggleEditing() {
        isEditing.toggle()
    }

    /// 提交分组最终顺序并立即持久化；所有子项仍随各自分组保持原有顺序。
    private func commitGroupOrder(_ orderedIDs: [DataImportGroupID]) {
        let groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let reorderedGroups = orderedIDs.compactMap { groupByID[$0] }
        guard reorderedGroups.count == groups.count, reorderedGroups.map(\.id) != groups.map(\.id) else {
            return
        }
        groups = reorderedGroups
        DataImportOrderingStore.saveGroupOrder(orderedIDs)
    }

    /// 提交单个分组的条目顺序，拒绝跨组或缺失条目的非完整结果。
    private func commitEntryOrder(_ groupID: DataImportGroupID, orderedEntryIDs: [String]) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let entries = groups[groupIndex].entries
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let reorderedEntries = orderedEntryIDs.compactMap { entryByID[$0] }
        guard reorderedEntries.count == entries.count,
              reorderedEntries.map(\.id) != entries.map(\.id) else {
            return
        }
        groups[groupIndex].entries = reorderedEntries
        DataImportOrderingStore.saveEntryOrder(reorderedEntries.map(\.id), for: groupID)
    }
}

struct WereadImportAuthView: View {
    @Environment(AppState.self) private var appState
    @Environment(XMToastCenter.self) private var toastCenter
    @State private var viewModel: WereadImportAuthViewModel
    @State private var showsError = false
    @State private var showsPremium = false
    @State private var showsBackfillPrompt = false
    @State private var isActionPanelPresented = true
    @State private var selectedActionPanelDetent = WereadImportActionPanel.expandedDetent
    @State private var activeDestination: WereadImportAuthViewModel.Destination?
    @State private var opensPremiumAfterPanelDismiss = false
    @State private var isSavingQRCode = false
    @State private var qrCodeSaveTask: Task<Void, Never>?
    let onOpenPremium: () -> Void

    init(repository: any WereadImportRepositoryProtocol, onOpenPremium: @escaping () -> Void) {
        _viewModel = State(initialValue: WereadImportAuthViewModel(repository: repository)); self.onOpenPremium = onOpenPremium
    }

    var body: some View {
        GeometryReader { geometry in
            authorizationContent(bottomSafeAreaInset: geometry.safeAreaInsets.bottom)
        }
    }

    /// 以页面真实安全区作为 Sheet 折叠基准，避免把 Home Indicator 留白误算为内容位移。
    private func authorizationContent(bottomSafeAreaInset: CGFloat) -> some View {
        WereadAuthorizationWebView(
            reloadToken: viewModel.webReloadToken,
            onQRCode: viewModel.receiveQRCode,
            onCookie: viewModel.receiveCookie,
            onExpired: viewModel.markExpired,
            onFailed: viewModel.markFailed
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color.surfacePage)
        .navigationTitle("微信读书导入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新授权页面", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .xmToolbarNeutralTint()
                    .disabled(viewModel.isWorking || isSavingQRCode)
            }
        }
        .sheet(isPresented: $isActionPanelPresented, onDismiss: actionPanelDidDismiss) {
            actionPanel(bottomSafeAreaInset: bottomSafeAreaInset)
                .presentationDetents(
                    WereadImportActionPanel.detents,
                    selection: $selectedActionPanelDetent
                )
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
                .interactiveDismissDisabled()
                .xmSystemAlert(isPresented: $showsError, descriptor: errorDescriptor)
                .xmSystemAlert(isPresented: $showsPremium, descriptor: premiumDescriptor)
                .xmSystemAlert(isPresented: $showsBackfillPrompt, descriptor: backfillDescriptor)
        }
        .task { await viewModel.load() }
        .onDisappear(perform: cancelTasks)
        .onChange(of: viewModel.errorMessage) { _, value in showsError = value != nil }
        .onChange(of: viewModel.backfillPrompt) { _, prompt in showsBackfillPrompt = prompt != nil }
        .onChange(of: viewModel.destination) { _, destination in
            guard destination != nil else { return }
            isActionPanelPresented = false
        }
        .onChange(of: activeDestination) { _, destination in
            guard destination == nil, viewModel.destination == nil else { return }
            selectedActionPanelDetent = WereadImportActionPanel.expandedDetent
            isActionPanelPresented = true
        }
        .navigationDestination(item: $activeDestination) { destination in
            switch destination {
            case .batches(let route): WereadBatchView(route: route)
            case .preview(let route): WereadImportPreviewView(route: route)
            }
        }
    }

    private var phaseIsLoading: Bool { if case .loading = viewModel.phase { return true }; return false }

    private func actionPanel(bottomSafeAreaInset: CGFloat) -> some View {
        WereadImportActionPanel(
            selectedDetent: $selectedActionPanelDetent,
            bottomSafeAreaInset: bottomSafeAreaInset,
            recentBookCount: viewModel.preferences.recentBookCount,
            importsReadingTime: viewModel.preferences.importsReadingTime,
            onlyBooksWithNotes: viewModel.preferences.onlyBooksWithNotes,
            primaryTitle: primaryTitle,
            primaryProgress: viewModel.isWorking ? viewModel.progress : nil,
            showsPrimaryProgress: showsPrimaryProgress,
            isPrimaryDisabled: isSavingQRCode || viewModel.isWorking || phaseIsLoading,
            areSettingsDisabled: viewModel.isWorking,
            onRecentBookCountChange: { value in
                viewModel.updatePreferences { $0.recentBookCount = value }
            },
            onImportsReadingTimeChange: { value in
                viewModel.updatePreferences { $0.importsReadingTime = value }
            },
            onOnlyBooksWithNotesChange: { value in
                viewModel.updatePreferences { $0.onlyBooksWithNotes = value }
            },
            onPrimaryAction: primaryAction
        )
    }

    private var primaryTitle: String {
        if isSavingQRCode { return "保存中…" }
        if viewModel.isWorking {
            return viewModel.workKind == .backfill ? "关联中" : "获取中"
        }
        switch viewModel.phase {
        case .loading: return "加载中…"
        case .available: return "保存二维码"
        case .expired: return "刷新二维码"
        case .failed: return "重新加载"
        case .authorized: return "获取书籍"
        }
    }

    private var showsPrimaryProgress: Bool {
        isSavingQRCode || viewModel.isWorking || phaseIsLoading
    }

    private func primaryAction() {
        switch viewModel.phase {
        case .available: saveQRCode()
        case .expired, .failed: refresh()
        case .authorized:
            guard appState.membership.snapshot.isLoaded else {
                viewModel.errorMessage = MembershipError.notReady.localizedDescription
                return
            }
            guard appState.isPremium else { showsPremium = true; return }
            viewModel.beginCandidateFetch()
        case .loading: break
        }
    }

    private func refresh() { viewModel.beginRefresh() }

    private func saveQRCode() {
        guard !isSavingQRCode,
              let data = viewModel.qrCodeData,
              let image = UIImage(data: data) else {
            toastCenter.error("保存二维码失败")
            return
        }
        isSavingQRCode = true
        qrCodeSaveTask?.cancel()
        qrCodeSaveTask = Task { @MainActor in
            defer {
                isSavingQRCode = false
                qrCodeSaveTask = nil
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard !Task.isCancelled else { return }
            guard status == .authorized || status == .limited else { toastCenter.error(WereadImportError.photoPermissionDenied.localizedDescription); return }
            let size = CGSize(width: image.size.width + 100, height: image.size.height + 100)
            let renderer = UIGraphicsImageRenderer(size: size)
            let padded = renderer.image { context in UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)); image.draw(at: CGPoint(x: 50, y: 50)) }
            guard !Task.isCancelled else { return }
            do { try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: padded) }; toastCenter.success("二维码已保存到相册") }
            catch { toastCenter.error("保存二维码失败：\(error.localizedDescription)") }
        }
    }

    /// Sheet 完成程序化收起后再提交导航，避免呈现层与 push 同时竞争。
    private func actionPanelDidDismiss() {
        if opensPremiumAfterPanelDismiss {
            opensPremiumAfterPanelDismiss = false
            onOpenPremium()
            return
        }
        guard let destination = viewModel.destination else { return }
        viewModel.destination = nil
        activeDestination = destination
    }

    /// 页面离开时同时取消 ViewModel 与照片写入任务，阻止过期状态回写当前界面。
    private func cancelTasks() {
        qrCodeSaveTask?.cancel()
        qrCodeSaveTask = nil
        isSavingQRCode = false
        viewModel.cancel()
    }

    private var errorDescriptor: XMSystemAlertDescriptor? {
        guard let message = viewModel.errorMessage else { return nil }
        return .init(
            title: errorTitle,
            message: message,
            actions: [.init(title: "知道了") { viewModel.clearError() }]
        )
    }
    private var errorTitle: String {
        switch viewModel.errorContext {
        case .authorization: "授权失败"
        case .candidateFetch: "获取书籍失败"
        case .emptyCandidates: "未获取到书籍"
        case .backfill: "关联书籍失败"
        case nil: "操作失败"
        }
    }
    private var premiumDescriptor: XMSystemAlertDescriptor { .init(title: "会员功能", message: "微信读书导入需要会员权限。", actions: [.init(title: "取消", role: .cancel) {}, .init(title: "开通会员") {
            opensPremiumAfterPanelDismiss = true
            isActionPanelPresented = false
        }]) }
    private var backfillDescriptor: XMSystemAlertDescriptor? {
        guard let prompt = viewModel.backfillPrompt else { return nil }
        return .init(title: "关联已有书籍", message: "有 \(prompt.pendingCount) 本此前导入的书籍缺少微信读书关联信息，是否现在补全？", actions: [.init(title: "稍后", role: .cancel) { viewModel.postponeBackfill() }, .init(title: "关联书籍") { viewModel.beginBackfill() }])
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
                            Spacer(); WereadImportBatchStatusView(status: batch.status)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoading && { if case .loading = batch.status { return false }; return true }())
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

}

/// 微信读书分批导入的确定进度与结果状态，保持批次语义而不并入通用页面状态角色。
struct WereadImportBatchStatusView: View {
    let status: WereadImportBatchStatus

    @ViewBuilder
    var body: some View {
        switch status {
        case .notStarted:
            Text("未开始")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
        case .loading(let percent):
            ProgressView(value: Double(percent), total: 100)
                .controlSize(.small)
                .tint(Color.appTint)
                .frame(width: 72)
                .accessibilityLabel("本批导入进度")
                .accessibilityValue("\(percent)%")
        case .failed:
            Text("重试")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.feedbackError)
        case .success:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.feedbackSuccess)
                .accessibilityLabel("已完成")
        }
    }
}

/// 微信读书共享导入预览，只保留来源转换、会员提交与批次返回差异。
private struct WereadImportPreviewView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var model: NoteImportPreviewViewModel?
    let route: WereadPreviewRoute

    var body: some View {
        Group {
            if let model {
                UnifiedNoteImportPreviewView(model: model, onFinished: {
                    if route.returnsToBatch { dismiss() } else { navigationCoordinator.dismissTask() }
                })
            } else { Color.surfaceSheet.ignoresSafeArea() }
        }
        .task {
            guard model == nil else { return }
            if let existing = route.previewModel { model = existing; return }
            let created = NoteImportPreviewViewModel(
                books: route.repository.makePreviewDrafts(route.books),
                repository: repositories.noteImportRepository,
                preferenceKey: "weread-online",
                commit: { group in
                    try await route.repository.commitPreviewGroup(group)
                }
            )
            route.previewModel = created
            model = created
        }
    }
}
