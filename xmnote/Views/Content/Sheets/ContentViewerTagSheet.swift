/**
 * [INPUT]: 依赖 XMTagLabel、SwiftUI 与 DesignTokens，并接收查看器的只读标签列表
 * [OUTPUT]: 对外提供 ContentViewerTagSheet，承载书摘标签只读浏览
 * [POS]: Views/Content/Sheets 的页面业务 Sheet；由 ContentViewerView 呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 标签查看弹层，统一承接书摘标签只读浏览体验。
struct ContentViewerTagSheet: View {
    let tags: [String]
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if tags.isEmpty {
                    Text("当前书摘没有标签")
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    ContentViewerFlowTagWrap(tags: tags)
                }

                Spacer(minLength: 0)
            }
            .padding(Spacing.screenEdge)
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: onDismiss)
                }
            }
        }
    }
}

/// 简单流式标签换行视图，保持 viewer 标签展示密度稳定。
private struct ContentViewerFlowTagWrap: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(chunkedTags, id: \.self) { row in
                HStack(spacing: Spacing.cozy) {
                    ForEach(row, id: \.self) { tag in
                        XMTagLabel(tag)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var chunkedTags: [[String]] {
        stride(from: 0, to: tags.count, by: 3).map { index in
            Array(tags[index..<min(index + 3, tags.count)])
        }
    }
}
