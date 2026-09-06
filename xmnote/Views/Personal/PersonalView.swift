//
//  PersonalView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

/**
 * [INPUT]: 依赖 AppState、DesktopWebSessionCoordinator、AppNavigationCoordinator、XMSettingsGroup、字体许可资源、PersonalRoute、DebugRoute 与阅读日历根级呈现回调
 * [OUTPUT]: 对外提供 PersonalView 与 AboutAppView，承载我的 Tab 核心入口、网页端状态、设置操作及思源宋体开源许可查看
 * [POS]: Personal 模块容器壳层，承载设置列表、网页端与备份入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 个人中心首页，汇总设置、备份、阅读偏好与支持入口。
struct PersonalView: View {
    /// “我的”入口图标语义映射；仅在本页统一功能隐喻与光学重量，不扩大全局组件边界。
    private enum PersonalEntryIcon {
        case readCalendar
        case readReminder
        case desktopWeb
        case dataImport
        case dataBackup
        case batchExport
        case apiIntegration
        case aiConfiguration
        case tagManagement
        case groupManagement
        case bookSource
        case authorManagement
        case pressManagement
        case helpDocumentation
        case feedback
        case about
        case debugCenter

        /// 返回“我的”页固定使用的线性 Reicon 资源。
        var resource: ImageResource {
            switch self {
            case .readCalendar:
                .reiconCalendarCheckOutline
            case .readReminder:
                .reiconBellOutline
            case .desktopWeb:
                .reiconDesktopOutline
            case .dataImport:
                .reiconInboxInOutline
            case .dataBackup:
                .reiconCloudOutline
            case .batchExport:
                .reiconFileDownloadOutline
            case .apiIntegration:
                .reiconPuzzlePieceOutline
            case .aiConfiguration:
                .reiconSparklesOutline
            case .tagManagement:
                .reiconTag5Outline
            case .groupManagement:
                .reiconFolderOutline
            case .bookSource:
                .reiconCompassOutline
            case .authorManagement:
                .reiconUsersOutline
            case .pressManagement:
                .reiconBuildingOutline
            case .helpDocumentation:
                .reiconHelpCircleOutline
            case .feedback:
                .reiconMessageDotsOutline
            case .about:
                .reiconInfoCircleOutline
            case .debugCenter:
                .reiconFlaskOutline
            }
        }
    }

    private enum Layout {
        static let panelSpacing: CGFloat = Spacing.comfortable
        static let panelEdgeVerticalInset: CGFloat = Spacing.half
        static let settingsRowIconCanvas: CGFloat = 24
        static let settingsRowIconSize: CGFloat = 16
        static let premiumIconSize: CGFloat = 30
        static let shortcutIconSize: CGFloat = 18
        static let shortcutIconCanvas: CGFloat = 24
        static let shortcutMinHeight: CGFloat = 64
        static let rowMinHeight: CGFloat = InteractionMetrics.minimumTouchTarget
        static let rowDividerLeading: CGFloat = Spacing.contentEdge + settingsRowIconCanvas + Spacing.tight
        static let topBarTrailingIconSize: CGFloat = 18
    }

    @Environment(AppState.self) private var appState
    @Environment(DesktopWebSessionCoordinator.self) private var desktopWebSessionCoordinator
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenReadCalendar: () -> Void

    /// 注入新增书籍、笔记与阅读日历回调，连接个人页跨层级动作。
    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {},
        onOpenReadCalendar: @escaping () -> Void = {}
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenReadCalendar = onOpenReadCalendar
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Layout.panelSpacing) {
                    premiumSection
                    shortcutsSection
                    toolsSection
                    libraryManagementSection
                    supportAndAboutSection
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
            }
            .padding(.top, PrimaryTopBarLayout.minimumHeight(for: dynamicTypeSize))

            HomeTopHeaderGradient()
                .allowsHitTesting(false)

            TopSwitcher(title: "我的") {
                TopBarActionPill {
                    AddMenuCircleButton(
                        onAddBook: onAddBook,
                        onAddNote: onAddNote,
                        usesGlassStyle: true,
                        presentation: .pillSegment
                    )
                } trailing: {
                    Button {
                        navigationCoordinator.push(.personal(.settings), in: .profile)
                    } label: {
                        Image(.reiconSettings4Outline)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(
                                width: Layout.topBarTrailingIconSize,
                                height: Layout.topBarTrailingIconSize
                            )
                            .foregroundStyle(Color.iconPrimary.opacity(0.88))
                            .frame(
                                width: InteractionMetrics.minimumTouchTarget,
                                height: InteractionMetrics.minimumTouchTarget
                            )
                            .contentShape(Rectangle())
                    }
                    .topBarActionPillSegmentStyle(true)
                    .accessibilityLabel("设置")
                }
            }
            .zIndex(1)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

// MARK: - Sections

extension PersonalView {

    // MARK: - Premium

    @ViewBuilder
    private var premiumSection: some View {
        if !appState.isPremium {
            XMSettingsGroup(
                horizontalPadding: Spacing.none,
                verticalPadding: Spacing.none
            ) {
                NavigationLink(value: AppRoute.personal(.premium)) {
                    HStack(spacing: Spacing.tight) {
                        Image(.reiconCrownFilled)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: Layout.premiumIconSize, height: Layout.premiumIconSize)
                            .foregroundStyle(Color.feedbackWarning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text("开通会员")
                                .font(AppTypography.callout)
                                .foregroundStyle(Color.textPrimary)
                            Text("解锁全部高级功能")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(AppTypography.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, Spacing.contentEdge)
                    .padding(.vertical, Spacing.base)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 常用功能

    private var shortcutsSection: some View {
        XMSettingsGroup(
            horizontalPadding: Spacing.none,
            verticalPadding: Spacing.none
        ) {
            LazyVGrid(
                columns: shortcutColumns,
                alignment: .center,
                spacing: Spacing.none
            ) {
                shortcutAction(.readCalendar, "阅读日历", action: onOpenReadCalendar)
                shortcutNavigation(
                    .desktopWeb,
                    "网页端",
                    route: .desktopWeb,
                    statusText: desktopWebStatusText,
                    statusColor: .feedbackSuccess
                )
                .animation(.smooth, value: desktopWebSessionCoordinator.state.isRunning)
                shortcutNavigation(.dataImport, "书摘导入", route: .dataImport)
                shortcutNavigation(.dataBackup, "数据备份", route: .dataBackup)
            }
            .padding(.vertical, Spacing.compact)
        }
    }

    // MARK: - 工具

    private var toolsSection: some View {
        groupedPanel {
            settingsRow(.readReminder, "阅读提醒", route: .readReminder)
            settingsRow(.batchExport, "笔记导出", route: .batchExport)
            settingsRow(.apiIntegration, "应用关联", route: .apiIntegration)
            settingsRow(.aiConfiguration, "AI 助手", route: .aiConfiguration, isLast: true)
        }
    }

    // MARK: - 书库管理

    private var libraryManagementSection: some View {
        groupedPanel {
            settingsRow(.tagManagement, "标签管理", route: .tagManagement)
            settingsRow(.groupManagement, "书籍分组", route: .groupManagement)
            settingsRow(.bookSource, "书籍来源", route: .bookSource)
            settingsRow(.authorManagement, "作者管理", route: .authorManagement)
            settingsRow(.pressManagement, "出版社管理", route: .pressManagement, isLast: true)
        }
    }

    // MARK: - 支持与关于

    private var supportAndAboutSection: some View {
        groupedPanel {
            debugCenterRow()
            actionRow(.helpDocumentation, "帮助文档") {
                // TODO: 打开帮助文档
            }
            actionRow(.feedback, "问题反馈") {
                // TODO: 发送反馈邮件
            }
            settingsRow(
                .about,
                "关于应用",
                route: .about,
                trailingText: appVersion,
                isLast: true
            )
        }
    }

    private var shouldShowAIConfiguration: Bool {
        appState.isAIEnabled && appState.isPremium
    }

    private var desktopWebStatusText: String? {
        desktopWebSessionCoordinator.state.isRunning ? "运行中" : nil
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }
}

// MARK: - Helpers

extension PersonalView {

    private var shortcutColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Spacing.none),
            count: dynamicTypeSize.isAccessibilitySize ? 2 : 4
        )
    }

    private func groupedPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        XMSettingsGroup(
            horizontalPadding: Spacing.none,
            verticalPadding: Spacing.none
        ) {
            VStack(spacing: Spacing.none) {
                content()
            }
            .padding(.vertical, Layout.panelEdgeVerticalInset)
        }
    }

    private func shortcutNavigation(
        _ icon: PersonalEntryIcon,
        _ title: String,
        route: PersonalRoute,
        statusText: String? = nil,
        statusColor: Color = .textSecondary
    ) -> some View {
        NavigationLink(value: AppRoute.personal(route)) {
            shortcutContent(
                icon: icon,
                title: title,
                statusText: statusText,
                statusColor: statusColor
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(statusText ?? "")
    }

    private func shortcutAction(
        _ icon: PersonalEntryIcon,
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            shortcutContent(icon: icon, title: title)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func shortcutContent(
        icon: PersonalEntryIcon,
        title: String,
        statusText: String? = nil,
        statusColor: Color = .textSecondary
    ) -> some View {
        VStack(spacing: Spacing.half) {
            Image(icon.resource)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.textPrimary)
                .frame(width: Layout.shortcutIconSize, height: Layout.shortcutIconSize)
                .frame(width: Layout.shortcutIconCanvas, height: Layout.shortcutIconCanvas)
                .accessibilityHidden(true)

            HStack(spacing: Spacing.compact) {
                Text(title)
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textPrimary)

                if let statusText {
                    ViewThatFits(in: .horizontal) {
                        Text(statusText)
                            .font(AppTypography.caption2)
                            .foregroundStyle(statusColor)
                            .lineLimit(1)

                        Circle()
                            .fill(statusColor)
                            .frame(width: Spacing.half, height: Spacing.half)
                    }
                    .accessibilityHidden(true)
                }
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.compact)
        .frame(maxWidth: .infinity)
        .frame(minHeight: Layout.shortcutMinHeight)
        .contentShape(Rectangle())
    }

    private func settingsRow(
        _ icon: PersonalEntryIcon,
        _ title: String,
        route: PersonalRoute,
        trailingText: String? = nil,
        trailingColor: Color = .textSecondary,
        isLast: Bool = false
    ) -> some View {
        VStack(spacing: Spacing.none) {
            NavigationLink(value: AppRoute.personal(route)) {
                rowContent(
                    icon: icon,
                    title: title,
                    trailingText: trailingText,
                    trailingColor: trailingColor
                )
            }
            .buttonStyle(.plain)

            if !isLast {
                PersonalSettingsDivider(leadingInset: Layout.rowDividerLeading)
            }
        }
    }

    private func actionRow(
        _ icon: PersonalEntryIcon,
        _ title: String,
        isLast: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: Spacing.none) {
            Button(action: action) {
                rowContent(icon: icon, title: title)
            }
            .buttonStyle(.plain)

            if !isLast {
                PersonalSettingsDivider(leadingInset: Layout.rowDividerLeading)
            }
        }
    }

    @ViewBuilder
    private func debugCenterRow() -> some View {
#if DEBUG
        VStack(spacing: Spacing.none) {
            NavigationLink(value: AppRoute.debug(.debugCenter)) {
                rowContent(icon: .debugCenter, title: "测试中心")
            }
            .buttonStyle(.plain)

            PersonalSettingsDivider(leadingInset: Layout.rowDividerLeading)
        }
#endif
    }

    private func rowContent(
        icon: PersonalEntryIcon,
        title: String,
        trailingText: String? = nil,
        trailingColor: Color = .textSecondary
    ) -> some View {
        HStack(spacing: Spacing.tight) {
            Image(icon.resource)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.textPrimary)
                .frame(width: Layout.settingsRowIconSize, height: Layout.settingsRowIconSize)
                .frame(
                    width: Layout.settingsRowIconCanvas,
                    height: Layout.settingsRowIconCanvas
                )
                .accessibilityHidden(true)

            Text(title)
                .font(AppTypography.callout)
                .foregroundStyle(Color.textPrimary)

            Spacer(minLength: Spacing.base)

            if let trailingText {
                Text(trailingText)
                    .font(AppTypography.footnote)
                    .foregroundStyle(trailingColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .transition(.opacity)
            }

            Image(systemName: "chevron.right")
                .font(AppTypography.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.contentEdge)
        .frame(minHeight: Layout.rowMinHeight)
        .contentShape(Rectangle())
    }
}

/// 关于应用页提供版本信息和随包分发字体的完整版权许可，避免资源内嵌后缺少用户可达的法律文本。
struct AboutAppView: View {
    var body: some View {
        XMSettingsPage {
            XMSettingsSection("应用") {
                XMSettingsGroup(presentation: .singleItem) {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text("纸间书摘")
                            .font(SettingsTypography.rowTitle)
                            .foregroundStyle(Color.textPrimary)

                        Text("版本 \(Self.appVersion)")
                            .font(SettingsTypography.rowDescription)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
                }
            }

            XMSettingsSection("开源许可") {
                XMSettingsGroup {
                    DisclosureGroup {
                        Text(verbatim: Self.sourceHanSerifLicense)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .textSelection(.enabled)
                            .padding(.top, Spacing.base)
                    } label: {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text(verbatim: "Source Han Serif SC")
                                .font(SettingsTypography.rowTitle)
                                .foregroundStyle(Color.textPrimary)

                            Text(verbatim: "SIL Open Font License 1.1")
                                .font(SettingsTypography.rowDescription)
                                .foregroundStyle(Color.textSecondary)
                        }
                        .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
                    }
                    .tint(Color.textSecondary)
                }
            }
        }
        .navigationTitle("关于应用")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let appVersion: String = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "—"

    private static let sourceHanSerifLicense: String = {
        guard let url = Bundle.main.url(
            forResource: "SourceHanSerifSC-LICENSE",
            withExtension: "txt"
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Source Han Serif SC\nSIL Open Font License 1.1\n许可文本资源缺失。"
        }
        return text
    }()
}

private struct PersonalSettingsDivider: View {
    let leadingInset: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.surfaceBorderSubtle.opacity(0.42))
            .frame(height: StrokeWidth.hairline)
            .padding(.leading, leadingInset)
    }
}

#Preview {
    NavigationStack {
        PersonalView()
            .environment(AppState())
            .environment(DesktopWebSessionCoordinator())
    }
}
