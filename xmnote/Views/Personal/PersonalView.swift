//
//  PersonalView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

import SwiftUI

struct PersonalView: View {
    @Environment(AppState.self) private var appState
    let onAddBook: () -> Void
    let onAddNote: () -> Void

    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {}
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.windowBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: Spacing.base) {
                    premiumSection
                    readingSection
                    dataSection
                    managementSection
                    supportSection
                    aboutSection
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.base)
            }

            HomeTopHeaderGradient()
                .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            TopSwitcher(title: "我的") {
                NavigationLink(value: PersonalRoute.settings) {
                    TopBarActionIcon(systemName: "gearshape")
                }
                .topBarGlassButtonStyle(true)

                AddMenuCircleButton(
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    usesGlassStyle: true
                )
            }
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
            NavigationLink(value: PersonalRoute.premium) {
                HStack(spacing: Spacing.base) {
                    Image(systemName: "crown.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开通会员")
                            .font(.headline)
                        Text("解锁全部高级功能")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(Spacing.contentEdge)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.contentBackground)
            .clipShape(RoundedRectangle(cornerRadius: CornerRadius.card))
            .overlay(
                RoundedRectangle(cornerRadius: CornerRadius.card)
                    .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
            )
        }
    }

    // MARK: - 阅读

    private var readingSection: some View {
        cardGroup("阅读") {
            settingsRow("calendar", "阅读日历", route: .readCalendar)
            settingsRow("bell", "阅读提醒", route: .readReminder, isLast: true)
        }
    }

    // MARK: - 数据

    private var dataSection: some View {
        cardGroup("数据") {
            settingsRow("square.and.arrow.down", "数据导入", route: .dataImport)
            settingsRow("externaldrive", "数据备份", route: .dataBackup)
            settingsRow("square.and.arrow.up.on.square", "批量导出", route: .batchExport)
            settingsRow("link", "API 集成", route: .apiIntegration,
                        isLast: !(appState.isAIEnabled && appState.isPremium))
            if appState.isAIEnabled && appState.isPremium {
                settingsRow("brain", "AI 配置", route: .aiConfiguration, isLast: true)
            }
        }
    }

    // MARK: - 管理

    private var managementSection: some View {
        cardGroup("管理") {
            settingsRow("tag", "标签管理", route: .tagManagement)
            settingsRow("folder", "书籍分组", route: .groupManagement)
            settingsRow("building.columns", "书籍来源", route: .bookSource)
            settingsRow("person.text.rectangle", "作者管理", route: .authorManagement)
            settingsRow("building.2", "出版社管理", route: .pressManagement, isLast: true)
        }
    }

    // MARK: - 支持

    private var supportSection: some View {
        cardGroup("支持") {
            actionRow("questionmark.circle", "帮助文档") {
                // TODO: 打开帮助文档
            }
            actionRow("envelope", "反馈", isLast: true) {
                // TODO: 发送反馈邮件
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        cardGroup("关于") {
            NavigationLink(value: PersonalRoute.about) {
                HStack {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(Color.brand)
                        .frame(width: 24)
                    Text("关于应用")
                    Spacer()
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(version)"
    }
}

// MARK: - Helpers

extension PersonalView {

    private func cardGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, Spacing.half)

            CardContainer {
                VStack(spacing: 0) {
                    content()
                }
            }
        }
    }

    private func settingsRow(
        _ icon: String,
        _ title: String,
        route: PersonalRoute,
        isLast: Bool = false
    ) -> some View {
        VStack(spacing: 0) {
            NavigationLink(value: route) {
                HStack {
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(Color.brand)
                        .frame(width: 24)
                    Text(title)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLast {
                Divider()
                    .padding(.leading, Spacing.contentEdge + 24 + Spacing.base)
            }
        }
    }

    private func actionRow(
        _ icon: String,
        _ title: String,
        isLast: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack {
                    Image(systemName: icon)
                        .font(.body)
                        .foregroundStyle(Color.brand)
                        .frame(width: 24)
                    Text(title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, Spacing.contentEdge)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLast {
                Divider()
                    .padding(.leading, Spacing.contentEdge + 24 + Spacing.base)
            }
        }
    }
}

#Preview {
    NavigationStack {
        PersonalView()
            .environment(AppState())
    }
}
