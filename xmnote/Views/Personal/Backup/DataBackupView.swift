/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 DataBackupViewModel 驱动本地与云端备份状态，复用 XMPopupButton 选择备份方式
 * [OUTPUT]: 对外提供 DataBackupView，以统一设置页文本层级和等高 Popup 指示器承载本地备份、云端备份与恢复确认入口
 * [POS]: Backup 模块入口壳层，统一组织 iOS 原生本地备份与云备份操作
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 数据备份入口页，聚合本地备份、云备份、provider 选择与恢复确认入口。
struct DataBackupView: View {
    @Environment(AppState.self) private var appState
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: DataBackupViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            if let viewModel {
                DataBackupContentView(viewModel: viewModel)
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在加载备份数据…", style: .card)
                }
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("数据备份")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let viewModel = DataBackupViewModel(
                backupRepository: repositories.backupRepository,
                onRestoreSucceeded: { appState.dataEpoch += 1 }
            )
            self.viewModel = viewModel
            await viewModel.loadPageData()
            bootstrapLoadingGate.update(intent: .none)
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active, let viewModel else { return }
            Task { await viewModel.refreshOnBecomeActive() }
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

// MARK: - Content View

private struct DataBackupContentView: View {
    private enum Layout {
        static let rowDividerLeading = Spacing.contentEdge
            + XMSettingsPageLayout.iconSlotWidth
            + Spacing.base
        static let avatarSize: CGFloat = 40
        static let avatarDividerLeading: CGFloat = Spacing.contentEdge + avatarSize + Spacing.base
    }

    @Bindable var viewModel: DataBackupViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var loadingTransitionNamespace

    var body: some View {
        XMSettingsPage {
            backupSection(title: "本地备份") {
                localBackupPanel
            }
            backupSection(title: "云备份") {
                cloudBackupPanel
            }
        }
        .overlay { taskBackdropOverlay }
        .overlay { taskCardOverlay }
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: viewModel.blockingAction)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: viewModel.operationState != .idle)
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: viewModel.initialLoadState)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: viewModel.lastBackupState)
        .xmSystemAlert(
            isPresented: $viewModel.showError,
            descriptor: XMSystemAlertDescriptor(
                title: "错误",
                message: viewModel.errorMessage ?? "",
                actions: [
                    XMSystemAlertAction(title: "确定", role: .cancel) { }
                ]
            )
        )
        .xmSystemAlert(
            isPresented: $viewModel.showRestoreSuccess,
            descriptor: XMSystemAlertDescriptor(
                title: "恢复成功",
                message: viewModel.restoreSuccessMessage,
                actions: [
                    XMSystemAlertAction(title: "确定", role: .cancel) {
                        viewModel.acknowledgeRestoreSuccess()
                    }
                ]
            )
        )
        .sheet(isPresented: $viewModel.isShowingBackupHistory) {
            BackupHistorySheetView(viewModel: viewModel)
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.isShowingRestoreConfirmation },
                set: { isPresented in
                    if isPresented == false {
                        viewModel.handleRestoreSheetDismissed()
                    }
                }
            )
        ) {
            if let restoreTarget = viewModel.restoreTarget {
                BackupRestoreConfirmSheet(
                    target: restoreTarget,
                    onCancel: { viewModel.cancelRestore() },
                    onConfirm: { Task { await viewModel.confirmRestore() } }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingLocalExportPicker) {
            if let ticket = viewModel.localExportTicket {
                LocalBackupExportDocumentPicker(fileURL: ticket.archiveFileURL) { succeeded in
                    viewModel.isShowingLocalExportPicker = false
                    Task { await viewModel.finishLocalExport(succeeded: succeeded) }
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingLocalImportPicker) {
            LocalBackupImportDocumentPicker(
                onPick: { url in
                    viewModel.isShowingLocalImportPicker = false
                    Task { await viewModel.prepareLocalImport(from: url) }
                },
                onCancel: {
                    viewModel.isShowingLocalImportPicker = false
                },
                onFailure: { error in
                    viewModel.isShowingLocalImportPicker = false
                    viewModel.errorMessage = error.localizedDescription
                    viewModel.showError = true
                }
            )
        }
    }
}

// MARK: - Local Backup

private extension DataBackupContentView {

    func backupSection<Content: View>(
        title: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) -> some View {
        XMSettingsSection(title) {
            content()
        }
    }

    var localBackupPanel: some View {
        settingsPanel {
            VStack(spacing: Spacing.none) {
                localExportButton
                settingsDivider(leadingInset: Layout.rowDividerLeading)
                localRestoreButton
            }
        }
    }

    var localExportButton: some View {
        Button {
            Task { await viewModel.prepareLocalExport() }
        } label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: "square.and.arrow.up")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(width: XMSettingsPageLayout.iconSlotWidth)

                Text("导出到文件")
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                fieldTransitionContainer(
                    id: "backup.local.lastExport",
                    isLoading: viewModel.isLocalBackupValueLoading
                ) {
                    InlineLoadingTextPlaceholder(width: 76, height: 11)
                } content: {
                    Text(viewModel.localBackupDateText)
                        .font(SettingsTypography.rowValue)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.88)
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPerformLocalOperation)
    }

    var localRestoreButton: some View {
        Button {
            viewModel.beginLocalImport()
        } label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: "arrow.down.doc")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(width: XMSettingsPageLayout.iconSlotWidth)

                Text("从文件恢复")
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.textHint)
            }
            .padding(.horizontal, Spacing.contentEdge)
            .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPerformLocalOperation)
    }
}

