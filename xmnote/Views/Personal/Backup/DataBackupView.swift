/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 DataBackupViewModel 驱动状态
 * [OUTPUT]: 对外提供 DataBackupView，承载 provider 选择、授权状态与手动备份/恢复入口
 * [POS]: Backup 模块入口壳层，对齐 Android 的云备份 provider 切换模式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 数据备份入口页，聚合 provider 选择、当前 provider 状态与手动备份/恢复入口。
struct DataBackupView: View {
    @Environment(AppState.self) private var appState
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: DataBackupViewModel?

    var body: some View {
        Group {
            if let viewModel {
                DataBackupContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("数据备份")
                    .font(AppTypography.headlineSemibold)
            }
        }
        .task {
            guard viewModel == nil else { return }
            let viewModel = DataBackupViewModel(
                backupRepository: repositories.backupRepository,
                onRestoreSucceeded: { appState.dataEpoch += 1 }
            )
            self.viewModel = viewModel
            await viewModel.loadPageData()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active, let viewModel else { return }
            Task { await viewModel.refreshOnBecomeActive() }
        }
    }
}

// MARK: - Content View

private struct DataBackupContentView: View {
    private enum Layout {
        static let panelCornerRadius: CGFloat = CornerRadius.containerMedium
        static let panelSpacing: CGFloat = Spacing.comfortable
        static let rowIconWidth: CGFloat = 24
        static let rowVerticalPadding: CGFloat = Spacing.comfortable
        static let providerRowVerticalPadding: CGFloat = Spacing.cozy
        static let providerTriggerMinWidth: CGFloat = 92
        static let providerTriggerMinHeight: CGFloat = 44
        static let sectionDividerLeading: CGFloat = Spacing.contentEdge
        static let rowDividerLeading: CGFloat = Spacing.contentEdge + rowIconWidth + Spacing.base
        static let avatarSize: CGFloat = 40
        static let avatarDividerLeading: CGFloat = Spacing.contentEdge + avatarSize + Spacing.base
    }

    @Bindable var viewModel: DataBackupViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var loadingTransitionNamespace

    var body: some View {
        ScrollView {
            contentSections
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
        }
        .overlay { taskBackdropOverlay }
        .overlay { taskCardOverlay }
        .animation(reduceMotion ? nil : .snappy(duration: 0.32), value: viewModel.blockingAction)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: viewModel.operationState != .idle)
        .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: viewModel.initialLoadState)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: viewModel.lastBackupState)
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定") {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("恢复成功", isPresented: $viewModel.showRestoreSuccess) {
            Button("确定") {
                viewModel.acknowledgeRestoreSuccess()
            }
        } message: {
            Text("数据已恢复，页面将刷新")
        }
        .sheet(isPresented: $viewModel.isShowingBackupHistory) {
            BackupHistorySheetView(viewModel: viewModel)
        }
    }
}

private extension DataBackupContentView {
    var contentSections: some View {
        VStack(spacing: Layout.panelSpacing) {
            cloudBackupPanel
            actionSection
        }
    }
}

// MARK: - Provider Section

private extension DataBackupContentView {

    var cloudBackupPanel: some View {
        BackupSettingsPanel(cornerRadius: Layout.panelCornerRadius) {
            VStack(spacing: Spacing.none) {
                providerSelectionRow
                BackupSettingsDivider(leadingInset: Layout.sectionDividerLeading)
                currentProviderContent
            }
        }
    }

