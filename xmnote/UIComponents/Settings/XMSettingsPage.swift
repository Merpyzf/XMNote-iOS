/**
 * [INPUT]: 依赖 DesignSystem 的页面间距与表层语义，接收配置页分区内容
 * [OUTPUT]: 对外提供统一滚动、回弹、安全边距、最大宽度与页面背景的 XMSettingsPage
 * [POS]: UIComponents/Settings 的配置页面根容器，是卡片式配置页的唯一标准入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 配置类页面的共享布局语义，统一页面留白、分区节奏和常用控件最小体量。
enum XMSettingsPageLayout {
    static let contentMaxWidth: CGFloat = 640
    static let sectionSpacing: CGFloat = Spacing.double
    static let sectionContentSpacing: CGFloat = Spacing.cozy
    static let regularRowMinHeight: CGFloat = 56
    static let detailRowMinHeight: CGFloat = 64
    static let iconSlotWidth: CGFloat = Spacing.double
    static let inputMinHeight: CGFloat = 48
}

/// 卡片式配置页面根容器；业务页面只注入分区，不再重复声明滚动与页面级布局细节。
struct XMSettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    /// 注入配置分区，页面统一获得滚动、回弹、安全边距与最大内容宽度。
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: XMSettingsPageLayout.sectionSpacing) {
                content
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.contentEdge)
            .frame(maxWidth: XMSettingsPageLayout.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.always)
        .scrollIndicators(.hidden)
        .background(Color.surfacePage.ignoresSafeArea())
    }
}
