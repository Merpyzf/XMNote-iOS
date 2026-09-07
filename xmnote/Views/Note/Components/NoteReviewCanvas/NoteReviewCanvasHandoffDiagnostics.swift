/**
 * [INPUT]: 接收生产转场中的图像、显示表面与几何，不读取业务正文或书摘身份
 * [OUTPUT]: 在显式 Debug 启动参数下输出有界的首尾交接证据
 * [POS]: NoteReviewCanvas 内部诊断，不参与正常显示、排版或状态提交
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import UIKit
import OSLog

/// 主 actor 只在诊断检查点捕获；编码和写入串行执行，关闭开关后没有图像工作。
@MainActor
enum NoteReviewCanvasHandoffDiagnostics {
    static var capturesEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["NOTE_REVIEW_HANDOFF_CAPTURE"] == "1"
        #else
        false
        #endif
    }
    static var disablesEdges: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["NOTE_REVIEW_HANDOFF_NO_EDGES"] == "1"
        #else
        false
        #endif
    }
    static var fixedProgress: CGFloat? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["NOTE_REVIEW_HANDOFF_PROGRESS"],
              let value = Double(raw), (0...1).contains(value) else { return nil }
        return CGFloat(value)
        #else
        return nil
        #endif
    }
    private static let logger = Logger(subsystem: "com.wangke.xmnote", category: "CanvasHandoff")
    private static var captureCount = 0
    private static let run = UUID().uuidString
    private static let writer = DispatchQueue(label: "com.wangke.xmnote.handoff-evidence", qos: .utility)

    /// 仅写不含业务身份的诊断事件，不改变显示时序。
    static func event(_ message: String) {
        guard capturesEnabled else { return }
        logger.notice("\(message, privacy: .public)")
    }

    /// 元数据只含阶段、透明度与视图几何，不含正文、无障碍文本或 noteID。
    static func record(_ stage: String, view: UIView, progress: CGFloat = 0) {
        guard capturesEnabled else { return }
        let geometry = "frame=\(view.frame) bounds=\(view.bounds) alpha=\(view.alpha) hidden=\(view.isHidden) progress=\(progress)"
        logger.notice("\(stage, privacy: .public) \(geometry, privacy: .public)")
        guard view.bounds.width > 0, view.bounds.height > 0, captureCount < 32 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.traitCollection.displayScale
        format.preferredRange = .standard
        let bitmap = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { output in
            output.cgContext.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
            let complete = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            event("checkpoint-hierarchy complete=\(complete)")
        }
        save(bitmap, stage: stage)
    }

    /// 已生成的正文图直接保存，不再次捕获或改变源页面状态；最多保留三十二个检查点。
    static func save(_ image: UIImage, stage: String) {
        guard capturesEnabled, captureCount < 32 else { return }
        captureCount += 1
        let filename = String(format: "%02d-", captureCount) + stage + ".png"
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteReviewHandoff/" + run, isDirectory: true)
        logger.notice("Capture \(filename, privacy: .public) size=\(String(describing: image.size), privacy: .public)")
        writer.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try image.pngData()?.write(to: directory.appendingPathComponent(filename), options: .atomic)
            } catch { /* Evidence failure never changes production navigation. */ }
        }
    }
}
