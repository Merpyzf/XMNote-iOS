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
    let onOpenDebugCenter: (() -> Void)?
    let usesGlassStyle: Bool

    /// 注入新增书籍/笔记操作回调，配置顶部加号入口行为。
    init(
        onAddBook: @escaping () -> Void,
        onAddNote: @escaping () -> Void,
        onOpenDebugCenter: (() -> Void)? = nil,
        usesGlassStyle: Bool = false
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenDebugCenter = onOpenDebugCenter
        self.usesGlassStyle = usesGlassStyle
    }

    var body: some View {
        Menu {
            Button("添加书籍", systemImage: "book.badge.plus", action: onAddBook)
            Button("添加书摘", systemImage: "square.and.pencil", action: onAddNote)
            #if DEBUG
            if let onOpenDebugCenter {
                Divider()
                Button("测试中心", systemImage: "hammer") {
                    onOpenDebugCenter()
                }
            }
            #endif
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
                    .background(Color.surfaceCard, in: Circle())
                    .overlay(Circle().stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
        }
        .topBarGlassButtonStyle(usesGlassStyle)
        .accessibilityLabel("添加")
    }
}
