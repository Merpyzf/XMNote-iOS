/**
 * [INPUT]: 依赖 SwiftUI 系统占位组件与 DesignTokens 的页面背景色
 * [OUTPUT]: 对外提供 BookSearchSettingsPlaceholderView，承接“添加书籍设置”入口的首期占位页
 * [POS]: Book 模块的二级占位页面，在搜索偏好能力未接入前提供稳定设置入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 添加书籍设置占位页，仅用于固定入口层级，不承担真实配置读写。
struct BookSearchSettingsPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("添加书籍设置", systemImage: "slider.horizontal.3")
        } description: {
            Text("设置入口已开放，搜索来源与录入流程配置将在后续版本补齐。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePage)
        .navigationTitle("添加书籍设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        BookSearchSettingsPlaceholderView()
    }
}
