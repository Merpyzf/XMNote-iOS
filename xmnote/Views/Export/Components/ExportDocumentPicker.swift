/**
 * [INPUT]: 依赖 SwiftUI/UIKit 的文档选择器，接收一次导出的一个或多个临时文件 URL
 * [OUTPUT]: 为导出结果页提供 ExportDocumentPicker，在系统保存完成或取消时准确回调并支持 iPad 弹出定位
 * [POS]: Views/Export/Components 的功能内多文件“存储到文件”桥接，由导出结果页持有 ArtifactTicket 期间使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 使用系统导出文档选择器复制一个或多个文件；业务层在完成回调后释放临时文件票据。
struct ExportDocumentPicker: UIViewControllerRepresentable {
    let fileURLs: [URL]
    let onComplete: (Bool) -> Void

    /// 让当前呈现持有独立的完成回调去重状态。
    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    /// 创建只复制不移动源文件的系统选择器，并为 iPad popover 提供稳定的锚点。
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(
            forExporting: fileURLs,
            asCopy: true
        )
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.maxY,
                width: 1,
                height: 1
            )
            popover.permittedArrowDirections = []
        }
        return controller
    }

    /// 导出来源在当前呈现期间保持不变，不重建系统选择器。
    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    /// 文档选择器 delegate 只允许发出一次结束事件，避免 dismiss 与选择回调重复清理文件。
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onComplete: (Bool) -> Void
        private var hasCompleted = false

        /// 绑定当前文件票据的完成通知，不持有业务状态。
        init(onComplete: @escaping (Bool) -> Void) {
            self.onComplete = onComplete
        }

        /// 系统返回有效目标后通知业务层完成文件交付。
        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            complete(succeeded: !urls.isEmpty)
        }

        /// 用户取消时结束当前交付并由调用方处理票据生命周期。
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            complete(succeeded: false)
        }

        /// 保证同一次系统呈现最多通知一次结束事件。
        private func complete(succeeded: Bool) {
            guard !hasCompleted else { return }
            hasCompleted = true
            onComplete(succeeded)
        }
    }
}
