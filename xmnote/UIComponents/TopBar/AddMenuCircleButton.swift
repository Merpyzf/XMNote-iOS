/**
 * [INPUT]: 依赖 xmnote/Utilities/DesignTokens.swift 的品牌色与边框令牌，依赖 topBarGlassButtonStyle 样式扩展
 * [OUTPUT]: 对外提供 AddMenuCircleButton 顶部添加菜单组件
 * [POS]: UIComponents/TopBar 的业务操作入口组件，被主页面顶部导航栏复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 统一 `+` 菜单按钮。glass 模式下通过 `.glassEffect(.regular.interactive())` 实现液态玻璃与按压反馈。
struct AddMenuCircleButton: View {
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let usesGlassStyle: Bool

    init(
        onAddBook: @escaping () -> Void,
        onAddNote: @escaping () -> Void,
        usesGlassStyle: Bool = false
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.usesGlassStyle = usesGlassStyle
    }

    var body: some View {
        Menu {
            Button("添加书籍", systemImage: "book.badge.plus", action: onAddBook)
            Button("添加书摘", systemImage: "square.and.pencil", action: onAddNote)
        } label: {
            if usesGlassStyle {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.brand)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.brand)
                    .frame(width: 36, height: 36)
                    .background(Color.contentBackground, in: Circle())
                    .overlay(Circle().stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
        }
        .topBarGlassButtonStyle(usesGlassStyle)
        .accessibilityLabel("添加")
    }
}
