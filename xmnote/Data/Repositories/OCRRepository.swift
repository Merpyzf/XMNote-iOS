/**
 * [INPUT]: 依赖 OCR 领域模型、BaiduOCRSDKRuntimeBridge 与 UserDefaults，承接 OCR 偏好持久化与 SDK 结果后处理
 * [OUTPUT]: 对外提供 OCRRepository，实现 OCRRepositoryProtocol
 * [POS]: Data 层 OCR 仓储，负责对齐 Android OCRHelper 的文本拼接、标点优化与中英混排策略
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// OCR 仓储，统一管理调试偏好、鉴权缓存与百度 OCR 识别结果加工。
final class OCRRepository: OCRRepositoryProtocol {
    private enum StorageKey {
        static let preferences = "debug.baidu_ocr.preferences"
    }

    private let runtimeBridge: BaiduOCRSDKRuntimeBridge
    private let userDefaults: UserDefaults
    private let defaultPreferences: OCRPreferences
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    init(
        runtimeBridge: BaiduOCRSDKRuntimeBridge,
        userDefaults: UserDefaults = .standard,
        defaultPreferences: OCRPreferences = .default
    ) {
        self.runtimeBridge = runtimeBridge
        self.userDefaults = userDefaults
        self.defaultPreferences = defaultPreferences
    }

    /// 读取 OCR 偏好；若无持久化值则回退到默认配置。
    func fetchPreferences() -> OCRPreferences {
        guard let data = userDefaults.data(forKey: StorageKey.preferences) else {
            return defaultPreferences
        }
        let preferences = (try? jsonDecoder.decode(OCRPreferences.self, from: data)) ?? defaultPreferences
        return mergedWithDefaultCredentialsIfNeeded(preferences)
    }

    /// 覆盖保存 OCR 偏好，供 Debug 页面开关与凭据输入实时持久化。
    func savePreferences(_ preferences: OCRPreferences) {
        guard let data = try? jsonEncoder.encode(preferences) else {
            return
        }
        userDefaults.set(data, forKey: StorageKey.preferences)
    }

    /// 透传到 Runtime Bridge，清除 SDK 内部 token / 鉴权缓存。
    func clearAuthorizationCache() {
        runtimeBridge.clearAuthorizationCache()
    }

    /// 执行 OCR 识别并对输出文本应用 Android 对齐的后处理链路。
    func recognizeText(request: OCRRecognitionRequest) async throws -> OCRRecognitionResult {
        guard request.preferences.credentials.isConfigured else {
            throw OCRRepositoryError.missingCredentials
        }

        do {
            let payload = try await runtimeBridge.recognizeText(
                imageData: request.imageData,
                credentials: request.preferences.credentials,
                language: request.preferences.language,
                isHighPrecision: request.preferences.isHighPrecisionEnabled
            )
            let rawText = extractRecognizedText(from: payload.rawResponse)
            let optimizedText = postProcess(
                text: rawText,
                language: request.preferences.language,
                isPunctuationOptimizationEnabled: request.preferences.isPunctuationOptimizationEnabled,
                isChineseEnglishSpacingOptimizationEnabled: request.preferences.isChineseEnglishSpacingOptimizationEnabled
            )
            let finalText = optimizedText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !finalText.isEmpty else {
                throw OCRRepositoryError.emptyText
            }

            let lines = finalText.split(whereSeparator: \.isNewline)
            let characterCount = finalText.filter { !$0.isWhitespace && !$0.isNewline }.count

            return OCRRecognitionResult(
                text: finalText,
                rawJSON: payload.rawJSON,
                lineCount: lines.count,
                characterCount: characterCount,
                logID: payload.rawResponse["log_id"] as? String
                    ?? (payload.rawResponse["log_id"] as? NSNumber)?.stringValue
            )
        } catch let repositoryError as OCRRepositoryError {
            throw repositoryError
        } catch {
            throw mapRuntimeError(error)
        }
    }
}

private extension OCRRepository {
    func mergedWithDefaultCredentialsIfNeeded(_ preferences: OCRPreferences) -> OCRPreferences {
        let apiKey = preferences.credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = preferences.credentials.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard apiKey.isEmpty,
              secretKey.isEmpty,
              defaultPreferences.credentials.isConfigured else {
            return preferences
        }

        var merged = preferences
        merged.credentials = defaultPreferences.credentials
        return merged
    }

    /// 优先使用 paragraphs_result + words_result_idx 还原段落；若不存在则回退按 words_result 逐行拼接。
    func extractRecognizedText(from rawResponse: [String: Any]) -> String {
        if let paragraphs = rawResponse["paragraphs_result"] as? [[String: Any]],
           let wordsResults = rawResponse["words_result"] as? [[String: Any]],
           !paragraphs.isEmpty {
            let lines = paragraphs.compactMap { paragraph -> String? in
                guard let indexes = paragraph["words_result_idx"] as? [Int] else {
                    return nil
                }
                let text = indexes.compactMap { index -> String? in
                    guard wordsResults.indices.contains(index) else { return nil }
                    return wordsResults[index]["words"] as? String
                }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            if !lines.isEmpty {
                return lines.joined(separator: "\n")
            }
        }

        if let wordsResults = rawResponse["words_result"] as? [[String: Any]] {
            return wordsResults
                .compactMap { $0["words"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        if let wordsResults = rawResponse["words_result"] as? [String: Any] {
            return wordsResults.values
                .compactMap { value in
                    if let item = value as? [String: Any] {
                        return item["words"] as? String
                    }
                    return value as? String
                }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        return ""
    }

    /// 应用 Android OcrHelper 对齐的文本后处理链：标点优化 + 中英混排空格优化。
    func postProcess(
        text: String,
        language: OCRLanguage,
        isPunctuationOptimizationEnabled: Bool,
        isChineseEnglishSpacingOptimizationEnabled: Bool
    ) -> String {
        var processed = text

        if isPunctuationOptimizationEnabled {
            processed = optimizePunctuation(processed, language: language)
        }

        if isChineseEnglishSpacingOptimizationEnabled {
            processed = processed
                .replacingOccurrences(
                    of: #"([\da-zA-Z]+)([\u4e00-\u9fa5]+)"#,
                    with: "$1 $2",
                    options: .regularExpression
                )
                .replacingOccurrences(
                    of: #"([\u4e00-\u9fa5]+)([\da-zA-Z]+)"#,
                    with: "$1 $2",
                    options: .regularExpression
                )
        }

        return processed
    }

    /// 对齐 Android StringHelper.optimizePunctuation，保留中英识别时的中英文语境修正逻辑。
    func optimizePunctuation(_ text: String, language: OCRLanguage) -> String {
        switch language {
        case .chnEng:
            let zhPunctuationText = convertEnglishPunctuationToChinese(in: text)
            return convertChinesePunctuationBetweenASCIIToEnglish(in: zhPunctuationText)
        case .eng:
            return convertChinesePunctuationToEnglish(in: text)
        default:
            return text
        }
    }

    func convertChinesePunctuationBetweenASCIIToEnglish(in text: String) -> String {
        let characters = Array(text)
        guard characters.count > 1 else {
            return text
        }

        var output = characters
        for index in characters.indices {
            let current = characters[index]
            guard let replacement = chineseToEnglishPunctuation[current] else {
                continue
            }
            let previousIndex = index - 1
            guard previousIndex >= 0, isVisibleASCII(characters[previousIndex]) else {
                continue
            }
            if index + 1 >= characters.count || isVisibleASCII(characters[index + 1]) {
                output[index] = replacement
            }
        }
        return String(output)
    }

    func convertChinesePunctuationToEnglish(in text: String) -> String {
        String(text.map { chineseToEnglishPunctuation[$0] ?? $0 })
    }

    func convertEnglishPunctuationToChinese(in text: String) -> String {
        String(text.map { englishToChinesePunctuation[$0] ?? $0 })
    }

    func isVisibleASCII(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        return scalar.value >= 32 && scalar.value <= 126
    }

    var chineseToEnglishPunctuation: [Character: Character] {
        [
            "！": "!",
            "，": ",",
            "。": ".",
            "；": ";",
            "～": "~",
            "《": "<",
            "》": ">",
            "（": "(",
            "）": ")",
            "？": "?",
            "\"": "＂",
            "“": "＂",
            "”": "＂",
            "‘": "'",
            "：": ":",
        ]
    }

    var englishToChinesePunctuation: [Character: Character] {
        [
            "!": "！",
            ",": "，",
            ".": "。",
            ";": "；",
            "~": "～",
            "<": "《",
            ">": "》",
            "(": "（",
            ")": "）",
            "?": "？",
            "'": "‘",
            ":": "：",
        ]
    }

    /// 将 SDK / Runtime 错误归类为调试页可直接展示的业务错误。
    func mapRuntimeError(_ error: Error) -> OCRRepositoryError {
        if let runtimeError = error as? BaiduOCRSDKRuntimeError {
            switch runtimeError {
            case .simulatorUnsupported:
                return .simulatorUnsupported
            case .invalidImageData:
                return .invalidImageData
            case .runtimeUnavailable(let message):
                return .sdkUnavailable(reason: message)
            }
        }

        let nsError = error as NSError
        let message = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()

        if lowered.contains("bundle") || lowered.contains("bundle id") || lowered.contains("bundleid") {
            return .bundleIdentifierMismatch(message: message)
        }

        if lowered.contains("network")
            || lowered.contains("网络")
            || lowered.contains("timeout")
            || lowered.contains("timed out")
            || nsError.domain == NSURLErrorDomain {
            return .networkFailed(message: message)
        }

        if lowered.contains("auth")
            || lowered.contains("token")
            || lowered.contains("apikey")
            || lowered.contains("secret")
            || [14, 17, 18, 19, 110, 111].contains(nsError.code) {
            return .authenticationFailed(message: message)
        }

        return .serviceFailed(message: message.isEmpty ? "百度 OCR 返回了未知错误。" : message)
    }
}

extension OCRRepository {
    static let androidAlignedDebugDefaults: OCRPreferences = {
        let defaults = OCRPreferences.default
        guard let payload = try? OCRDefaultCredentialsPayload.decodeAndroidAlignedDebugPayload() else {
            return defaults
        }

        return OCRPreferences(
            credentials: OCRCredentials(
                apiKey: payload.apiKey,
                secretKey: payload.secretKey
            ),
            language: defaults.language,
            isHighPrecisionEnabled: defaults.isHighPrecisionEnabled,
            isPunctuationOptimizationEnabled: defaults.isPunctuationOptimizationEnabled,
            isChineseEnglishSpacingOptimizationEnabled: defaults.isChineseEnglishSpacingOptimizationEnabled,
            showsCropGrid: defaults.showsCropGrid
        )
    }()
}

private extension OCRRepository {
    struct OCRDefaultCredentialsPayload: Decodable {
        let apiKey: String
        let secretKey: String

        private static let androidEncodedConfig = "657941695958427053325635496a6f67496a673354545272527a42464d33464663475652626c52486445313255454a485753497349434a7a5a574e795a58524c5a586b694f6941694e30526855303555616e46485646637a616a52485a6d56595a315a78565574575131467652314a76565530694948303d"

        static func decodeAndroidAlignedDebugPayload() throws -> OCRDefaultCredentialsPayload {
            let base64String = try decodeHexString(androidEncodedConfig)
            guard let jsonData = Data(base64Encoded: base64String) else {
                throw OCRRepositoryError.sdkUnavailable(reason: "默认 OCR 配置 Base64 解码失败。")
            }
            return try JSONDecoder().decode(OCRDefaultCredentialsPayload.self, from: jsonData)
        }

        static func decodeHexString(_ value: String) throws -> String {
            guard value.count.isMultiple(of: 2) else {
                throw OCRRepositoryError.sdkUnavailable(reason: "默认 OCR 配置格式错误。")
            }

            var bytes: [UInt8] = []
            bytes.reserveCapacity(value.count / 2)
            var index = value.startIndex

            while index < value.endIndex {
                let nextIndex = value.index(index, offsetBy: 2)
                let byteString = value[index..<nextIndex]
                guard let byte = UInt8(byteString, radix: 16) else {
                    throw OCRRepositoryError.sdkUnavailable(reason: "默认 OCR 配置格式错误。")
                }
                bytes.append(byte)
                index = nextIndex
            }

            guard let decoded = String(bytes: bytes, encoding: .utf8) else {
                throw OCRRepositoryError.sdkUnavailable(reason: "默认 OCR 配置格式错误。")
            }
            return decoded
        }
    }
}