// MARK: - Cloud Backup

private extension DataBackupContentView {

    var cloudBackupPanel: some View {
        settingsPanel {
            VStack(spacing: Spacing.none) {
                providerSelectionRow
                settingsDivider(leadingInset: Spacing.contentEdge)
                currentProviderContent
                settingsDivider(leadingInset: providerContentDividerLeadingInset)
                cloudBackupButton
                settingsDivider(leadingInset: Layout.rowDividerLeading)
                cloudRestoreButton
            }
        }
    }

    var providerSelectionRow: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            Text("备份方式")
                .font(SettingsTypography.rowTitle)
                .foregroundStyle(Color.textPrimary)

            Spacer(minLength: Spacing.base)

            providerSelectionMenu
        }
        .padding(.horizontal, Spacing.contentEdge)
        .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
    }

    @ViewBuilder
    var providerSelectionMenu: some View {
        if viewModel.isProviderSwitching {
            ProgressView()
                .controlSize(.small)
                .frame(
                    minHeight: InteractionMetrics.minimumTouchTarget,
                    alignment: .trailing
                )
                .accessibilityLabel("正在切换云备份方式")
                .accessibilityValue(viewModel.selectedProvider.displayName)
        } else {
            XMPopupButton(
                viewModel.selectedProvider.displayName,
                font: SettingsTypography.rowValue
            ) {
                Picker("备份方式", selection: selectedProviderBinding) {
                    ForEach([CloudBackupProvider.webdav, .aliyunDrive]) { provider in
                        Text(provider.displayName)
                            .tag(provider)
                    }
                }
            }
            .disabled(viewModel.isBusy)
            .accessibilityLabel("云备份方式")
            .accessibilityValue(viewModel.selectedProvider.displayName)
        }
    }

    var selectedProviderBinding: Binding<CloudBackupProvider> {
        Binding(
            get: { viewModel.selectedProvider },
            set: { newValue in
                guard newValue != viewModel.selectedProvider else { return }
                Task { await viewModel.selectProvider(newValue) }
            }
        )
    }

    @ViewBuilder
    var currentProviderContent: some View {
        switch viewModel.selectedProvider {
        case .webdav:
            webdavContent
        case .aliyunDrive:
            aliyunDriveContent
        }
    }

    var webdavContent: some View {
        NavigationLink(value: AppRoute.personal(.webdavServers)) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "externaldrive")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(width: XMSettingsPageLayout.iconSlotWidth)

                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("WebDAV 服务器")
                        .font(SettingsTypography.rowTitle)
                        .foregroundStyle(Color.textPrimary)

                    fieldTransitionContainer(
                        id: "backup.provider.detail",
                        isLoading: viewModel.isProviderDetailLoading
                    ) {
                        InlineLoadingTextPlaceholder(width: 126, height: 11)
                    } content: {
                        Text(viewModel.currentServer?.title ?? "未配置")
                            .font(SettingsTypography.rowDescription)
                            .foregroundStyle(Color.textSecondary)
                            .contentTransition(.opacity)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.textHint)
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.cozy)
            .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var aliyunDriveContent: some View {
        VStack(spacing: Spacing.none) {
            if viewModel.isProviderDetailLoading {
                aliyunLoadingRow
            } else if let accountInfo = viewModel.aliyunAccountInfo {
                aliyunAccountRow(accountInfo)
            } else if viewModel.isAliyunAuthorized {
                aliyunAuthorizedFallbackRow
            } else {
                authorizeAliyunDriveButton
            }
        }
    }

    var aliyunAuthorizedFallbackRow: some View {
        HStack(spacing: Spacing.base) {
            Circle()
                .fill(Color.controlFillSecondary)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(Color.iconSecondary)
                }
                .frame(width: Layout.avatarSize, height: Layout.avatarSize)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("阿里云盘")
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)
                Text("已登录")
                    .font(SettingsTypography.rowDescription)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            logoutAccessory
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.cozy)
        .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)
    }

    var authorizeAliyunDriveButton: some View {
        Button {
            Task { await viewModel.authorizeAliyunDrive() }
        } label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(width: XMSettingsPageLayout.iconSlotWidth)

                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("登录阿里云盘")
                        .font(SettingsTypography.rowTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text("登录后即可使用云备份")
                        .font(SettingsTypography.rowDescription)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer()

                if viewModel.isAliyunAuthorizing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Spacing.cozy)
            .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }

    func aliyunAccountRow(_ accountInfo: CloudBackupAccountInfo) -> some View {
        HStack(spacing: Spacing.base) {
            fieldTransitionContainer(
                id: "backup.aliyun.avatar",
                isLoading: false
            ) {
                InlineLoadingAvatarPlaceholder(size: Layout.avatarSize)
            } content: {
                avatarView(for: accountInfo.avatarURL)
            }

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(accountInfo.nickName)
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)
                Text(accountInfo.storageSummary ?? accountInfo.userId)
                    .font(SettingsTypography.rowDescription)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            logoutAccessory
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.cozy)
        .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)
    }

    var aliyunLoadingRow: some View {
        HStack(spacing: Spacing.base) {
            InlineLoadingAvatarPlaceholder(size: Layout.avatarSize)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                InlineLoadingTextPlaceholder(width: 104, height: 14)
                InlineLoadingTextPlaceholder(width: 182, height: 11)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.cozy)
        .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)
    }

    @ViewBuilder
    func avatarView(for urlString: String) -> some View {
        if let url = URL(string: urlString), !urlString.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Circle()
                        .fill(Color.controlFillSecondary)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(Color.iconSecondary)
                        }
                }
            }
            .frame(width: Layout.avatarSize, height: Layout.avatarSize)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.controlFillSecondary)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(Color.iconSecondary)
                }
                .frame(width: Layout.avatarSize, height: Layout.avatarSize)
        }
    }

    @ViewBuilder
    var logoutAccessory: some View {
        if viewModel.isAliyunRevoking {
            ProgressView()
                .controlSize(.small)
                .frame(
                    minWidth: InteractionMetrics.minimumTouchTarget,
                    minHeight: InteractionMetrics.minimumTouchTarget,
                    alignment: .trailing
                )
        } else {
            Button("登出") {
                Task { await viewModel.revokeAliyunDriveAuthorization() }
            }
            .font(AppTypography.footnoteSemibold)
            .foregroundStyle(Color.feedbackError)
            .frame(minHeight: InteractionMetrics.minimumTouchTarget, alignment: .trailing)
            .buttonStyle(.plain)
            .disabled(viewModel.isBusy)
        }
    }

    var providerContentDividerLeadingInset: CGFloat {
        switch viewModel.selectedProvider {
        case .webdav:
            return Layout.rowDividerLeading
        case .aliyunDrive:
            return viewModel.isAliyunAuthorized ? Layout.avatarDividerLeading : Layout.rowDividerLeading
        }
    }

    var cloudBackupButton: some View {
        Button {
            Task { await viewModel.performCloudBackup() }
        } label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(width: XMSettingsPageLayout.iconSlotWidth)

                Text("立即备份")
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                fieldTransitionContainer(
                    id: "backup.cloud.lastBackup",
                    isLoading: viewModel.isCloudBackupValueLoading
                ) {
                    InlineLoadingTextPlaceholder(width: 76, height: 11)
                } content: {
                    if !viewModel.cloudBackupDateText.isEmpty {
                        Text(viewModel.cloudBackupDateText)
                            .font(SettingsTypography.rowValue)
                            .foregroundStyle(viewModel.lastBackupState == .failed ? Color.feedbackError : Color.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)
                    }
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPerformCloudOperation)
    }

    var cloudRestoreButton: some View {
        Button {
            Task {
                if await viewModel.fetchBackupHistory() {
                    viewModel.isShowingBackupHistory = true
                }
            }
        } label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(width: XMSettingsPageLayout.iconSlotWidth)

                Text("从云端恢复")
                    .font(SettingsTypography.rowTitle)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                if viewModel.isBackupHistoryLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.textHint)
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPerformCloudOperation && !viewModel.isBackupHistoryLoading)
    }
}

