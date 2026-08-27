//
//  PersonalView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

/**
 * [INPUT]: 依赖 AppState、DesktopWebSessionCoordinator、AppNavigationCoordinator、XMSettingsGroup、PersonalRoute、DebugRoute 与阅读日历根级呈现回调
 * [OUTPUT]: 对外提供 PersonalView，以 17/15pt 设置行层级与页面私有 SF Symbols 光学校准承载我的 Tab 核心入口、阅读日历独立入口、网页端入口状态与新增优先顶部更多菜单
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

        var systemName: String {
            switch self {
            case .readCalendar:
                "calendar"
            case .readReminder:
                "bell"
            case .desktopWeb:
                "display"
            case .dataImport:
                "square.and.arrow.down"
            case .dataBackup:
                "externaldrive"
            case .batchExport:
                "square.and.arrow.up"
            case .apiIntegration:
                "link"
            case .aiConfiguration:
                "sparkles"
            case .tagManagement:
                "tag"
            case .groupManagement:
                "folder"
            case .bookSource:
                "books.vertical"
            case .authorManagement:
                "person.2"
            case .pressManagement:
                "building.2"
            case .helpDocumentation:
                "questionmark.circle"
            case .feedback:
                "envelope"
            case .about:
                "info.circle"
            case .debugCenter:
                "hammer"
            }
        }

        var visualScale: CGFloat {
            switch self {
            case .desktopWeb, .dataBackup, .bookSource, .pressManagement:
                0.88
            case .apiIntegration, .aiConfiguration, .tagManagement, .authorManagement:
                0.94
            case .readCalendar,
                 .readReminder,
                 .dataImport,
                 .batchExport,
                 .groupManagement,
                 .helpDocumentation,
                 .feedback,
                 .about,
                 .debugCenter:
                1
            }
        }
    }

    private enum Layout {
        static let panelSpacing: CGFloat = Spacing.comfortable
        static let panelEdgeVerticalInset: CGFloat = Spacing.half
        static let settingsRowIconCanvas: CGFloat = 24
        static let rowMinHeight: CGFloat = InteractionMetrics.minimumTouchTarget
        static let rowDividerLeading: CGFloat = Spacing.contentEdge + settingsRowIconCanvas + Spacing.base
        static let topBarTrailingIconSize: CGFloat = 15
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
                    readingAndDataSection
                    managementSection
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
                    Menu {
                        Button {
                            navigationCoordinator.push(.personal(.settings), in: .profile)
                        } label: {
                            XMMenuLabel("设置", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        TopBarActionIcon(
                            systemName: "ellipsis",
                            iconSize: Layout.topBarTrailingIconSize,
                            foregroundColor: Color.iconPrimary.opacity(0.88),
                            hitShape: .rectangle
                        )
                    }
                    .topBarActionPillSegmentStyle(true)
                    .xmMenuNeutralTint()
                    .menuOrder(.fixed)
                    .accessibilityLabel("我的更多操作")
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
                    HStack(spacing: Spacing.base) {
                        Image(systemName: "crown.fill")
                            .font(AppTypography.title3Semibold)
                            .foregroundStyle(Color.feedbackWarning)
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text("开通会员")
                                .font(AppTypography.headlineSemibold)
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

    // MARK: - 阅读与数据

    private var readingAndDataSection: some View {
        groupedPanel {
            actionRow(.readCalendar, "阅读日历", action: onOpenReadCalendar)
            settingsRow(.readReminder, "阅读提醒", route: .readReminder)
            settingsRow(
                .desktopWeb,
                "网页端",
                route: .desktopWeb,
                trailingText: desktopWebStatusText,
                trailingColor: .feedbackSuccess,
                isLast: true
            )
            .animation(.smooth, value: desktopWebSessionCoordinator.state.isRunning)
            PersonalSettingsDivider(leadingInset: Layout.rowDividerLeading)
            settingsRow(.dataImport, "书摘导入", route: .dataImport)
            settingsRow(.dataBackup, "数据备份", route: .dataBackup)
            settingsRow(.batchExport, "批量导出", route: .batchExport)
            settingsRow(.apiIntegration, "API 集成", route: .apiIntegration)
            settingsRow(.aiConfiguration, "AI 配置", route: .aiConfiguration, isLast: true)
        }
    }

    // MARK: - 管理

    private var managementSection: some View {
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
            actionRow(.helpDocumentation, "帮助文档") {
                // TODO: 打开帮助文档
            }
            actionRow(.feedback, "反馈") {
                // TODO: 发送反馈邮件
            }
            settingsRow(
                .about,
                "关于应用",
                route: .about,
                trailingText: appVersion,
                isLast: !hasDebugSection
            )
            debugCenterRow()
        }
    }

    private var shouldShowAIConfiguration: Bool {
        appState.isAIEnabled && appState.isPremium
    }

    private var desktopWebStatusText: String? {
        desktopWebSessionCoordinator.state.isRunning ? "运行中" : nil
    }

    private var hasDebugSection: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }
}

// MARK: - Helpers

extension PersonalView {

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
        NavigationLink(value: AppRoute.debug(.debugCenter)) {
            rowContent(icon: .debugCenter, title: "测试中心")
        }
        .buttonStyle(.plain)
#endif
    }

    private func rowContent(
        icon: PersonalEntryIcon,
        title: String,
        trailingText: String? = nil,
        trailingColor: Color = .textSecondary
    ) -> some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: icon.systemName)
                .font(AppTypography.body)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.iconSecondary)
                .scaleEffect(icon.visualScale)
                .frame(
                    width: Layout.settingsRowIconCanvas,
                    height: Layout.settingsRowIconCanvas
                )
                .accessibilityHidden(true)

            Text(title)
                .font(SettingsTypography.rowTitle)
                .foregroundStyle(Color.textPrimary)

            Spacer(minLength: Spacing.base)

            if let trailingText {
                Text(trailingText)
                    .font(SettingsTypography.rowValue)
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
