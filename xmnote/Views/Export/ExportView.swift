/**
 * [INPUT]: 依赖 RepositoryContainer/AppState、ExportViewModel、项目设置页/选择/状态组件及系统分享与保存桥接
 * [OUTPUT]: 对外提供 ExportView，承载范围、类型与目标、配置、预检、执行和结果的原生导出流程
 * [POS]: Views/Export 的统一页面入口，由个人页、书籍、书架多选和书单详情通过 AppRoute.export 打开
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 原生导出页面壳层只负责注入 Repository 和会员快照，运行中状态不参与导航恢复。
struct ExportView: View {
    @Environment(AppState.self) private var appState
    @Environment(RepositoryContainer.self) private var repositories
    let route: ExportRoute
    @State private var viewModel: ExportViewModel?

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()
            if let viewModel {
                ExportContentView(viewModel: viewModel)
            } else {
                LoadingStateView("正在读取导出设置…", style: .card)
            }
        }
        .navigationTitle("导出")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            let model = ExportViewModel(
                route: route,
                repository: repositories.exportRepository,
                isPremium: appState.isPremium
            )
            viewModel = model
            await model.load()
        }
    }
}

/// 配置加载后的导出页面，保持设置页面组件和系统交付控制器的既有交互语义。
private struct ExportContentView: View {
    @Bindable var viewModel: ExportViewModel

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                LoadingStateView("正在读取导出设置…", style: .card)
            case .configuring:
                configurationPage
            case .running:
                runningPage
            case .result:
                resultPage
            }
        }
        .xmSystemAlert(
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            ),
            descriptor: XMSystemAlertDescriptor(
                title: "无法继续导出",
                message: viewModel.errorMessage ?? "",
                actions: [
                    XMSystemAlertAction(title: "知道了", role: .cancel) {
                        viewModel.errorMessage = nil
                    }
                ]
            )
        )
        .confirmationDialog(
            "重建 Notion 托管页面？",
            isPresented: $viewModel.showsNotionPageRebuildConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认重建") {
                Task { await viewModel.rebuildDeletedNotionPages() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会为已被移入回收站的书籍重新创建托管页面；本批其他书籍不会重复导出。")
        }
        .sheet(isPresented: $viewModel.showsShareSheet) {
            XMActivityShareSheet(activityItems: viewModel.localArtifactURLs) { _ in
                viewModel.finishArtifactDelivery()
            }
        }
        .sheet(isPresented: $viewModel.showsDocumentPicker) {
            ExportDocumentPicker(fileURLs: viewModel.localArtifactURLs) { _ in
                viewModel.finishArtifactDelivery()
            }
        }
    }

    private var configurationPage: some View {
        XMSettingsPage {
            stepHeader
            switch viewModel.step {
            case .scope:
                scopeSection
            case .target:
                targetSections
            case .configuration:
                settingsSections
            case .preflight:
                preflightSections
            }
        }
        .safeAreaInset(edge: .bottom) {
            configurationActionBar
        }
    }

    private var stepHeader: some View {
        HStack(spacing: Spacing.half) {
            ForEach(ExportConfigurationStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= viewModel.step.rawValue
                        ? Color.appTint
                        : Color.controlFillSecondary)
                    .frame(height: 4)
                    .accessibilityLabel(step.title)
                    .accessibilityValue(step.rawValue <= viewModel.step.rawValue ? "已完成" : "未完成")
            }
        }
        .padding(.horizontal, Spacing.contentEdge)
    }

    private var scopeSection: some View {
        XMSettingsSection("导出范围") {
            XMSettingsGroup {
                exportSelectionRow(
                    title: "全部书籍",
                    subtitle: "按任务开始时的实际查询顺序冻结",
                    isSelected: viewModel.scope == .allBooks
                ) {
                    viewModel.scope = .allBooks
                }
                if viewModel.scope != .allBooks {
                    XMSettingsDivider()
                    exportSelectionRow(
                        title: scopeTitle(viewModel.scope),
                        subtitle: "保持入口提供的书籍或书单顺序",
                        isSelected: true
                    ) {}
                }
            }
        }
    }

    private var targetSections: some View {
        Group {
            XMSettingsSection("导出类型") {
                XMSettingsGroup {
                    ForEach(Array(ExportKind.allCases.enumerated()), id: \.element) { index, kind in
                        if index > 0 { XMSettingsDivider() }
                        exportSelectionRow(
                            title: kind.title,
                            subtitle: kind == .noteExcerpt ? "书评、关联笔记与书摘" : "按字段导出书库信息",
                            isSelected: viewModel.kind == kind
                        ) {
                            viewModel.selectKind(kind)
                        }
                    }
                }
            }

            XMSettingsSection("导出目标") {
                XMSettingsGroup {
                    let targets = ExportTarget.supportedTargets(for: viewModel.kind)
                    ForEach(Array(targets.enumerated()), id: \.element) { index, target in
                        if index > 0 { XMSettingsDivider() }
                        exportSelectionRow(
                            title: target.title,
                            subtitle: target.requiresPremium ? "高级版" : "免费",
                            isSelected: viewModel.target == target,
                            isEnabled: !target.requiresPremium || viewModel.isPremiumAccessAvailable
                        ) {
                            viewModel.selectTarget(target)
                        }
                    }
                }
            }
        }
    }

    private var settingsSections: some View {
        Group {
            if viewModel.kind == .noteExcerpt {
                noteContentSection
            } else {
                bookFieldsSection
            }
            localFormattingSection
            if !viewModel.target.isLocalFile {
                remoteConfigurationSection
            }
        }
    }

    private var noteContentSection: some View {
        XMSettingsSection("内容") {
            XMSettingsGroup {
                XMSettingsToggleRow(
                    title: "书评",
                    isOn: $viewModel.settings.content.includesReviews
                )
                XMSettingsDivider()
                XMSettingsToggleRow(
                    title: "关联笔记",
                    isOn: $viewModel.settings.content.includesRelatedNotes
                )
                XMSettingsDivider()
                XMSettingsToggleRow(
                    title: "书摘",
                    isOn: $viewModel.settings.content.includesNotes
                )
            }
        }
    }

    private var localFormattingSection: some View {
        XMSettingsSection("格式") {
            XMSettingsGroup {
                XMSettingsToggleRow(title: "日期与时间", isOn: $viewModel.settings.includesDateTime)
                XMSettingsDivider()
                XMSettingsToggleRow(title: "页码或进度", isOn: $viewModel.settings.includesPage)
                XMSettingsDivider()
                XMSettingsToggleRow(title: "标签", isOn: $viewModel.settings.includesTags)
                XMSettingsDivider()
                XMSettingsToggleRow(title: "书籍信息", isOn: $viewModel.settings.includesBookInformation)
            }
        }
    }

    private var bookFieldsSection: some View {
        XMSettingsSection("书籍字段") {
            XMSettingsGroup {
                ForEach(viewModel.settings.bookFields.indices, id: \.self) { index in
                    if index > 0 { XMSettingsDivider() }
                    HStack(spacing: Spacing.base) {
                        Toggle(
                            viewModel.settings.bookFields[index].field.title,
                            isOn: $viewModel.settings.bookFields[index].isEnabled
                        )
                        .font(SettingsTypography.rowTitle)
                        .foregroundStyle(Color.textPrimary)
                        .tint(Color.appTint)
                        .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
                        Spacer(minLength: 0)
                        VStack(spacing: Spacing.tiny) {
                            fieldMoveButton(systemName: "chevron.up", index: index, offset: -1)
                            fieldMoveButton(systemName: "chevron.down", index: index, offset: 1)
                        }
                    }
                }
            }
        }
    }

    private var remoteConfigurationSection: some View {
        XMSettingsSection("连接") {
            XMSettingsGroup {
                remoteEndpointFields
                if let _ = viewModel.editableCredential {
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        HStack {
                            Text(viewModel.isCredentialConfigured ? "凭据已保存" : "尚未保存凭据")
                                .font(SettingsTypography.rowTitle)
                                .foregroundStyle(Color.textPrimary)
                            Spacer()
                            Image(systemName: viewModel.isCredentialConfigured ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(viewModel.isCredentialConfigured ? Color.feedbackSuccess : Color.iconSecondary)
                        }
                        SecureField("输入 \(viewModel.target.title) 凭据", text: $viewModel.pendingCredential)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, Spacing.base)
                            .frame(minHeight: XMSettingsPageLayout.inputMinHeight)
                            .background(Color.controlFillSecondary, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium))
                        Button("保存凭据") {
                            Task { await viewModel.savePendingCredential() }
                        }
                        .disabled(viewModel.pendingCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.vertical, Spacing.cozy)
                } else {
                    XMInlineStatusBanner(
                        viewModel.target == .notion
                            ? "Notion 使用 OAuth 连接，不接受旧版 token 或页面 ID。"
                            : "OneNote 使用 Microsoft 账户授权，客户端不会保存 secret。",
                        tone: .neutral
                    )
                    .padding(.vertical, Spacing.cozy)
                    if viewModel.target == .notion {
                        exportTextField("Notion Data Source ID", text: $viewModel.settings.notionDataSourceID)
                    }
                    Button(viewModel.isCredentialConfigured ? "重新连接" : "连接账户") {
                        Task { await viewModel.connectCurrentAccount() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.primaryActionFill)
                    .padding(.bottom, Spacing.cozy)
                }
            }
        }
    }

    @ViewBuilder
    private var remoteEndpointFields: some View {
        switch viewModel.target {
        case .oneNote:
            exportTextField("OneNote 分区名称", text: $viewModel.settings.oneNoteSectionName)
            XMSettingsDivider()
        case .siYuan:
            exportTextField("思源主机或 IP", text: $viewModel.settings.siYuanHost)
            XMSettingsDivider()
            exportTextField(
                "思源端口",
                text: Binding(
                    get: { String(viewModel.settings.siYuanPort) },
                    set: { if let value = Int($0) { viewModel.settings.siYuanPort = value } }
                )
            )
            XMSettingsDivider()
            exportTextField("笔记本 ID", text: $viewModel.settings.siYuanNotebookID)
            XMSettingsDivider()
        case .obsidian:
            exportTextField("Obsidian 主机或 IP", text: $viewModel.settings.obsidianHost)
            XMSettingsDivider()
            exportTextField("Vault 目录（可留空）", text: $viewModel.settings.obsidianDirectory)
            XMSettingsDivider()
            exportTextField(
                "证书 SHA-256（自签名证书必填）",
                text: $viewModel.settings.obsidianPinnedCertificateSHA256
            )
            XMSettingsDivider()
        case .notion, .yuque, .pdf, .markdown, .text, .csv:
            EmptyView()
        }
    }

    private func exportTextField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, Spacing.base)
            .frame(minHeight: XMSettingsPageLayout.inputMinHeight)
            .background(
                Color.controlFillSecondary,
                in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium)
            )
            .padding(.vertical, Spacing.half)
    }

    private var preflightSections: some View {
        Group {
            XMSettingsSection("确认导出") {
                XMSettingsGroup {
                    summaryRow("范围", value: scopeTitle(viewModel.scope))
                    XMSettingsDivider()
                    summaryRow("类型", value: viewModel.kind.title)
                    XMSettingsDivider()
                    summaryRow("目标", value: viewModel.target.title)
                }
            }
            if viewModel.target.requiresPremium {
                XMInlineStatusBanner("该目标需要高级版，执行时仍会由 Repository 再次校验会员状态。")
            }
        }
    }

    private var configurationActionBar: some View {
        HStack(spacing: Spacing.base) {
            if viewModel.step != .scope {
                Button("上一步") { viewModel.goBack() }
                    .buttonStyle(.bordered)
            }
            Button(viewModel.step == .preflight ? "开始导出" : "下一步") {
                Task { await viewModel.advance() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.primaryActionFill)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(!viewModel.canAdvance)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
        .background(.bar)
    }

    private var runningPage: some View {
        VStack(spacing: Spacing.double) {
            Spacer()
            ProgressView(value: viewModel.progress.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(Color.appTint)
                .frame(maxWidth: 320)
            Text(viewModel.progress.message)
                .font(AppTypography.body)
                .foregroundStyle(Color.textSecondary)
            Button("取消") { viewModel.cancelExport() }
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding(Spacing.screenEdge)
    }

    @ViewBuilder
    private var resultPage: some View {
        if let result = viewModel.result {
            ScrollView {
                VStack(spacing: Spacing.double) {
                    XMContentStateView(
                        role: result.isCompleteSuccess ? .instruction : .failure,
                        title: result.isCompleteSuccess ? "导出完成" : "导出已结束",
                        message: result.failures.isEmpty
                            ? "已成功导出 \(result.successCount) 本书"
                            : "成功 \(result.successCount) 本，失败 \(result.failures.count) 本",
                        systemImage: result.isCompleteSuccess ? "checkmark.circle" : nil
                    )
                    if result.hasUncertainRemoteResult {
                        XMInlineStatusBanner(
                            "远端可能已经完成写入。请先到 \(viewModel.target.title) 核对结果，避免重复内容。",
                            tone: .warning
                        )
                    }
                    if !result.failures.isEmpty {
                        failureSection(result.failures)
                    }
                    if !result.notionPageRebuildBookIDs.isEmpty {
                        Button("确认并重建已删除页面") {
                            viewModel.showsNotionPageRebuildConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.primaryActionFill)
                    }
                    if result.artifactTicket != nil {
                        HStack(spacing: Spacing.base) {
                            Button("分享") { viewModel.showsShareSheet = true }
                                .buttonStyle(.bordered)
                            Button("存储到文件") { viewModel.showsDocumentPicker = true }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.primaryActionFill)
                        }
                    } else if result.canSafelyRetry {
                        Button("重试") { Task { await viewModel.retry() } }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.primaryActionFill)
                    }
                }
                .padding(Spacing.screenEdge)
            }
        } else {
            XMContentStateView(role: .failure, title: "没有导出结果")
        }
    }

    private func failureSection(_ failures: [ExportFailure]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text(failure.bookName ?? failure.target.title)
                        .font(SettingsTypography.rowTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text(failure.message)
                        .font(SettingsTypography.rowValue)
                        .foregroundStyle(Color.textSecondary)
                    Text(failureDispositionTitle(failure.disposition))
                        .font(AppTypography.caption)
                        .foregroundStyle(failure.disposition == .resultUncertain
                            ? Color.feedbackWarning
                            : Color.textSecondary.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.base)
                .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium))
            }
        }
    }

    private func failureDispositionTitle(_ value: ExportFailureDisposition) -> String {
        switch value {
        case .retryable: "可安全重试"
        case .nonRetryable: "请修改配置或核对远端后重新导出"
        case .resultUncertain: "结果不确定，请勿直接重试"
        }
    }

    private func exportSelectionRow(
        title: String,
        subtitle: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text(title)
                        .font(SettingsTypography.rowTitle)
                        .foregroundStyle(Color.textPrimary)
                    Text(subtitle)
                        .font(SettingsTypography.rowValue)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                XMSelectionIndicator(
                    style: .radio,
                    isSelected: isSelected,
                    font: AppTypography.body
                )
            }
            .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(SettingsTypography.rowTitle).foregroundStyle(Color.textPrimary)
            Spacer()
            Text(value).font(SettingsTypography.rowValue).foregroundStyle(Color.textSecondary)
        }
        .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
    }

    private func fieldMoveButton(systemName: String, index: Int, offset: Int) -> some View {
        let destination = index + offset
        return Button {
            guard viewModel.settings.bookFields.indices.contains(destination) else { return }
            viewModel.settings.bookFields.swapAt(index, destination)
        } label: {
            Image(systemName: systemName)
                .font(AppTypography.caption)
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.iconSecondary)
        .disabled(!viewModel.settings.bookFields.indices.contains(destination))
    }

    private func scopeTitle(_ scope: ExportScope) -> String {
        switch scope {
        case .allBooks: "全部书籍"
        case .bookIDs(let ids): ids.count == 1 ? "当前书籍" : "已选 \(ids.count) 本书"
        case .collectionID: "当前书单"
        }
    }
}