// MARK: - Shared Section Helpers

private extension DataBackupContentView {
    func settingsPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        XMSettingsGroup(
            horizontalPadding: Spacing.none,
            verticalPadding: Spacing.none
        ) {
            content()
        }
    }

    func settingsDivider(leadingInset: CGFloat) -> some View {
        XMSettingsDivider()
            .padding(.leading, leadingInset)
    }
}

// MARK: - Progress Presentation

private extension DataBackupContentView {
    @ViewBuilder
    var taskBackdropOverlay: some View {
        if viewModel.operationState != .idle {
            BackupTaskBackdropView()
                .id("backup-task-backdrop")
                .transition(.opacity)
        }
    }

    @ViewBuilder
    var taskCardOverlay: some View {
        if let presentation = viewModel.taskPresentation {
            BackupTaskCardView(
                presentation: presentation,
                reduceMotion: reduceMotion
            )
            .id("backup-task-card")
            .transition(taskCardTransition)
        }
    }

    @ViewBuilder
    func fieldTransitionContainer<Placeholder: View, Content: View>(
        id: String,
        isLoading: Bool,
        @ViewBuilder placeholder: () -> Placeholder,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack(alignment: .leading) {
            if isLoading {
                placeholder()
                    .matchedTransition(id: id, in: loadingTransitionNamespace, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            } else {
                content()
                    .matchedTransition(id: id, in: loadingTransitionNamespace, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.01)))
            }
        }
    }

    var taskCardTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .scale(scale: 0.965, anchor: .center).combined(with: .opacity),
            removal: .scale(scale: 0.985, anchor: .center).combined(with: .opacity)
        )
    }
}

