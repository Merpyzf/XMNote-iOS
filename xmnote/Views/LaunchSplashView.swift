/**
 * [INPUT]: 依赖 DesignTokens 品牌色与间距令牌
 * [OUTPUT]: 对外提供 LaunchSplashView，数据库异步初始化期间的品牌闪屏
 * [POS]: Views 顶层辅助视图，仅由 xmnoteApp 在数据库就绪前展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 数据库异步初始化期间展示的品牌闪屏，静态标识保持从容感。
struct LaunchSplashView: View {
    var body: some View {
        VStack(spacing: Spacing.base) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .frame(width: 100, height: 100)
                .background(Color.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.containerXL, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: CornerRadius.containerXL, style: .continuous)
                        .strokeBorder(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
                )
            Text("纸间书摘")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(Color.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePage)
    }
}

#Preview {
    LaunchSplashView()
}