    var providerSelectionRow: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("云备份方式")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)

                if viewModel.isProviderSummaryLoading || viewModel.selectedProviderSummary != nil {
                    fieldTransitionContainer(
                        id: "backup.provider.summary",
                        isLoading: viewModel.isProviderSummaryLoading
                    ) {
                        InlineLoadingTextPlaceholder(width: 72, height: 11)
                    } content: {
                        if let summary = viewModel.selectedProviderSummary {
                            Text(summary)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .contentTransition(.opacity)
                        }
                    }
                }
            }

            Spacer(minLength: Spacing.base)

            providerSelectionMenu
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Layout.providerRowVerticalPadding)
    }

    var providerSelectionMenu: some View {
        Menu {
            ForEach([CloudBackupProvider.webdav, .aliyunDrive]) { provider in
                Button {
                    Task { await viewModel.selectProvider(provider) }
                } label: {
                    if provider == viewModel.selectedProvider {
                        Label(provider.displayName, systemImage: "checkmark")
                            .foregroundStyle(.primary)
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        } label: {
            Group {
                if viewModel.isProviderSwitching {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    HStack(spacing: Spacing.compact) {
                        Text(viewModel.selectedProvider.displayName)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                            .contentTransition(.opacity)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)

                        Image(systemName: "chevron.down")
                            .font(AppTypography.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(
                minWidth: Layout.providerTriggerMinWidth,
                minHeight: Layout.providerTriggerMinHeight,
                alignment: .trailing
            )
            .contentShape(Rectangle())
        }
        .tint(nil)
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
        .accessibilityLabel("云备份方式")
        .accessibilityValue(viewModel.selectedProvider.displayName)
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
        NavigationLink(value: PersonalRoute.webdavServers) {
            HStack(spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("WebDAV 服务器")
                        .font(AppTypography.subheadlineMedium)
                        .foregroundStyle(Color.textPrimary)

                    fieldTransitionContainer(
                        id: "backup.provider.detail",
                        isLoading: viewModel.isProviderDetailLoading
                    ) {
                        InlineLoadingTextPlaceholder(width: 126, height: 11)
                    } content: {
                        Text(viewModel.currentServer?.title ?? "未配置")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .contentTransition(.opacity)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Layout.rowVerticalPadding)
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
                BackupSettingsDivider(leadingInset: Layout.avatarDividerLeading)
                revokeAliyunDriveButton
            } else if viewModel.isAliyunAuthorized {
                aliyunAuthorizedFallbackRow
                BackupSettingsDivider(leadingInset: Layout.rowDividerLeading)
                revokeAliyunDriveButton
            } else {
                authorizeAliyunDriveButton
            }
        }
    }

    var aliyunAuthorizedFallbackRow: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "checkmark.shield")
                .font(AppTypography.body)
                .foregroundStyle(Color.iconSecondary)
                .frame(width: Layout.rowIconWidth)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text("阿里云盘已登录")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                Text(viewModel.aliyunAccountInfoErrorMessage ?? "当前可继续进行云备份")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Layout.rowVerticalPadding)
    }

    var authorizeAliyunDriveButton: some View {
        Button {
            Task { await viewModel.authorizeAliyunDrive() }
        } label: {
            HStack(spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("登录阿里云盘")
                        .font(AppTypography.subheadlineMedium)
                        .foregroundStyle(Color.textPrimary)
                    Text("登录后可将备份保存到阿里云盘")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer()

                if viewModel.isAliyunAuthorizing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Layout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isBusy)
    }

    var revokeAliyunDriveButton: some View {
        Button {
            Task { await viewModel.revokeAliyunDriveAuthorization() }
        } label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.feedbackError)
                    .frame(width: Layout.rowIconWidth)

                Text("退出阿里云盘")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.feedbackError)

                Spacer()

                if viewModel.isAliyunRevoking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Layout.rowVerticalPadding)
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
                fieldTransitionContainer(
                    id: "backup.aliyun.title",
                    isLoading: false
                ) {
                    InlineLoadingTextPlaceholder(width: 92, height: 13)
                } content: {
                    Text(accountInfo.nickName)
                        .font(AppTypography.subheadlineMedium)
                        .foregroundStyle(Color.textPrimary)
                }
                fieldTransitionContainer(
                    id: "backup.aliyun.subtitle",
                    isLoading: false
                ) {
                    InlineLoadingTextPlaceholder(width: 138, height: 11)
                } content: {
                    Text(accountInfo.storageSummary ?? accountInfo.userId)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Layout.rowVerticalPadding)
    }

    var aliyunLoadingRow: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            fieldTransitionContainer(
                id: "backup.aliyun.login.title",
                isLoading: true
            ) {
                InlineLoadingTextPlaceholder(width: 104, height: 14)
            } content: {
                EmptyView()
            }
            fieldTransitionContainer(
                id: "backup.aliyun.login.subtitle",
                isLoading: true
            ) {
                InlineLoadingTextPlaceholder(width: 182, height: 11)
            } content: {
                EmptyView()
            }
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Layout.rowVerticalPadding)
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
}

// MARK: - Action Section

private extension DataBackupContentView {

    var actionSection: some View {
        BackupSettingsPanel(cornerRadius: Layout.panelCornerRadius) {
            VStack(spacing: Spacing.none) {
                backupButton
                BackupSettingsDivider(leadingInset: Layout.rowDividerLeading)
                restoreButton
            }
        }
    }

    var backupButton: some View {
        Button {
            Task { await viewModel.performBackup() }
        } label: {
            HStack(spacing: Spacing.base) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(width: Layout.rowIconWidth)

                Text("备份数据")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                fieldTransitionContainer(
                    id: "backup.lastBackup.value",
                    isLoading: viewModel.isLastBackupValueLoading
                ) {
                    InlineLoadingTextPlaceholder(width: 76, height: 11)
                } content: {
                    if !viewModel.lastBackupDateText.isEmpty {
                        Text(viewModel.lastBackupDateText)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(viewModel.lastBackupState == .failed ? Color.feedbackError : Color.textSecondary)
                            .contentTransition(viewModel.lastBackupState == .loaded(nil) ? .opacity : .numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)
                    }
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Layout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPerformCloudOperation)
    }

    var restoreButton: some View {
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
                    .frame(width: Layout.rowIconWidth)

                Text("恢复数据")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)

                Spacer()
                if viewModel.isBackupHistoryLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Spacing.contentEdge)
            .padding(.vertical, Layout.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.canPerformCloudOperation)
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

private struct BackupTaskBackdropView: View {
    var body: some View {
        Color.overlay
            .opacity(0.46)
            .ignoresSafeArea()
    }
}

private struct BackupSettingsPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content

    init(
        cornerRadius: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        CardContainer(cornerRadius: cornerRadius) {
            content
        }
    }
}

private struct BackupSettingsDivider: View {
    let leadingInset: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.surfaceBorderSubtle.opacity(0.55))
            .frame(height: CardStyle.borderWidth)
            .padding(.leading, leadingInset)
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
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
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
            .font(AppTypography.subheadline)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .contentTransition(.interpolate)
    }

    private func transition(to newValue: String) {
        outgoingMessage = displayedMessage
        displayedMessage = newValue

        if reduceMotion {
            incomingOpacity = 0
            outgoingOpacity = 1
            incomingOffsetY = 0
            outgoingOffsetY = 0
            incomingBlur = 0
            outgoingBlur = 0

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
