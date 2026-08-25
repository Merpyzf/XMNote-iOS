/**
 * [INPUT]: 依赖 App 环境中的 DesktopWebSessionCoordinator、系统剪贴板、OpenURL 与 XMSystemAlert
 * [OUTPUT]: 对外提供设置/电脑导入两种网页端入口，展示当前会话、分级启动反馈、固定局域网域名、IP 回退地址、自动启动、安全设置、页内使用说明入口与提示
 * [POS]: Views/Personal/DesktopWeb 的页面壳层；只控制 App 级会话，不持有 HTTP 服务生命周期
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 网页端入口场景；业务能力保持一致，仅按用户来路调整标题与任务引导。
enum DesktopWebEntryMode: Equatable {
    case settings
    case computerImport

    var title: String {
        switch self {
        case .settings:
            return "网页端"
        case .computerImport:
            return "从电脑导入"
        }
    }
}

/// iPhone 局域网网页服务入口，优先帮助用户在电脑浏览器完成后续任务。
struct DesktopWebView: View {
    private enum Layout {
        static let contentMaxWidth: CGFloat = 640
        static let groupedPanelCornerRadius: CGFloat = CornerRadius.containerXL
        static let cardContentInset: CGFloat = Spacing.screenEdge
        static let sectionTextInset: CGFloat = Spacing.screenEdge
        static let sectionSpacing: CGFloat = Spacing.double + Spacing.cozy
        static let sectionTitleBottomSpacing: CGFloat = Spacing.base
        static let rowMinHeight: CGFloat = 56
    }

    private static let helpURL = URL(string: "https://docs.xmnote.com/#/web/guide")!
    private static let usageHelpDescription: LocalizedStringKey =
        "电脑与 iPhone 需连接同一 Wi-Fi；连接期间请保持 App 在前台。"

    @Environment(DesktopWebSessionCoordinator.self) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State private var presentedError: DesktopWebErrorPresentation?
    @State private var presentedAccessAlert: DesktopWebAccessAlert?
    @State private var editingAccessCode = ""
    @State private var isUpdatingAccessAuth = false
    @State private var isShowingOtherAddresses = false

    let mode: DesktopWebEntryMode

    /// 注入入口模式；个人页沿用设置模式，书摘导入页使用电脑导入模式。
    init(mode: DesktopWebEntryMode = .settings) {
        self.mode = mode
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Layout.sectionSpacing) {
                serviceSettingsSection

                accessSecuritySection
                usageHelpSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .frame(maxWidth: Layout.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.surfacePage)
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .animation(
            reduceMotion ? .easeInOut(duration: 0.15) : .smooth,
            value: coordinator.state
        )
        .animation(reduceMotion ? nil : .smooth, value: coordinator.isAccessAuthEnabled)
        .onChange(of: coordinator.state) { _, state in
            guard case .failed(let failure) = state,
                  failure.recovery == .openSettings else {
                return
            }
            presentedError = DesktopWebErrorPresentation(
                title: "网页服务未能启动",
                message: failure.message,
                recovery: .openSettings
            )
        }
        .task {
            await coordinator.refreshAccessAuthSettings()
        }
        .xmSystemAlert(item: $presentedError) { presentation in
            errorDescriptor(for: presentation)
        }
        .xmSystemAlert(item: $presentedAccessAlert) { presentation in
            accessAlertDescriptor(for: presentation)
        }
    }

    /// 将访问结果、本次运行与冷启动偏好收进同一服务面板，建立从结果到控制的连续层级。
    private var serviceSettingsSection: some View {
        desktopWebSection(title: "网页服务") {
            desktopWebPanel {
                VStack(spacing: Spacing.none) {
                    if case .running(let addresses) = coordinator.state {
                        accessAddressRows(addresses)
                        DesktopWebDivider()
                    }

                    Toggle(
                        isOn: Binding(
                            get: { coordinator.isEnabled },
                            set: { coordinator.setEnabled($0) }
                        ),
                        label: {
                            desktopWebRowLabel(
                                title: "允许电脑访问",
                                detail: serviceStatusDetail
                            )
                        }
                    )
                    .disabled(coordinator.state.isTransitioning)
                    .tint(Color.brand)
                    .padding(.horizontal, Layout.cardContentInset)
                    .padding(.top, Spacing.base)
                    .padding(
                        .bottom,
                        hasAttachedServiceFeedback ? Spacing.cozy : Spacing.base
                    )
                    .frame(minHeight: Spacing.actionReserved)

                    if case .waitingForLocalNetwork = coordinator.state {
                        attachedStatusMessage(
                            "请连接 Wi-Fi，并在系统设置中允许 XMNote 访问本地网络",
                            color: .textSecondary
                        )
                    }

                    if case .failed(let failure) = coordinator.state,
                       failure.recovery == .retry {
                        retryableFailureRow(failure)
                    }

                    DesktopWebDivider()

                    Toggle(
                        isOn: Binding(
                            get: { coordinator.isAutoStartEnabled },
                            set: { coordinator.setAutoStartEnabled($0) }
                        ),
                        label: {
                            desktopWebRowLabel(
                                title: "自动启动",
                                detail: "下次打开 App 时自动开启网页端"
                            )
                        }
                    )
                    .tint(Color.brand)
                    .padding(.horizontal, Layout.cardContentInset)
                    .frame(minHeight: Layout.rowMinHeight + Spacing.cozy)
                }
            }
        }
    }

    /// 访问码只在 App 内展示；编辑、重置与失败继续使用统一系统弹窗。
    private var accessSecuritySection: some View {
        desktopWebSection(title: "安全") {
            desktopWebPanel(isSingleItem: !coordinator.isAccessAuthEnabled) {
                VStack(spacing: Spacing.none) {
                    Toggle(
                        isOn: Binding(
                            get: { coordinator.isAccessAuthEnabled },
                            set: updateAccessAuth
                        ),
                        label: {
                            desktopWebRowLabel(
                                title: "访问授权码",
                                detail: coordinator.isAccessAuthEnabled
                                    ? "电脑端访问数据时需要验证"
                                    : "同一局域网设备无需验证"
                            )
                        }
                    )
                    .disabled(isUpdatingAccessAuth)
                    .tint(Color.brand)
                    .padding(.horizontal, Layout.cardContentInset)
                    .frame(minHeight: Layout.rowMinHeight + Spacing.cozy)

                    if coordinator.isAccessAuthEnabled {
                        DesktopWebDivider()

                        accessCodeRow
                    }
                }
            }
        }
    }

    /// 以低视觉权重的页内文本行提供使用说明，并用简短事实说明连接前置条件。
    private var usageHelpSection: some View {
        Button {
            openURL(Self.helpURL)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.half) {
                Label("网页端使用说明", systemImage: "questionmark.circle")
                    .labelStyle(.titleAndIcon)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)

                Text(Self.usageHelpDescription)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: Spacing.actionReserved,
                alignment: .topLeading
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("网页端使用说明")
        .accessibilityValue(Text(Self.usageHelpDescription))
        .accessibilityHint("在浏览器中打开使用说明")
        .padding(.horizontal, Layout.sectionTextInset)
    }

    private var serviceStatusDetail: String {
        switch coordinator.state {
        case .stopped:
            return "当前已停止"
        case .starting:
            return "正在启动…"
        case .waitingForLocalNetwork:
            return "等待局域网连接"
        case .running(let addresses):
            return addresses.isSimulatorOnly
                ? "已运行，仅可从当前 Mac 访问"
                : "已运行，可从同一局域网访问"
        case .stopping:
            return "正在停止…"
        case .failed(let failure):
            return failure.recovery == .openSettings
                ? "需要本地网络权限"
                : "启动失败"
        }
    }

    private var hasAttachedServiceFeedback: Bool {
        switch coordinator.state {
        case .waitingForLocalNetwork:
            return true
        case .failed(let failure):
            return failure.recovery == .retry
        default:
            return false
        }
    }

    /// 依次展示固定域名、IP 回退和域名状态；模拟器只保留当前 Mac 可用的访问地址。
    @ViewBuilder
    private func accessAddressRows(_ addresses: DesktopWebAccessAddresses) -> some View {
        if let domainURL = addresses.domainURL {
            addressRow(
                title: "局域网地址",
                url: domainURL,
                accessibilityLabel: "电脑局域网域名",
                copyActionName: "复制局域网地址"
            )
            DesktopWebDivider()
        }

        if let primaryIPEndpoint = addresses.ipEndpoints.first {
            addressRow(
                title: addresses.isSimulatorOnly ? "访问地址" : "局域网 IP 地址",
                url: primaryIPEndpoint.url,
                accessibilityLabel: addresses.isSimulatorOnly
                    ? "网页访问地址"
                    : "电脑局域网 IP 地址",
                copyActionName: addresses.isSimulatorOnly
                    ? "复制访问地址"
                    : "复制局域网 IP 地址"
            )
        }

        let otherEndpoints = Array(addresses.ipEndpoints.dropFirst())
        if !otherEndpoints.isEmpty {
            DesktopWebDivider()
            otherEndpointsDisclosure(otherEndpoints)
        }

        if let domainStatusMessage = addresses.domainStatusMessage {
            DesktopWebDivider()
            statusMessage(domainStatusMessage, color: .feedbackWarning)
        }
    }

    /// 把授权码操作统一收进整行长按菜单，并为辅助技术暴露等价动作。
    private var accessCodeRow: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text("访问授权码")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)

            Text(accessCodeDisplayValue)
                .font(AppTypography.callout.monospaced())
                .foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.cardContentInset)
        .padding(.vertical, Spacing.base)
        .contentShape(Rectangle())
        .contextMenu {
            accessCodeContextMenuActions
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("访问授权码")
        .accessibilityValue(accessCodeDisplayValue)
        .accessibilityHint("长按显示操作菜单")
        .accessibilityActions {
            accessCodeAccessibilityActions
        }
    }

    private var accessCodeDisplayValue: String {
        coordinator.accessAuthCode.isEmpty
            ? "正在生成…"
            : coordinator.accessAuthCode
    }

    @ViewBuilder
    private var accessCodeContextMenuActions: some View {
        if !coordinator.accessAuthCode.isEmpty {
            Button("复制") {
                copyAccessCode()
            }
        }

        Button("编辑") {
            presentAccessCodeEditor()
        }
        .disabled(coordinator.accessAuthCode.isEmpty || isUpdatingAccessAuth)

        Divider()

        Button("重新生成", role: .destructive) {
            presentAccessCodeResetConfirmation()
        }
        .disabled(isUpdatingAccessAuth)
    }

    @ViewBuilder
    private var accessCodeAccessibilityActions: some View {
        if !coordinator.accessAuthCode.isEmpty {
            Button("复制") {
                copyAccessCode()
            }
        }

        Button("编辑") {
            presentAccessCodeEditor()
        }
        .disabled(coordinator.accessAuthCode.isEmpty || isUpdatingAccessAuth)

        Button("重新生成", role: .destructive) {
            presentAccessCodeResetConfirmation()
        }
        .disabled(isUpdatingAccessAuth)
    }

    /// 展示一条可复制地址；标题与无障碍文案保留本地化资源语义。
    private func addressRow(
        title: LocalizedStringResource,
        url: URL,
        accessibilityLabel: LocalizedStringResource,
        copyActionName: LocalizedStringResource
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(title)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)

            Text(url.absoluteString)
                .font(AppTypography.callout)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contextMenu {
                    Button("复制") {
                        copy(url.absoluteString)
                    }
                }
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityValue(url.absoluteString)
                .accessibilityHint("长按显示复制菜单")
                .accessibilityAction(named: Text(copyActionName)) {
                    copy(url.absoluteString)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.cardContentInset)
        .padding(.vertical, Spacing.base)
        .frame(minHeight: Layout.rowMinHeight)
    }

    /// 把低频备用地址收起，仅在排障或多网卡场景中按需展开。
    private func otherEndpointsDisclosure(
        _ endpoints: [LocalNetworkEndpoint]
    ) -> some View {
        DisclosureGroup(
            isExpanded: $isShowingOtherAddresses,
            content: {
                VStack(spacing: Spacing.none) {
                    ForEach(Array(endpoints.enumerated()), id: \.element.id) { index, endpoint in
                        if index > 0 {
                            DesktopWebDivider(leadingInset: Spacing.none)
                        }
                        otherEndpointRow(endpoint)
                    }
                }
                .padding(.top, Spacing.cozy)
            },
            label: {
                Text("其他局域网 IP 地址")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }
        )
        .padding(.horizontal, Layout.cardContentInset)
        .frame(minHeight: Spacing.actionReserved)
        .animation(reduceMotion ? nil : .smooth, value: isShowingOtherAddresses)
    }

    private func desktopWebSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Layout.sectionTitleBottomSpacing) {
            Text(title)
                .font(AppTypography.footnoteSemibold)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Layout.sectionTextInset)

            content()
        }
    }

    /// 按可见设置项数量选择分组圆角或完整胶囊，仅复用当前页面既有表层颜色。
    @ViewBuilder
    private func desktopWebPanel<Content: View>(
        isSingleItem: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if isSingleItem {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceCard)
                .clipShape(Capsule())
        } else {
            CardContainer(cornerRadius: Layout.groupedPanelCornerRadius) {
                content()
            }
        }
    }

    private func desktopWebRowLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(title)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textPrimary)

            Text(detail)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func otherEndpointRow(_ endpoint: LocalNetworkEndpoint) -> some View {
        HStack(spacing: Spacing.base) {
            Text(endpoint.url.absoluteString)
                .font(AppTypography.callout)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contextMenu {
                    Button("复制") {
                        copy(endpoint.url.absoluteString)
                    }
                }
                .accessibilityHint("长按显示复制菜单")
                .accessibilityAction(named: Text("复制其他可用地址")) {
                    copy(endpoint.url.absoluteString)
                }
        }
        .padding(.vertical, Spacing.cozy)
    }

    private func statusMessage(_ message: String, color: Color) -> some View {
        Text(message)
            .font(AppTypography.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Layout.cardContentInset)
            .padding(.vertical, Spacing.contentEdge)
    }

    /// 在服务开关下方展示同组状态，使视觉间距不受独立触控框影响。
    private func attachedStatusMessage(_ message: String, color: Color) -> some View {
        Text(message)
            .font(AppTypography.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Layout.cardContentInset)
            .padding(.bottom, Spacing.base)
    }

    /// 将可重试故障贴近当前会话开关，并在窄宽度或大字体下切换为纵向操作布局。
    private func retryableFailureRow(_ failure: DesktopWebSessionFailure) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Spacing.base) {
                retryableFailureMessage(failure.message)

                Spacer(minLength: Spacing.cozy)

                retryButton
            }

            VStack(alignment: .leading, spacing: Spacing.compact) {
                retryableFailureMessage(failure.message)

                retryButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, Layout.cardContentInset)
        .transition(
            reduceMotion
                ? .opacity
                : .move(edge: .top).combined(with: .opacity)
        )
    }

    private func retryableFailureMessage(_ message: String) -> some View {
        Text(message)
            .font(AppTypography.caption)
            .foregroundStyle(Color.feedbackError)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var retryButton: some View {
        Button {
            coordinator.retry()
        } label: {
            Text("重新尝试")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textPrimary)
                .frame(minHeight: Spacing.actionReserved, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 异步保存访问安全设置；任务固定在 MainActor 回写，Repository actor 串行保护持久化顺序。
    private func updateAccessAuth(_ enabled: Bool) {
        isUpdatingAccessAuth = true
        Task { @MainActor in
            await coordinator.setAccessAuthEnabled(enabled)
            isUpdatingAccessAuth = false
        }
    }

    /// 复制当前有效授权码；生成中的占位状态不会写入剪贴板。
    private func copyAccessCode() {
        guard !coordinator.accessAuthCode.isEmpty else { return }
        copy(coordinator.accessAuthCode)
    }

    /// 使用当前授权码预填编辑弹窗；生成中或保存中保持不可执行。
    private func presentAccessCodeEditor() {
        guard !coordinator.accessAuthCode.isEmpty, !isUpdatingAccessAuth else { return }
        editingAccessCode = coordinator.accessAuthCode
        presentedAccessAlert = DesktopWebAccessAlert(kind: .edit)
    }

    /// 展示重新生成确认弹窗；实际重置继续由原有异步流程负责。
    private func presentAccessCodeResetConfirmation() {
        guard !isUpdatingAccessAuth else { return }
        presentedAccessAlert = DesktopWebAccessAlert(kind: .reset)
    }

    /// 响应用户从系统上下文菜单选择的复制操作，将当前值写入系统剪贴板。
    private func copy(_ value: String) {
        UIPasteboard.general.string = value
    }

    /// 使用系统弹窗提供单一主恢复动作，普通动作保持系统默认颜色语义。
    private func errorDescriptor(
        for presentation: DesktopWebErrorPresentation
    ) -> XMSystemAlertDescriptor {
        let primaryAction: XMSystemAlertAction
        switch presentation.recovery {
        case .retry:
            primaryAction = XMSystemAlertAction(title: "重新尝试") {
                coordinator.retry()
            }
        case .openSettings:
            primaryAction = XMSystemAlertAction(title: "打开设置") {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }
                openURL(settingsURL)
            }
        }
        return XMSystemAlertDescriptor(
            title: presentation.title,
            message: presentation.message,
            actions: [
                primaryAction,
                XMSystemAlertAction(title: "取消", role: .cancel) {}
            ]
        )
    }

    /// 生成访问码编辑或重置弹窗；异步写入固定回到 MainActor 更新可观察状态与错误展示。
    private func accessAlertDescriptor(
        for presentation: DesktopWebAccessAlert
    ) -> XMSystemAlertDescriptor {
        switch presentation.kind {
        case .edit:
            return XMSystemAlertDescriptor(
                title: "编辑访问授权码",
                message: "请输入 8–32 位小写字母或数字。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) {},
                    XMSystemAlertAction(title: "保存") {
                        isUpdatingAccessAuth = true
                        Task { @MainActor in
                            do {
                                try await coordinator.setAccessAuthCode(editingAccessCode)
                            } catch {
                                presentedError = DesktopWebErrorPresentation(
                                    title: "无法保存访问授权码",
                                    message: error.localizedDescription
                                )
                            }
                            isUpdatingAccessAuth = false
                        }
                    }
                ],
                textFields: [
                    XMSystemAlertTextField(
                        text: $editingAccessCode,
                        placeholder: "8–32 位小写字母或数字",
                        keyboardType: .asciiCapable,
                        textInputAutocapitalization: .none,
                        autocorrectionDisabled: true
                    )
                ]
            )
        case .reset:
            return XMSystemAlertDescriptor(
                title: "重新生成访问授权码",
                message: "重新生成后，已在电脑端保存的旧授权码将立即失效。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) {},
                    XMSystemAlertAction(title: "重新生成", role: .destructive) {
                        isUpdatingAccessAuth = true
                        Task { @MainActor in
                            await coordinator.resetAccessAuthCode()
                            isUpdatingAccessAuth = false
                        }
                    }
                ]
            )
        }
    }
}

/// 分组面板内的轻量分隔线，保持与“我的”“数据备份”设置面板一致。
private struct DesktopWebDivider: View {
    let leadingInset: CGFloat

    init(leadingInset: CGFloat = Spacing.screenEdge) {
        self.leadingInset = leadingInset
    }

    var body: some View {
        Rectangle()
            .fill(Color.surfaceBorderSubtle.opacity(0.5))
            .frame(height: CardStyle.borderWidth)
            .padding(.leading, leadingInset)
    }
}

/// 系统弹窗 item，确保同一错误状态只触发一次展示周期。
private struct DesktopWebErrorPresentation: Identifiable {
    enum Recovery {
        case retry
        case openSettings
    }

    let id = UUID()
    let title: String
    let message: String
    let recovery: Recovery

    init(
        title: String,
        message: String,
        recovery: Recovery = .retry
    ) {
        self.title = title
        self.message = message
        self.recovery = recovery
    }
}

/// 访问安全弹窗身份；每次动作使用新 id，允许连续编辑或重置触发独立展示周期。
private struct DesktopWebAccessAlert: Identifiable {
    enum Kind {
        case edit
        case reset
    }

    let id = UUID()
    let kind: Kind
}
