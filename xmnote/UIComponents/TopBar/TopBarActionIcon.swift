/**
 * [INPUT]: 依赖 SwiftUI 图标与字体渲染能力
 * [OUTPUT]: 对外提供 TopBarActionIcon 顶部栏统一图标组件
 * [POS]: UIComponents/TopBar 的原子级按钮图标组件，被个人页与其它顶部操作区域复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

struct TopBarActionIcon: View {
    let systemName: String
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .medium
    var foregroundColor: Color = .secondary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: weight))
            .foregroundStyle(foregroundColor)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
    }
}
