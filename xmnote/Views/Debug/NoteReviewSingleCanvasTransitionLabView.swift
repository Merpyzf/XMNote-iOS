#if DEBUG
/**
 * [INPUT]: 依赖 SwiftUI、显式注入的 NoteRepositoryProtocol 只读入口与 NoteReviewSingleCanvasTransitionPrototypeController
 * [OUTPUT]: 对外提供测试中心的单画布共享纸张转场实验入口
 * [POS]: Debug 测试页，只承载导航语义并把完整交互生命周期交给 UIKit 原型控制器
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 使用模拟数据或现有回顾筛选的只读快照验证画布，不修改真实书摘。
struct NoteReviewSingleCanvasTransitionLabView: View {
    let repository: any NoteRepositoryProtocol

    var body: some View {
        NoteReviewSingleCanvasTransitionPrototypeHost(repository: repository)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("单画布转场")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct NoteReviewSingleCanvasTransitionPrototypeHost: UIViewControllerRepresentable {
    let repository: any NoteRepositoryProtocol

    func makeUIViewController(context: Context) -> NoteReviewSingleCanvasTransitionPrototypeController {
        NoteReviewSingleCanvasTransitionPrototypeController(repository: repository)
    }

    func updateUIViewController(
        _ uiViewController: NoteReviewSingleCanvasTransitionPrototypeController,
        context: Context
    ) {}

    static func dismantleUIViewController(_ controller: NoteReviewSingleCanvasTransitionPrototypeController, coordinator: ()) {
        controller.disposeCanvas()
    }
}
#endif