// MARK: - Document Picker

private struct LocalBackupExportDocumentPicker: UIViewControllerRepresentable {
    let fileURL: URL
    let onComplete: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onComplete: (Bool) -> Void
        private var hasCompleted = false

        init(onComplete: @escaping (Bool) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            complete(with: true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            complete(with: false)
        }

        private func complete(with succeeded: Bool) {
            guard !hasCompleted else { return }
            hasCompleted = true
            onComplete(succeeded)
        }
    }
}

private struct LocalBackupImportDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    let onFailure: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.zip], asCopy: false)
        controller.delegate = context.coordinator
        controller.allowsMultipleSelection = false
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void
        private let onFailure: (Error) -> Void
        private var hasCompleted = false

        init(
            onPick: @escaping (URL) -> Void,
            onCancel: @escaping () -> Void,
            onFailure: @escaping (Error) -> Void
        ) {
            self.onPick = onPick
            self.onCancel = onCancel
            self.onFailure = onFailure
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !hasCompleted else { return }
            hasCompleted = true
            guard let url = urls.first else {
                onFailure(BackupError.backupFileCorrupted)
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !hasCompleted else { return }
            hasCompleted = true
            onCancel()
        }
    }
}

// MARK: - Shared Surface

private struct BackupTaskBackdropView: View {
    var body: some View {
        Color.overlay
            .opacity(0.46)
            .ignoresSafeArea()
    }
}

