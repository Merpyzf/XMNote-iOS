/**
 * [INPUT]: 依赖稳定书摘身份、相机倍率及内容区域中的阅读锚点
 * [OUTPUT]: 提供环境变化时的逻辑锚点恢复与必要边缘留白
 * [POS]: NoteReviewCanvas 会话视口值；不读写持久化偏好
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 同一会话内保存视口；旋转时保留逻辑阅读位置，不能用重新居中代替恢复。
nonisolated struct NoteReviewCanvasViewport: Sendable {
    let noteID: Int64
    let offset: CGPoint
    let zoomScale: CGFloat
    let anchor: CGPoint
    let viewportRect: CGRect

    /// 调用方在停止惯性后捕获显示中的位置；不包含任何可变视图引用。
    init(noteID: Int64, offset: CGPoint, zoomScale: CGFloat, anchor: CGPoint, viewportRect: CGRect) {
        self.noteID = noteID; self.offset = offset; self.zoomScale = zoomScale
        self.anchor = anchor; self.viewportRect = viewportRect
    }

    /// 可用区域改变时保持锚点的相对位置；倍率由调用方原样恢复，不做 fit。
    func anchor(in rect: CGRect) -> CGPoint {
        guard viewportRect.width > 0, viewportRect.height > 0 else { return anchor }
        return CGPoint(x: rect.minX + (anchor.x - viewportRect.minX) / viewportRect.width * rect.width,
            y: rect.minY + (anchor.y - viewportRect.minY) / viewportRect.height * rect.height)
    }

    /// 将新几何中的纸张中心投影到保存的锚点；允许负偏移，由必要留白承接边缘。
    func offset(for frame: CGRect, in rect: CGRect) -> CGPoint {
        let point = anchor(in: rect)
        return CGPoint(x: frame.midX * zoomScale - (point.x - rect.minX),
            y: frame.midY * zoomScale - (point.y - rect.minY))
    }
}
