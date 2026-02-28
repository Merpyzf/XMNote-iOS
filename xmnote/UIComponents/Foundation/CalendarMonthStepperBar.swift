/**
 * [INPUT]: 依赖 xmnote/Utilities/DesignTokens.swift 的颜色、圆角、边框与间距令牌
 * [OUTPUT]: 对外提供 CalendarMonthStepperBar（月视图顶部月份切换胶囊组件，支持轻玻璃浮层视觉）
 * [POS]: UIComponents/Foundation 的可复用月份切换组件，服务阅读日历与后续月视图页面
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct CalendarMonthStepperBar: View {
    private enum Layout {
        static let sideButtonOuterSize: CGFloat = 40
        static let sideButtonInnerSize: CGFloat = 30
    }

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
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .contentTransition(.numericText())
                .animation(.easeInOut, value: title)

            Spacer(minLength: Spacing.half)

            arrowButton(
                systemName: "chevron.right",
                isEnabled: canGoNext,
                action: onNext
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.readCalendarCardBackground.opacity(0.68))
                .glassEffect(.regular.interactive(), in: .capsule)
        )
//        .overlay {
//            Capsule(style: .continuous)
//                .stroke(Color.readCalendarCardStroke.opacity(0.85), lineWidth: CardStyle.borderWidth)
//        }
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 5)
        .shadow(color: Color.white.opacity(0.45), radius: 0.2, x: 0, y: -0.2)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isEnabled ? Color.readCalendarSubtleText : Color.textHint)
                .frame(width: Layout.sideButtonInnerSize, height: Layout.sideButtonInnerSize)
                .background(
                    Circle()
                        .fill(Color.readCalendarCardBackground.opacity(isEnabled ? 0.84 : 0.55))
                )
                .overlay {
                    Circle()
                        .stroke(Color.readCalendarCardStroke.opacity(isEnabled ? 0.88 : 0.58), lineWidth: CardStyle.borderWidth)
                }
        }
        .topBarGlassButtonStyle(isEnabled)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.56)
        .frame(width: Layout.sideButtonOuterSize, height: Layout.sideButtonOuterSize)
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
