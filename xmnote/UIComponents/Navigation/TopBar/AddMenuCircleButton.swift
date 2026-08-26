/**
 * [INPUT]: 依赖 xmnote/Utilities/DesignSystem/SemanticColors.swift 的语义色令牌，依赖 XMMenuLabel 与顶部 action 展示样式扩展
 * [OUTPUT]: 对外提供 AddMenuCircleButton 顶部添加菜单组件
 * [POS]: UIComponents/Navigation/TopBar 的业务操作入口组件，被主页面顶部导航栏复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 统一 `+` 菜单按钮，静止态使用中性顶部工具图标，按压时由顶部 action 样式提供反馈。
struct AddMenuCircleButton: View {
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?
    /// 兼容旧玻璃样式调用参数，当前视觉统一由 topBarActionButtonStyle 承接。
    let usesGlassStyle: Bool
    let presentation: TopBarActionPresentation
    let iconSize: CGFloat

    /// 注入新增书籍/笔记操作回调，配置顶部加号入口行为。
    init(
        onAddBook: @escaping () -> Void,
        onAddNote: @escaping () -> Void,
        onOpenDebugCenter: (() -> Void)? = nil,
        usesGlassStyle: Bool = false,
        presentation: TopBarActionPresentation = .standalone,
        iconSize: CGFloat = 14
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenDebugCenter = onOpenDebugCenter
        self.usesGlassStyle = usesGlassStyle
        self.presentation = presentation
        self.iconSize = iconSize
    }

    var body: some View {
        Menu {
            Button(action: onAddBook) {
                XMMenuLabel("添加书籍", systemImage: "book.badge.plus")
            }
            Button(action: onAddNote) {
                XMMenuLabel("添加书摘", systemImage: "square.and.pencil")
            }
            #if DEBUG
            if let onOpenDebugCenter {
                Divider()
                Button {
                    onOpenDebugCenter()
                } label: {
                    XMMenuLabel("测试中心", systemImage: "hammer")
                }
            }
            #endif
        } label: {
            TopBarActionIcon(
                systemName: "plus",
                iconSize: iconSize,
                weight: .medium,
                foregroundColor: Color.iconPrimary.opacity(0.88),
                hitShape: presentation == .pillSegment ? .rectangle : .circle
            )
        }
        .xmMenuNeutralTint()
        .topBarActionPresentationStyle(presentation)
        .accessibilityLabel("添加")
    }
}
