/**
 * [INPUT]: 依赖 SwiftUI UIViewControllerRepresentable、NoteReviewLaunchPayload、RepositoryContainer、XMToastCenter 与全屏导航回调
 * [OUTPUT]: 对外提供 NoteReviewUIKitHost（现有 SwiftUI App 外壳到 UIKit 全屏回顾控制器的唯一桥接层）
 * [POS]: Views/Note/Components 的呈现桥接层，只注入标签 Sheet 所需环境，不承载集合视图或业务状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// SwiftUI 只负责创建 UIKit 控制器并把关闭、详情导航和轻量反馈上抛给 App 外壳。
struct NoteReviewUIKitHost: UIViewControllerRepresentable {
    let payload: NoteReviewLaunchPayload
    let repositories: RepositoryContainer
    let toastCenter: XMToastCenter
    let onDismiss: () -> Void
    let onOpenDetail: (Int64, ContentViewerSourceContext) -> Void
    let onError: (String) -> Void

    /// 创建全屏回顾控制器；后续数据和交互均由 UIKit 会话拥有。
    func makeUIViewController(context: Context) -> NoteReviewViewController {
        NoteReviewViewController(
            payload: payload,
            repositories: repositories,
            toastCenter: toastCenter,
            onDismiss: onDismiss,
            onOpenDetail: onOpenDetail,
            onError: onError
        )
    }

    /// 启动负载在一次全屏任务内保持稳定，不对活跃 UIKit 会话做重建式更新。
    func updateUIViewController(_ uiViewController: NoteReviewViewController, context: Context) {}

    /// 宿主被导航移除时也释放会话，覆盖并非经页面关闭按钮退出的生命周期。
    static func dismantleUIViewController(_ uiViewController: NoteReviewViewController, coordinator: ()) {
        uiViewController.disposeReviewSession()
    }
}
