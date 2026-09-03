/**
 * [INPUT]: 依赖 SwiftUI UIViewControllerRepresentable、NoteReviewLaunchPayload、NoteRepositoryProtocol 与全屏导航回调
 * [OUTPUT]: 对外提供 NoteReviewUIKitHost（现有 SwiftUI App 外壳到 UIKit 全屏回顾控制器的唯一桥接层）
 * [POS]: Views/Note/Components 的呈现桥接层，不承载集合视图、设置 Sheet 或收藏业务状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// SwiftUI 只负责创建 UIKit 控制器并把关闭、详情导航和轻量反馈上抛给 App 外壳。
struct NoteReviewUIKitHost: UIViewControllerRepresentable {
    let payload: NoteReviewLaunchPayload
    let repository: any NoteRepositoryProtocol
    let onDismiss: () -> Void
    let onOpenDetail: (Int64, [Int64]) -> Void
    let onError: (String) -> Void
    let onInfo: (String) -> Void

    /// 创建全屏回顾控制器；后续数据和交互均由 UIKit 会话拥有。
    func makeUIViewController(context: Context) -> NoteReviewViewController {
        NoteReviewViewController(
            payload: payload,
            repository: repository,
            onDismiss: onDismiss,
            onOpenDetail: onOpenDetail,
            onError: onError,
            onInfo: onInfo
        )
    }

    /// 启动负载在一次全屏任务内保持稳定，不对活跃 UIKit 会话做重建式更新。
    func updateUIViewController(_ uiViewController: NoteReviewViewController, context: Context) {}
}
