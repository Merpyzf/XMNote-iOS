/**
 * [INPUT]: 依赖 BookPickerScope、BookPickerVisibleScope 与 BookSearchSource 表达可切换来源，依赖 SwiftUI Menu、XMMenuLabel 和 Liquid Glass 提供系统交互与材质
 * [OUTPUT]: 对 BookPicker Apple 推荐分支提供按配置显隐、以当前具体来源命名的单一玻璃 Menu-chip
 * [POS]: Book 模块页面私有来源入口，仅服务仍在 Debug 验证中的 Apple 推荐选书样式
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 将本地与在线来源收口为一个系统菜单，避免为不可切换场景常驻展示同权范围控件。
struct BookPickerAppleSourceMenu: View {
    let scope: BookPickerScope
    let visibleScope: BookPickerVisibleScope
    let selectedOnlineSource: BookSearchSource
    let onlineSources: [BookSearchSource]
    let onSelectLocal: () -> Void
    let onSelectOnlineSource: (BookSearchSource) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .subheadline) private var visualHeight = Layout.visualHeight

    var body: some View {
        Menu {
            if scope == .both {
                Button(action: onSelectLocal) {
                    XMMenuLabel(
                        "本地书架",
                        systemImage: visibleScope == .local ? "checkmark" : "books.vertical",
                        isSelected: visibleScope == .local
                    )
                }
            }

            Section("在线来源") {
                ForEach(onlineSources, id: \.self) { source in
                    Button {
                        onSelectOnlineSource(source)
                    } label: {
                        XMMenuLabel(
                            source.title,
                            systemImage: visibleScope == .online && selectedOnlineSource == source
                                ? "checkmark"
                                : nil,
                            isSelected: visibleScope == .online && selectedOnlineSource == source
                        )
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.compact) {
                Text(currentTitle)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(AppTypography.captionSemibold)
                    .foregroundStyle(Color.iconSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.base)
            .frame(minHeight: visualHeight)
            .contentShape(Capsule())
            .glassEffect(.clear.interactive(isEnabled), in: .capsule)
        }
        .menuOrder(.fixed)
        .xmMenuNeutralTint()
        .xmMinimumHitTarget(anchor: .leading)
        .accessibilityLabel("书籍来源")
        .accessibilityValue(currentTitle)
        .accessibilityHint("双击切换本地书架或在线来源")
        .accessibilityIdentifier("book.picker.source-menu")
    }

    private var currentTitle: String {
        switch visibleScope {
        case .local:
            return "本地"
        case .online:
            return selectedOnlineSource.title
        }
    }

    private enum Layout {
        static let visualHeight: CGFloat = 36
    }
}
