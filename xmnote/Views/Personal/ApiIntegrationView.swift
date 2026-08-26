/**
 * [INPUT]: 依赖 RepositoryContainer 注入 ExternalAppIntegrationRepositoryProtocol，依赖 ApiIntegrationViewModel 驱动状态概览与单项配置编辑
 * [OUTPUT]: 对外提供 ApiIntegrationView，承载 Flomo、Writeathon 与 Inbox 的关联应用状态列表和配置 Sheet
 * [POS]: Views/Personal 的 API 集成页面壳层，被 PersonalRoute.apiIntegration 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// API 集成配置页，提供关联应用状态概览并将具体配置编辑收进二级 Sheet。
struct ApiIntegrationView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(XMToastCenter.self) private var toastCenter
    @State private var viewModel: ApiIntegrationViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ApiIntegrationContentView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .navigationTitle("API 集成")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            let model = ApiIntegrationViewModel(repository: repositories.externalAppIntegrationRepository)
            model.load()
            viewModel = model
        }
        .onChange(of: viewModel?.feedback) { _, feedback in
            guard let feedback else { return }
            switch feedback.role {
            case .success:
                toastCenter.success(feedback.message)
            case .error:
                toastCenter.error(feedback.message)
            }
            viewModel?.consumeFeedback()
        }
    }
}

private struct ApiIntegrationContentView: View {
    @Bindable var viewModel: ApiIntegrationViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeDestination: ExternalAppDestination?

    var body: some View {
        XMSettingsPage {
            XMSettingsSection("关联应用") {
                XMSettingsGroup(verticalPadding: Spacing.none) {
                    VStack(spacing: Spacing.none) {
                        ForEach(ExternalAppDestination.allCases) { destination in
                            ApiIntegrationAppRow(
                                destination: destination,
                                isConfigured: viewModel.settings.isConfigured(destination)
                            ) {
                                viewModel.resetDraft(for: destination)
                                activeDestination = destination
                            }

                            if let lastDestination = ExternalAppDestination.allCases.last,
                               destination != lastDestination {
                                XMSettingsDivider()
                                    .padding(.leading, ApiIntegrationLayout.rowDividerLeadingInset)
                            }
                        }
                    }
                }
            }
        }
        .animation(settingsAnimation, value: viewModel.settings)
        .sheet(item: $activeDestination) { destination in
            ApiIntegrationEditSheet(destination: destination, viewModel: viewModel)
                .presentationDetents([.height(ApiIntegrationEditSheet.compactHeight), .medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var settingsAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.18)
    }
}

private enum ApiIntegrationLayout {
    static let iconContainerSize: CGFloat = 32
    static let flomoIconWidth: CGFloat = 28
    static let flomoIconHeight: CGFloat = 22
    static let writeathonIconSize: CGFloat = 23
    static let inboxIconSize: CGFloat = 21
    static let rowDividerLeadingInset: CGFloat = iconContainerSize + Spacing.base
}

private struct ApiIntegrationAppRow: View {
    let destination: ExternalAppDestination
    let isConfigured: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                ApiIntegrationAppIcon(destination: destination)

                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(destination.presentationTitle)
                        .font(AppTypography.subheadlineMedium)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                    Text(destination.rowSubtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Spacing.base)

                HStack(spacing: Spacing.half) {
                    Text(destination.statusTitle(isConfigured: isConfigured))
                        .font(AppTypography.subheadline)
                        .foregroundStyle(isConfigured ? Color.feedbackSuccess : Color.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Image(systemName: "chevron.right")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.textHint)
                }
            }
            .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(destination.presentationTitle)，\(destination.statusTitle(isConfigured: isConfigured))")
        .accessibilityHint("打开配置")
    }
}

private struct ApiIntegrationAppIcon: View {
    let destination: ExternalAppDestination

    var body: some View {
        ZStack {
            if destination.usesIconContainer {
                RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    .fill(Color.surfaceNested)
            }

            iconImage
        }
        .frame(width: ApiIntegrationLayout.iconContainerSize, height: ApiIntegrationLayout.iconContainerSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var iconImage: some View {
        if destination.usesTemplateIcon {
            Image(destination.iconAssetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.iconSecondary)
                .frame(width: destination.iconVisualSize, height: destination.iconVisualSize)
        } else {
            Image(destination.iconAssetName)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: destination.iconWidth, height: destination.iconHeight)
        }
    }
}

extension ExternalAppDestination {
    var presentationTitle: String {
        switch self {
        case .flomo:
            return "Flomo"
        case .writeathon:
            return "Writeathon"
        case .inbox:
            return "Inbox"
        }
    }

    var rowSubtitle: String {
        switch self {
        case .flomo:
            return "发送书摘到 flomo"
        case .writeathon:
            return "同步书摘到 Writeathon"
        case .inbox:
            return "发送书摘到 inBox 接收箱"
        }
    }

    var sheetSubtitle: String {
        switch self {
        case .flomo:
            return "Incoming Webhook"
        case .writeathon:
            return "个人访问 Token"
        case .inbox:
            return "接收内容的 API 地址"
        }
    }

    var iconAssetName: String {
        switch self {
        case .flomo:
            return "IntegrationFlomo"
        case .writeathon:
            return "IntegrationWriteathon"
        case .inbox:
            return "IntegrationInbox"
        }
    }

    var usesTemplateIcon: Bool {
        self == .inbox
    }

    var usesIconContainer: Bool {
        self == .writeathon || self == .inbox
    }

    var iconWidth: CGFloat {
        switch self {
        case .flomo:
            return ApiIntegrationLayout.flomoIconWidth
        case .writeathon:
            return ApiIntegrationLayout.writeathonIconSize
        case .inbox:
            return ApiIntegrationLayout.inboxIconSize
        }
    }

    var iconHeight: CGFloat {
        switch self {
        case .flomo:
            return ApiIntegrationLayout.flomoIconHeight
        case .writeathon:
            return ApiIntegrationLayout.writeathonIconSize
        case .inbox:
            return ApiIntegrationLayout.inboxIconSize
        }
    }

    var iconVisualSize: CGFloat {
        switch self {
        case .flomo:
            return ApiIntegrationLayout.flomoIconWidth
        case .writeathon:
            return ApiIntegrationLayout.writeathonIconSize
        case .inbox:
            return ApiIntegrationLayout.inboxIconSize
        }
    }

    func statusTitle(isConfigured: Bool) -> String {
        guard isConfigured else { return "未配置" }
        switch self {
        case .flomo:
            return "Webhook 已配置"
        case .writeathon:
            return "Token 已保存"
        case .inbox:
            return "API 地址已配置"
        }
    }
}
