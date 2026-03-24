/**
 * [INPUT]: 依赖 OCR 领域模型、UIKit 与 Objective-C Runtime 调用桥，承接百度 OCR SDK 的 Swift 异步封装
 * [OUTPUT]: 对外提供 BaiduOCRSDKRuntimeBridge，负责 SDK 加载、鉴权与原始结果回传
 * [POS]: Infra/BaiduOCR 的 Swift Bridge，将 Objective-C callback 风格能力转换为仓储层可消费的 async 能力
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import UIKit

/// 百度 OCR Runtime Bridge 原始响应载体，保留字典与 JSON 字符串供仓储层进一步加工。
struct BaiduOCRRuntimePayload {
    let rawResponse: [String: Any]
    let rawJSON: String
}

/// SDK 桥接错误，统一处理图片解码、模拟器不可用与 framework 动态加载失败。
enum BaiduOCRSDKRuntimeError: LocalizedError {
    case simulatorUnsupported
    case invalidImageData
    case runtimeUnavailable(message: String)

    var errorDescription: String? {
        switch self {
        case .simulatorUnsupported:
            return "百度 OCR SDK 当前仅支持真机环境。"
        case .invalidImageData:
            return "裁切后的图片数据无效，无法提交到百度 OCR。"
        case .runtimeUnavailable(let message):
            return message
        }
    }
}

/// Swift async 包装层，隔离 Objective-C selector 调用与仓储层文本后处理逻辑。
final class BaiduOCRSDKRuntimeBridge {
    private var lastAuthenticatedCredentials: OCRCredentials?

    /// 清理缓存并重置桥接层凭据快照，便于 Debug 页面验证切换与恢复路径。
    func clearAuthorizationCache() {
        #if !targetEnvironment(simulator)
        XMBaiduOCRRuntimeInvoker.clearCache()
        #endif
        lastAuthenticatedCredentials = nil
    }

    /// 执行百度 OCR 文本识别，并返回原始响应字典与 JSON。
    func recognizeText(
        imageData: Data,
        credentials: OCRCredentials,
        language: OCRLanguage,
        isHighPrecision: Bool
    ) async throws -> BaiduOCRRuntimePayload {
        #if targetEnvironment(simulator)
        throw BaiduOCRSDKRuntimeError.simulatorUnsupported
        #else
        guard let image = UIImage(data: imageData) else {
            throw BaiduOCRSDKRuntimeError.invalidImageData
        }

        do {
            try XMBaiduOCRRuntimeInvoker.loadEmbeddedFrameworks()
        } catch {
            throw BaiduOCRSDKRuntimeError.runtimeUnavailable(message: error.localizedDescription)
        }

        try authenticateIfNeeded(credentials: credentials)

        let options = [
            "language_type": language.rawValue,
            "detect_direction": "true",
            "paragraph": "true",
        ]

        return try await withCheckedThrowingContinuation { continuation in
            XMBaiduOCRRuntimeInvoker.recognizeText(
                from: image,
                highPrecision: isHighPrecision,
                options: options,
                success: { result in
                    let jsonData = try? JSONSerialization.data(
                        withJSONObject: result,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    let rawJSON = jsonData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    continuation.resume(
                        returning: BaiduOCRRuntimePayload(
                            rawResponse: result,
                            rawJSON: rawJSON
                        )
                    )
                },
                failure: { error in
                    continuation.resume(throwing: error)
                }
            )
        }
        #endif
    }

    private func authenticateIfNeeded(credentials: OCRCredentials) throws {
        guard lastAuthenticatedCredentials != credentials else {
            return
        }

        XMBaiduOCRRuntimeInvoker.clearCache()
        do {
            try XMBaiduOCRRuntimeInvoker.authenticate(
                apiKey: credentials.apiKey,
                secretKey: credentials.secretKey
            )
        } catch {
            throw BaiduOCRSDKRuntimeError.runtimeUnavailable(message: error.localizedDescription)
        }
        lastAuthenticatedCredentials = credentials
    }
}
