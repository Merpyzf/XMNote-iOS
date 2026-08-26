/**
 * [INPUT]: 依赖 BookshelfBookListChromeMetrics、InteractionMetrics、顶部按钮与书架管理模式动效
 * [OUTPUT]: 对外提供 BookshelfBookListBrowsingChrome，供二级书籍列表页组合普通态顶部 chrome
 * [POS]: Book 模块二级书籍列表页面私有 chrome 子视图，降低 BookshelfBookListView 文件职责密度
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 二级列表普通态本地顶部 chrome，承载返回、标题、显示设置与整理入口。
struct BookshelfBookListBrowsingChrome: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let canEnterEditing: Bool
    let topBarHeight: CGFloat
    let onBack: () -> Void
    let onShowDisplaySettings: () -> Void
    let onEnterEditing: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(AppTypography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, BookshelfBookListChromeMetrics.titleHorizontalInset)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            GlassEffectContainer(spacing: Spacing.double) {
                HStack(spacing: Spacing.cozy) {
                    TopBarBackButton(action: onBack, foregroundColor: Color.textPrimary)
                        .buttonStyle(.plain)
                        .frame(
                            width: InteractionMetrics.minimumTouchTarget,
                            height: InteractionMetrics.minimumTouchTarget
                        )
                        .contentShape(Circle())

                    Spacer(minLength: Spacing.compact)

                    actionCluster
                }
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(height: topBarHeight)
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
    }

    private var actionCluster: some View {
        HStack(spacing: Spacing.none) {
            Button(action: onShowDisplaySettings) {
                TopBarActionIcon(
                    systemName: "slider.horizontal.3",
                    foregroundColor: Color.iconPrimary
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("显示设置")

            Divider()
                .frame(height: Spacing.double)
                .overlay(Color.surfaceBorderSubtle.opacity(canEnterEditing ? 0.58 : 0.18))
                .animation(BookshelfManagementMotion.bookListTopActionAnimation(reduceMotion: reduceMotion), value: canEnterEditing)

            Button(action: onEnterEditing) {
                TopBarActionIcon(
                    systemName: "checklist",
                    foregroundColor: canEnterEditing ? Color.iconPrimary : Color.textHint
                )
            }
            .buttonStyle(.plain)
            .disabled(!canEnterEditing)
            .opacity(canEnterEditing ? 1 : 0.42)
            .scaleEffect(canEnterEditing ? 1 : 0.96)
            .animation(BookshelfManagementMotion.bookListTopActionAnimation(reduceMotion: reduceMotion), value: canEnterEditing)
            .accessibilityLabel(canEnterEditing ? "整理书籍" : "整理书籍，当前不可用")
            .accessibilityHint(canEnterEditing ? "进入书籍整理模式" : "当前没有可整理的书籍")
        }
        .topBarGlassCapsuleStyle(true)
    }
}
