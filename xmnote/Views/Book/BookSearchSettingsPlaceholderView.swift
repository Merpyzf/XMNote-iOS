/**
 * [INPUT]: 依赖 BookSearchViewModel 提供搜索设置状态与持久化写入，依赖 DesignTokens 提供页面样式
 * [OUTPUT]: 对外提供 BookSearchSettingsView，承接“添加书籍设置”入口的真实偏好配置页
 * [POS]: Book 模块的二级设置页面，用于配置默认搜索源、快捷切换和添加后返回书架偏好
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 添加书籍设置页，负责读写搜索来源与添加完成后的流程偏好。
struct BookSearchSettingsView: View {
    @Bindable var viewModel: BookSearchViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                sourceSection
                behaviorSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.screenEdge)
        }
        .background(Color.surfacePage)
        .navigationTitle("添加书籍设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sourceSection: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("默认搜索源")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Spacing.cozy)], spacing: Spacing.cozy) {
                    ForEach(BookSearchSource.allCases) { source in
                        Button {
                            viewModel.updateSelectedSource(source)
                        } label: {
                            Text(source.title)
                                .font(AppTypography.semantic(.footnote, weight: source == viewModel.searchSettings.defaultSource ? .semibold : .medium))
                                .foregroundStyle(source == viewModel.searchSettings.defaultSource ? .white : Color.textPrimary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(
                                    source == viewModel.searchSettings.defaultSource ? Color.brand : Color.surfaceNested,
                                    in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private var behaviorSection: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(spacing: Spacing.base) {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.searchSettings.isQuickSourceSwitchEnabled },
                        set: { viewModel.updateQuickSourceSwitch($0) }
                    )
                ) {
                    settingText(
                        title: "快捷切换搜索源",
                        subtitle: "在搜索页显示来源切换入口"
                    )
                }

                Divider()

                Toggle(
                    isOn: Binding(
                        get: { viewModel.searchSettings.shouldReturnToBookshelfAfterSave },
                        set: { viewModel.updateReturnToBookshelfAfterSave($0) }
                    )
                ) {
                    settingText(
                        title: "添加后返回书架",
                        subtitle: "保存新书后关闭添加流程"
                    )
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func settingText(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tiny) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }
}

#Preview {
    NavigationStack {
        BookSearchSettingsView(
            viewModel: BookSearchViewModel(
                repository: BookSearchRepository()
            )
        )
    }
}
