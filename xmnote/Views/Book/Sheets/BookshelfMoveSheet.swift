/**
 * [INPUT]: 依赖 BookshelfPendingAction、选择数量和移动可用性，依赖外部闭包提交移到最前/最后意图
 * [OUTPUT]: 对外提供 BookshelfMoveSheet，承载默认书架批量移动排序入口
 * [POS]: Book 模块业务 Sheet，被 BookGridView 的编辑态底部栏唤起
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 默认书架批量移动 Sheet，只暴露已完成核对的普通区最前/最后排序能力。
struct BookshelfMoveSheet: View {
    @Environment(\.dismiss) private var dismiss

    let selectedCount: Int
    let canSubmit: Bool
    let disabledReason: String?
    let activeAction: BookshelfPendingAction?
    let onMoveToStart: () -> Void
    let onMoveToEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header

            VStack(spacing: Spacing.compact) {
                moveButton(
                    title: "移到最前",
                    subtitle: "放到普通区第一位",
                    icon: "arrow.up.to.line",
                    action: onMoveToStart
                )

                moveButton(
                    title: "移到最后",
                    subtitle: "放到普通区最后一位",
                    icon: "arrow.down.to.line",
                    action: onMoveToEnd
                )
            }

            Text(statusText)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.section)
        .background(Color.surfaceSheet)
        .presentationDetents([.height(288)])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text("移动")
                    .font(AppTypography.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.textPrimary)

                Text("已选 \(selectedCount) 项")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer(minLength: Spacing.compact)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(AppTypography.title3)
                    .foregroundStyle(Color.textHint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
    }

    private func moveButton(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Image(systemName: icon)
                    .font(AppTypography.title3)
                    .fontWeight(.medium)
                    .foregroundStyle(canSubmit ? Color.brand : Color.textHint)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: Spacing.tiny) {
                    Text(title)
                        .font(AppTypography.body)
                        .fontWeight(.medium)
                        .foregroundStyle(canSubmit ? Color.textPrimary : Color.textSecondary)

                    Text(subtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer(minLength: Spacing.compact)
            }
            .padding(Spacing.base)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .accessibilityLabel(canSubmit ? title : "\(title)，\(disabledReason ?? "当前不可用")")
    }

    private var statusText: String {
        if let activeAction {
            return "正在\(activeAction.title)..."
        }
        guard canSubmit else {
            return disabledReason ?? "至少选择一个非置顶项后才能移动"
        }
        return "移动只调整普通区顺序，置顶区保持不变"
    }
}

#Preview {
    BookshelfMoveSheet(
        selectedCount: 3,
        canSubmit: true,
        disabledReason: nil,
        activeAction: nil,
        onMoveToStart: {},
        onMoveToEnd: {}
    )
}
