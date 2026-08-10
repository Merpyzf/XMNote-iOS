/**
 * [INPUT]: 依赖 XMInlineSearchField 与 SwiftUI Binding 同步当前分类搜索词和焦点状态，接收可访问性可见态与取消回调闭合父级滚动状态
 * [OUTPUT]: 对 Note 页面提供兼容既有调用契约的搜索内容头，统一复用跨模块搜索、清除、提交与取消语义
 * [POS]: Note 模块页面私有搜索组件，由 NoteCollectionView 控制显隐与分类上下文
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 以 SwiftUI 原生输入能力承载分类内搜索，让视觉表面弱于内容而保持完整焦点与清除语义。
struct NotePullDownSearchBar: View {
    @Binding var text: String
    @Binding var isActive: Bool
    let placeholder: String
    let isAccessibilityVisible: Bool
    let onCancel: () -> Void

    var body: some View {
        XMInlineSearchField(
            text: $text,
            isActive: $isActive,
            prompt: placeholder,
            onCancel: onCancel
        )
        .accessibilityHidden(!isAccessibilityVisible)
    }
}
