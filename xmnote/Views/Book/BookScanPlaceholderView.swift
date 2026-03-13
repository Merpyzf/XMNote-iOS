/**
 * [INPUT]: 依赖 SwiftUI 系统占位组件与 DesignTokens 的页面背景色
 * [OUTPUT]: 对外提供 BookScanPlaceholderView，承接“扫码录入”入口的首期占位页
 * [POS]: Book 模块的二级占位页面，在扫码能力未接入前为入口提供稳定导航终点
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 扫码录入占位页，仅声明入口已就位，避免当前迭代误导为已接入扫描能力。
struct BookScanPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("扫码录入", systemImage: "barcode.viewfinder")
        } description: {
            Text("扫码录入入口已就位，实际扫描能力将在后续版本接入。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePage)
        .navigationTitle("扫码录入")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        BookScanPlaceholderView()
    }
}
