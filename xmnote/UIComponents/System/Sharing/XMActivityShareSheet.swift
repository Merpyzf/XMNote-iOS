/**
 * [INPUT]: 依赖 SwiftUI 的 UIViewControllerRepresentable 与 UIKit 的 UIActivityViewController，接收文本、文件 URL 等系统 activity item
 * [OUTPUT]: 对外提供 XMActivitySharePayload 与 XMActivityShareSheet，统一页面级 item-driven 系统分享入口
 * [POS]: UIComponents/System/Sharing 的系统分享桥接组件，被内容查看、书摘列表、回顾、书单与阅读日历跨模块复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 系统分享会话载荷，用稳定 item 身份把菜单动作与页面级分享 Sheet 解耦。
struct XMActivitySharePayload: Identifiable {
    let activityItems: [Any]
    let id = UUID()
}

/// UIKit 系统分享面板桥接，页面通过 `.sheet(item:)` 在稳定宿主层级呈现。
struct XMActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    /// 使用当前会话快照创建系统活动控制器，避免菜单关闭后重新读取已变化的页面选择。
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    /// 分享会话展示期间不替换 activity items，防止系统面板交互状态被 SwiftUI 更新重置。
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