private struct BackupTaskCardView: View {
    let presentation: BackupTaskPresentation
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: Spacing.cozy) {
            ProgressView()
                .controlSize(.regular)

            BackupTaskMessageSwitcher(
                message: presentation.message,
                reduceMotion: reduceMotion
            )
        }
        .frame(maxWidth: 252)
        .padding(.horizontal, Spacing.section)
        .padding(.vertical, Spacing.double)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous)
                .fill(Color.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.containerLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 18, x: 0, y: 10)
        .padding(.horizontal, Spacing.double)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(
            reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.9, blendDuration: 0.16),
            value: presentation
        )
    }
}

private struct BackupTaskMessageSwitcher: View {
    let message: String
    let reduceMotion: Bool

    @State private var displayedMessage: String
    @State private var outgoingMessage: String?
    @State private var incomingOpacity: Double = 1
    @State private var outgoingOpacity: Double = 0
    @State private var incomingOffsetY: CGFloat = 0
    @State private var outgoingOffsetY: CGFloat = 0
    @State private var incomingBlur: CGFloat = 0
    @State private var outgoingBlur: CGFloat = 0

    init(message: String, reduceMotion: Bool) {
        self.message = message
        self.reduceMotion = reduceMotion
        _displayedMessage = State(initialValue: message)
    }

    var body: some View {
        ZStack {
            if let outgoingMessage {
                messageText(outgoingMessage)
                    .opacity(outgoingOpacity)
                    .offset(y: outgoingOffsetY)
                    .blur(radius: outgoingBlur)
                    .allowsHitTesting(false)
            }

            messageText(displayedMessage)
                .opacity(incomingOpacity)
                .offset(y: incomingOffsetY)
                .blur(radius: incomingBlur)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 42)
        .onChange(of: message) { _, newValue in
            guard newValue != displayedMessage else { return }
            transition(to: newValue)
        }
    }

    @ViewBuilder
    private func messageText(_ value: String) -> some View {
        Text(value)
            .font(SettingsTypography.rowValue)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func transition(to newValue: String) {
        outgoingMessage = displayedMessage
        displayedMessage = newValue

        if reduceMotion {
            incomingOpacity = 0
            outgoingOpacity = 1

            withAnimation(.easeInOut(duration: 0.18)) {
                incomingOpacity = 1
                outgoingOpacity = 0
            }

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                outgoingMessage = nil
            }
            return
        }

        incomingOpacity = 0
        outgoingOpacity = 1
        incomingOffsetY = 3
        outgoingOffsetY = 0
        incomingBlur = 2
        outgoingBlur = 0

        withAnimation(.smooth(duration: 0.24)) {
            incomingOpacity = 1
            outgoingOpacity = 0
            incomingOffsetY = 0
            outgoingOffsetY = -2
            incomingBlur = 0
            outgoingBlur = 3
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(240))
            outgoingMessage = nil
            outgoingOffsetY = 0
            outgoingBlur = 0
        }
    }
}

private struct InlineLoadingTextPlaceholder: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
            .fill(Color.controlFillSecondary)
            .frame(width: width, height: height)
            .modifier(InlineLoadingShimmerModifier())
    }
}

private struct InlineLoadingAvatarPlaceholder: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Color.controlFillSecondary)
            .frame(width: size, height: size)
            .modifier(InlineLoadingShimmerModifier())
    }
}

private struct InlineLoadingShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.38),
                            Color.white.opacity(0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: max(width * 0.55, 24))
                    .offset(x: phase * (width + max(width * 0.55, 24)))
                }
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous))
                .allowsHitTesting(false)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}

private struct MatchedLoadingTransitionModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.matchedGeometryEffect(id: id, in: namespace, properties: .frame, anchor: .leading)
        }
    }
}

private extension View {
    func matchedTransition<ID: Hashable>(
        id: ID,
        in namespace: Namespace.ID,
        reduceMotion: Bool
    ) -> some View {
        modifier(MatchedLoadingTransitionModifier(id: id, namespace: namespace, reduceMotion: reduceMotion))
    }
}

#Preview {
    NavigationStack {
        DataBackupView()
    }
    .environment(AppState())
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
