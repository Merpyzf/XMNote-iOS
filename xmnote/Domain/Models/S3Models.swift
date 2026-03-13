/**
 * [INPUT]: 依赖 Foundation 提供值类型语义与 URL 表达，承接 S3 配置与上传结果跨层传递
 * [OUTPUT]: 对外提供 S3Config、S3ConfigFormInput、S3UploadResult、S3StorageError 等对象存储领域模型
 * [POS]: Domain/Models 层的 S3 基础设施契约模型，被 Repository、Service 与测试共同消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// S3 配置领域模型，统一承接默认配置与数据库自定义配置的运行时视图。
struct S3Config: Identifiable, Equatable, Sendable {
    let id: Int64
    let bucket: String
    let secretId: String
    let secretKey: String
    let region: String
    let isUsing: Bool
    let isBundledDefault: Bool
}

/// S3 配置表单输入模型，用于新增、编辑与联通性校验时提交凭据。
struct S3ConfigFormInput: Equatable, Sendable {
    let bucket: String
    let secretId: String
    let secretKey: String
    let region: String
}

/// S3 上传结果模型，统一返回对象键与远端访问地址。
struct S3UploadResult: Equatable, Sendable {
    let objectKey: String
    let remoteURL: URL
}

/// S3 运行时错误语义，统一映射配置、上传、取消与 SDK 不可用场景。
enum S3StorageError: LocalizedError, Equatable {
    case noConfigConfigured
    case invalidConfig(message: String)
    case protectedDefaultConfig
    case sdkUnavailable
    case cancelled
    case serviceError(code: Int?, message: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .noConfigConfigured:
            return "未配置可用的 S3 服务"
        case .invalidConfig(let message):
            return message
        case .protectedDefaultConfig:
            return "默认 S3 配置不允许编辑或删除"
        case .sdkUnavailable:
            return "S3 SDK 未完成接入"
        case .cancelled:
            return "上传已取消"
        case .serviceError(_, let message):
            return message
        case .invalidResponse:
            return "S3 响应格式异常"
        }
    }
}

extension S3ConfigFormInput {
    /// 统一收口表单输入的空白裁剪，避免仓储层与 SDK 层重复实现同一规则。
    var normalized: S3ConfigFormInput {
        S3ConfigFormInput(
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            secretId: secretId.trimmingCharacters(in: .whitespacesAndNewlines),
            secretKey: secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
