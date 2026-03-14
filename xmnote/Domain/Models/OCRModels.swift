/**
 * [INPUT]: 依赖 Foundation 提供值类型与错误语义，承接 OCR 调试页与仓储层共享的数据契约
 * [OUTPUT]: 对外提供 OCRLanguage、OCRCredentials、OCRPreferences、OCRRecognitionRequest、OCRRecognitionResult、OCRRepositoryError 六类 OCR 领域模型
 * [POS]: Domain 层 OCR 共享模型，统一描述 SDK 调试页所需的参数、结果与错误语义
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// OCR 语言枚举，对齐 Android 端现有的百度 OCR 语言档位。
enum OCRLanguage: String, CaseIterable, Identifiable, Codable {
    case chnEng = "CHN_ENG"
    case eng = "ENG"
    case por = "POR"
    case fre = "FRE"
    case ger = "GER"
    case ita = "ITA"
    case spa = "SPA"
    case rus = "RUS"
    case jap = "JAP"
    case kor = "KOR"

    var id: String { rawValue }

    /// 返回调试页展示用的中文标题，保持与 Android 设置页语义一致。
    var title: String {
        switch self {
        case .chnEng:
            return "中英混合"
        case .eng:
            return "英文"
        case .por:
            return "葡萄牙语"
        case .fre:
            return "法语"
        case .ger:
            return "德语"
        case .ita:
            return "意大利语"
        case .spa:
            return "西班牙语"
        case .rus:
            return "俄语"
        case .jap:
            return "日语"
        case .kor:
            return "韩语"
        }
    }
}

/// 百度 OCR 凭据输入，Debug 页面通过 UserDefaults 持久化。
struct OCRCredentials: Equatable, Codable {
    var apiKey: String
    var secretKey: String

    /// 当前凭据是否已达到最小可识别条件。
    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// OCR 调试页偏好集合，对齐 Android OCRSettingViewModel 的开关项。
struct OCRPreferences: Equatable, Codable {
    var credentials: OCRCredentials
    var language: OCRLanguage
    var isHighPrecisionEnabled: Bool
    var isPunctuationOptimizationEnabled: Bool
    var isChineseEnglishSpacingOptimizationEnabled: Bool
    var showsCropGrid: Bool

    static let `default` = OCRPreferences(
        credentials: OCRCredentials(apiKey: "", secretKey: ""),
        language: .chnEng,
        isHighPrecisionEnabled: false,
        isPunctuationOptimizationEnabled: true,
        isChineseEnglishSpacingOptimizationEnabled: true,
        showsCropGrid: true
    )
}

/// OCR 识别请求，包含裁切后的图像数据与当前生效偏好。
struct OCRRecognitionRequest {
    let imageData: Data
    let preferences: OCRPreferences
}

/// OCR 识别结果，供调试页同时展示文本预览、统计与原始响应。
struct OCRRecognitionResult {
    let text: String
    let rawJSON: String
    let lineCount: Int
    let characterCount: Int
    let logID: String?
}

/// OCR 仓储错误，统一抽象 SDK、鉴权与网络层异常。
enum OCRRepositoryError: LocalizedError {
    case missingCredentials
    case invalidImageData
    case emptyText
    case simulatorUnsupported
    case sdkUnavailable(reason: String)
    case authenticationFailed(message: String)
    case networkFailed(message: String)
    case bundleIdentifierMismatch(message: String)
    case serviceFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "请先填写百度 OCR 的 API Key 和 Secret Key。"
        case .invalidImageData:
            return "当前图片无法转换为可识别的数据，请重新选择图片后再试。"
        case .emptyText:
            return "未从图片中识别出文本信息。"
        case .simulatorUnsupported:
            return "百度 OCR SDK 当前仅在真机 Debug 构建下可用。"
        case .sdkUnavailable(let reason):
            return reason
        case .authenticationFailed(let message):
            return "鉴权失败：\(message)"
        case .networkFailed(let message):
            return "网络异常：\(message)"
        case .bundleIdentifierMismatch(let message):
            return "Bundle ID 未匹配百度 OCR 控制台配置：\(message)"
        case .serviceFailed(let message):
            return message
        }
    }
}
