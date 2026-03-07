/**
 * [INPUT]: 依赖 TimelineNoteEvent 数据模型、TimelineCardMetaLine、CardContainer 容器、DesignTokens 设计令牌
 * [OUTPUT]: 对外提供 TimelineNoteCard（时间线书摘卡片）
 * [POS]: Reading/Timeline 页面私有子视图，渲染书摘正文与用户批注
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 时间线书摘卡片，展示划线正文与用户批注（引用块风格）。
struct TimelineNoteCard: View {
    let event: TimelineNoteEvent
    let timestamp: Int64
    let bookName: String

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                TimelineCardMetaLine(timestamp: timestamp, bookName: bookName)

                Text(event.content)
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                if !event.idea.isEmpty {
                    ideaSection
                }
            }
            .padding(Spacing.contentEdge)
        }
    }

    // MARK: - Idea

    private var ideaSection: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.brand.opacity(0.5))
                .frame(width: 2.5)

            Text(event.idea)
                .font(.callout)
                .foregroundStyle(Color.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ZStack {
        Color.windowBackground.ignoresSafeArea()
        VStack(spacing: Spacing.base) {
            TimelineNoteCard(
                event: TimelineNoteEvent(
                    content: "人生最大的幸运，就是在年富力强时发现了自己的使命。",
                    idea: "这句话让我想到了乔布斯在斯坦福的演讲",
                    bookTitle: "活法"
                ),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                bookName: "活法"
            )
            TimelineNoteCard(
                event: TimelineNoteEvent(
                    content: "我们总是倾向于用最复杂的方式来解决问题，却忽略了最简单的途径往往就在眼前。",
                    idea: "",
                    bookTitle: "思考快与慢"
                ),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                bookName: "思考快与慢"
            )
        }
        .padding(.horizontal, Spacing.screenEdge)
    }
}
