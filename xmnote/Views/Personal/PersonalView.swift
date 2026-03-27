//
//  PersonalView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

/**
 * [INPUT]: 依赖 AppState 环境状态，依赖 PersonalRoute 导航路由
 * [OUTPUT]: 对外提供 PersonalView，我的 Tab 核心入口
 * [POS]: Personal 模块容器壳层，承载设置列表与备份入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 个人中心首页，汇总设置、备份、阅读偏好与支持入口。
struct PersonalView: View {
    /// Layout 负责当前场景的enum定义，明确职责边界并组织相关能力。
    private enum Layout {
        static let panelCornerRadius: CGFloat = CornerRadius.containerMedium
        static let panelSpacing: CGFloat = Spacing.comfortable
        static let panelEdgeVerticalInset: CGFloat = Spacing.half
        static let settingsRowIconWidth: CGFloat = 24
        static let rowMinHeight: CGFloat = 44
        static let rowDividerLeading: CGFloat = Spacing.contentEdge + settingsRowIconWidth + Spacing.base
    }

    @Environment(AppState.self) private var appState
    private let topBarHeight: CGFloat = 56
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?

    /// 注入新增书籍回调，连接个人页快捷操作入口。
    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {},
        onOpenDebugCenter: (() -> Void)? = nil
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenDebugCenter = onOpenDebugCenter
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
            .padding(.top, topBarHeight)

            HomeTopHeaderGradient()
                .allowsHitTesting(false)

            TopSwitcher(title: "我的") {
                NavigationLink(value: PersonalRoute.settings) {
                    TopBarActionIcon(systemName: "gearshape", containerSize: 36)
                }
                .topBarGlassButtonStyle(true)

                AddMenuCircleButton(
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    onOpenDebugCenter: onOpenDebugCenter,
                    usesGlassStyle: true
                )
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
            PersonalSettingsPanel(cornerRadius: Layout.panelCornerRadius) {
                NavigationLink(value: PersonalRoute.premium) {
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
            settingsRow("calendar", "阅读日历", route: .readCalendar)
            settingsRow("bell", "阅读提醒", route: .readReminder)
            PersonalSettingsDivider(leadingInset: Layout.rowDividerLeading)
            settingsRow("square.and.arrow.down", "数据导入", route: .dataImport)
            settingsRow("externaldrive", "数据备份", route: .dataBackup)
            settingsRow("square.and.arrow.up.on.square", "批量导出", route: .batchExport)
            settingsRow("link", "API 集成", route: .apiIntegration,
                        isLast: !shouldShowAIConfiguration)
            if shouldShowAIConfiguration {
                settingsRow("brain", "AI 配置", route: .aiConfiguration, isLast: true)
            }
        }
    }

    // MARK: - 管理

    private var managementSection: some View {
        groupedPanel {
            settingsRow("tag", "标签管理", route: .tagManagement)
            settingsRow("folder", "书籍分组", route: .groupManagement)
            settingsRow("building.columns", "书籍来源", route: .bookSource)
            settingsRow("person.text.rectangle", "作者管理", route: .authorManagement)
            settingsRow("building.2", "出版社管理", route: .pressManagement, isLast: true)
        }
    }

    // MARK: - 支持与关于

    private var supportAndAboutSection: some View {
        groupedPanel {
            actionRow("questionmark.circle", "帮助文档") {
                // TODO: 打开帮助文档
            }
            actionRow("envelope", "反馈") {
                // TODO: 发送反馈邮件
            }
            settingsRow(
                "info.circle",
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

    /// 封装groupedPanel对应的业务步骤，确保调用方可以稳定复用该能力。
    private func groupedPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        PersonalSettingsPanel(cornerRadius: Layout.panelCornerRadius) {
            VStack(spacing: Spacing.none) {
                content()
            }
            .padding(.vertical, Layout.panelEdgeVerticalInset)
        }
    }

    /// 封装settingsRow对应的业务步骤，确保调用方可以稳定复用该能力。
    private func settingsRow(
        _ icon: String,
        _ title: String,
        route: PersonalRoute,
        trailingText: String? = nil,
        isLast: Bool = false
    ) -> some View {
        VStack(spacing: Spacing.none) {
            NavigationLink(value: route) {
                rowContent(icon: icon, title: title, trailingText: trailingText)
            }
            .buttonStyle(.plain)

            if !isLast {
                PersonalSettingsDivider(leadingInset: Layout.rowDividerLeading)
            }
        }
    }

    /// 封装actionRow对应的业务步骤，确保调用方可以稳定复用该能力。
    private func actionRow(
        _ icon: String,
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
    /// 封装debugCenterRow对应的业务步骤，确保调用方可以稳定复用该能力。
    private func debugCenterRow() -> some View {
#if DEBUG
        NavigationLink(destination: DebugCenterView()) {
            rowContent(icon: "hammer", title: "测试中心")
        }
        .buttonStyle(.plain)
#endif
    }

    /// 组装rowContent对应的界面片段，保持页面层级与信息结构清晰。
    private func rowContent(
        icon: String,
        title: String,
        trailingText: String? = nil
    ) -> some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: icon)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .frame(width: Layout.settingsRowIconWidth)

            Text(title)
                .font(AppTypography.subheadlineMedium)
                .foregroundStyle(Color.textPrimary)

            Spacer(minLength: Spacing.base)

            if let trailingText {
                Text(trailingText)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
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

/// PersonalSettingsPanel 负责当前场景的struct定义，明确职责边界并组织相关能力。
private struct PersonalSettingsPanel<Content: View>: View {
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

/// PersonalSettingsDivider 负责当前场景的struct定义，明确职责边界并组织相关能力。
private struct PersonalSettingsDivider: View {
    let leadingInset: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.surfaceBorderSubtle.opacity(0.42))
            .frame(height: CardStyle.borderWidth)
            .padding(.leading, leadingInset)
    }
}

#Preview {
    NavigationStack {
        PersonalView()
            .environment(AppState())
    }
}
