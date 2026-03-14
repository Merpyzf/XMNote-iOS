#if DEBUG
/**
 * [INPUT]: 依赖 OCRRepositoryProtocol 提供偏好持久化与 OCR 能力，依赖 UIKit/NSAttributedString 承接裁切图像与富文本回填
 * [OUTPUT]: 对外提供 BaiduOCRTestViewModel，驱动百度 OCR Debug 页面状态、偏好与结果回填
 * [POS]: Debug 模块百度 OCR 测试页状态编排器，集中管理图片选择、裁切、识别与双编辑器目标一致性
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit

@MainActor
@Observable
final class BaiduOCRTestViewModel {
    enum FocusField: String {
        case content
        case idea

        var title: String {
            switch self {
            case .content:
                return "书摘内容"
            case .idea:
                return "想法"
            }
        }
    }

    private let repository: any OCRRepositoryProtocol
    private var shouldPersistPreferences = false

    var preferences: OCRPreferences {
        didSet {
            guard shouldPersistPreferences else { return }
            repository.savePreferences(preferences)
        }
    }

    var selectedImage: UIImage?
    var selectedSourceTitle = "未选择"
    var cropRectNormalized = BaiduOCRTestViewModel.defaultCropRect

    var contentText = NSAttributedString(string: "")
    var contentFormats = Set<RichTextFormat>()
    var ideaText = NSAttributedString(string: "")
    var ideaFormats = Set<RichTextFormat>()
    var selectedHighlightARGB: UInt32 = HighlightColors.defaultHighlightColor
    var focusedField: FocusField = .content

    var isRecognizing = false
    var statusMessage: String?
    var errorMessage: String?
    var recognitionResult: OCRRecognitionResult?

    init(repository: any OCRRepositoryProtocol) {
        self.repository = repository
        self.preferences = repository.fetchPreferences()
        self.shouldPersistPreferences = true
    }

    static let defaultCropRect = CGRect(x: 0.1, y: 0.14, width: 0.8, height: 0.58)

    var canUseCamera: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var isRuntimeSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    var runtimeHintText: String {
        if isRuntimeSupported {
            return "SDK 通过运行时动态加载，仅在真机 Debug 构建下可执行识别。"
        }
        return "当前是模拟器环境。页面可验证 UI、裁切与回填链路，但无法实际调用百度 OCR SDK。"
    }

    var selectedTargetTitle: String {
        focusedField.title
    }

    var canRecognize: Bool {
        !isRecognizing && selectedImage != nil && preferences.credentials.isConfigured
    }

    func updateFocus(isFocused: Bool, field: FocusField) {
        if isFocused {
            focusedField = field
        }
    }

    func selectImage(_ image: UIImage, sourceTitle: String) {
        selectedImage = image.normalizedUpImage()
        selectedSourceTitle = sourceTitle
        cropRectNormalized = Self.defaultCropRect
        recognitionResult = nil
        errorMessage = nil
        statusMessage = "已载入\(sourceTitle)图片，请调整裁切区域后开始识别。"
    }

    func resetCrop() {
        cropRectNormalized = Self.defaultCropRect
    }

    func clearAuthorizationCache() {
        repository.clearAuthorizationCache()
        statusMessage = "已清除百度 OCR 鉴权缓存。"
        errorMessage = nil
    }

    func recognizeCurrentSelection() async {
        guard let selectedImage else {
            errorMessage = "请先选择一张待识别图片。"
            return
        }

        guard preferences.credentials.isConfigured else {
            errorMessage = "请先填写 API Key 与 Secret Key。"
            return
        }

        guard let croppedImage = crop(image: selectedImage, normalizedRect: cropRectNormalized),
              let imageData = croppedImage.jpegData(compressionQuality: 0.92) else {
            errorMessage = OCRRepositoryError.invalidImageData.localizedDescription
            return
        }

        isRecognizing = true
        errorMessage = nil
        statusMessage = "正在识别..."

        defer {
            isRecognizing = false
        }

        do {
            let result = try await repository.recognizeText(
                request: OCRRecognitionRequest(
                    imageData: imageData,
                    preferences: preferences
                )
            )
            recognitionResult = result
            applyRecognizedText(result.text)
            statusMessage = "识别完成，结果已回填到\(focusedField.title)。"
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = nil
        }
    }
}

private extension BaiduOCRTestViewModel {
    func applyRecognizedText(_ text: String) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return }

        switch focusedField {
        case .content:
            contentText = appendedText(normalizedText, to: contentText)
        case .idea:
            ideaText = appendedText(normalizedText, to: ideaText)
        }
    }

    func appendedText(_ text: String, to original: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: original)
        if mutable.length > 0 {
            let suffix = mutable.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !suffix.isEmpty {
                mutable.append(NSAttributedString(string: "\n"))
            }
        }
        mutable.append(NSAttributedString(string: text))
        return mutable
    }

    func crop(image: UIImage, normalizedRect: CGRect) -> UIImage? {
        let normalizedImage = image.normalizedUpImage()
        guard let cgImage = normalizedImage.cgImage else { return nil }

        let clamped = normalizedRect.clampedToUnit
        let pixelRect = CGRect(
            x: clamped.minX * CGFloat(cgImage.width),
            y: clamped.minY * CGFloat(cgImage.height),
            width: clamped.width * CGFloat(cgImage.width),
            height: clamped.height * CGFloat(cgImage.height)
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        guard pixelRect.width > 1, pixelRect.height > 1,
              let cropped = cgImage.cropping(to: pixelRect) else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: normalizedImage.scale, orientation: .up)
    }
}

private extension CGRect {
    var clampedToUnit: CGRect {
        let width = min(max(size.width, 0.12), 1)
        let height = min(max(size.height, 0.12), 1)
        let x = min(max(origin.x, 0), 1 - width)
        let y = min(max(origin.y, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

private extension UIImage {
    func normalizedUpImage() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
#endif
