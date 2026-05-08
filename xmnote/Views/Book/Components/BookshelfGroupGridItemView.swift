/**
 * [INPUT]: 依赖 BookshelfGroupPayload 展示分组名称、书籍数量与代表封面
 * [OUTPUT]: 对外提供 BookshelfGroupGridItemView，渲染默认书架中的分组聚合卡
 * [POS]: Book 模块页面私有子视图，服务 BookGridView 的分组条目展示，不承担导航与数据读取
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 默认书架中的分组聚合卡，以轻量封面拼贴表达组内内容。
struct BookshelfGroupGridItemView: View {
    let group: BookshelfGroupPayload
    var isPinned = false
    var titleDisplayMode: BookshelfTitleDisplayMode = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            coverMosaic
            groupInfo
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name)，\(group.bookCount)本")
    }

    private var coverMosaic: some View {
        BookshelfGridGroupCoverView(
            covers: group.representativeCovers,
            count: group.bookCount,
            isPinned: isPinned
        )
    }

    private var groupInfo: some View {
        BookshelfTitleText(
            text: group.name,
            mode: titleDisplayMode,
            style: .captionMedium,
            color: .textPrimary
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

#Preview {
    BookshelfGroupGridItemView(group: BookshelfGroupPayload(
        id: 1,
        name: "计算机",
        bookCount: 25,
        representativeCovers: ["", "", "", ""],
        books: []
    ), isPinned: true)
    .frame(width: 110)
    .padding(Spacing.screenEdge)
}
