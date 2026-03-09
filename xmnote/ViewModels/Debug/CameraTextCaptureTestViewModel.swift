#if DEBUG
/**
 * [INPUT]: 依赖 Foundation 与 VisionKit 读取系统支持的文本识别语言标识
 * [OUTPUT]: 对外提供 CameraTextCaptureTestViewModel，驱动 OCR 测试页状态与语言信息展示
 * [POS]: Debug 模块文本识别测试页状态编排器，集中维护双编辑器内容、焦点与语言列表
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit
import VisionKit

@MainActor
@Observable
final class CameraTextCaptureTestViewModel {
    struct SupportedLanguage: Identifiable {
        let id: String
        let displayName: String
    }

    enum FocusField: String {
        case none
        case content
        case idea

        var title: String {
            switch self {
            case .none:
                return "无"
            case .content:
                return "书摘内容"
            case .idea:
                return "想法"
            }
        }
    }

    var contentText = NSAttributedString(string: "")
    var contentFormats = Set<RichTextFormat>()
    var ideaText = NSAttributedString(string: "")
    var ideaFormats = Set<RichTextFormat>()
    var selectedHighlightARGB: UInt32 = HighlightColors.defaultHighlightColor
    var focusedField: FocusField = .none

    let supportedLanguages: [SupportedLanguage]

    init() {
        let locale = Locale.current
        supportedLanguages = ImageAnalyzer.supportedTextRecognitionLanguages.map { identifier in
            let displayName = locale.localizedString(forIdentifier: identifier) ?? identifier
            return SupportedLanguage(id: identifier, displayName: displayName)
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    var isAPISupported: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var isCurrentResponderEligible: Bool {
        focusedField != .none && isAPISupported
    }

    var focusedFieldTitle: String {
        focusedField.title
    }

    var supportedLanguageCountText: String {
        "\(supportedLanguages.count) 种"
    }

    var cameraHintText: String {
        if isAPISupported {
            return "请在真机上点击编辑器，使用键盘上方工具栏中的 OCR 按钮触发系统取词。"
        }
        return "当前环境未检测到可用相机。模拟器无法完成系统取词验收。"
    }

    func updateFocus(isFocused: Bool, field: FocusField) {
        if isFocused {
            focusedField = field
        } else if focusedField == field {
            focusedField = .none
        }
    }
}
#endif
