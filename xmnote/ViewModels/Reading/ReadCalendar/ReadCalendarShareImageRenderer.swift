/**
 * [INPUT]: 依赖 SwiftUI ImageRenderer、UIKit PNG 编码与 Photos 添加权限
 * [OUTPUT]: 对外提供 ReadCalendarShareImageRenderer，生成临时分享图并保存至系统相册
 * [POS]: Reading/ReadCalendar 分享成品渲染器，与现有书单/书摘分享渲染职责保持一致
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Photos
import SwiftUI
import UIKit

enum ReadCalendarShareImageError: LocalizedError {
    case renderFailed
    case photoLibraryPermissionDenied

    var errorDescription: String? {
        switch self {
        case .renderFailed: "图片生成失败，请稍后重试"
        case .photoLibraryPermissionDenied: "没有相册写入权限，请在系统设置中允许后重试"
        }
    }
}

/// 阅读日历分享图渲染器；渲染必须在主线程执行，临时文件由调用方在消费后清理。
@MainActor
enum ReadCalendarShareImageRenderer {
    /// 将与预览相同的 SwiftUI 卡片以 3 倍比例输出为临时 PNG。
    static func renderPNG<Content: View>(content: Content) throws -> URL {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else {
            throw ReadCalendarShareImageError.renderFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xmnote-read-calendar-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 请求“仅添加”权限并把图片写入相册；异步调用包含系统权限暂停点，不共享可变状态。
    static func saveToPhotoLibrary(fileURL: URL) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolvedStatus: PHAuthorizationStatus
        if status == .notDetermined {
            resolvedStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            resolvedStatus = status
        }
        guard resolvedStatus == .authorized || resolvedStatus == .limited else {
            throw ReadCalendarShareImageError.photoLibraryPermissionDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
        }
    }

    /// 删除本次生成的临时文件；文件已被系统清理时静默完成。
    static func discardTemporaryFile(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
