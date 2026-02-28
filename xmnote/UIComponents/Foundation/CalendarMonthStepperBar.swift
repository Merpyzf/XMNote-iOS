/**
 * [INPUT]: 依赖 xmnote/Utilities/DesignTokens.swift 的颜色、圆角、边框与间距令牌
 * [OUTPUT]: 对外提供 CalendarMonthStepperBar（月视图顶部月份切换胶囊组件）
 * [POS]: UIComponents/Foundation 的可复用月份切换组件，服务阅读日历与后续月视图页面
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct CalendarMonthStepperBar: View {
    let title: String
    let canGoPrev: Bool
    let canGoNext: Bool
    let onPrev: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            arrowButton(
                systemName: "chevron.left",
                isEnabled: canGoPrev,
                action: onPrev
            )

            Spacer(minLength: Spacing.half)

            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .contentTransition(.numericText())

            Spacer(minLength: Spacing.half)

            arrowButton(
                systemName: "chevron.right",
                isEnabled: canGoNext,
                action: onNext
            )
        }
        .padding(.horizontal, Spacing.half)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .fill(Color.contentBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.card, style: .continuous)
                .stroke(Color.cardBorder, lineWidth: CardStyle.borderWidth)
        }
        .shadow(color: Color.black.opacity(0.03), radius: 8, x: 0, y: 2)
    }

    private func arrowButton(
        systemName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.textSecondary : Color.textHint)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.bgSecondary.opacity(isEnabled ? 1 : 0.68))
                )
                .overlay {
                    Circle()
                        .stroke(Color.cardBorder.opacity(isEnabled ? 1 : 0.65), lineWidth: CardStyle.borderWidth)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
        .frame(width: 40, height: 40)
        .contentShape(Circle())
    }
}

#Preview {
    ZStack {
        Color.windowBackground.ignoresSafeArea()
        CalendarMonthStepperBar(
            title: "2026年2月",
            canGoPrev: true,
            canGoNext: false,
            onPrev: {},
            onNext: {}
        )
        .padding()
    }
}
