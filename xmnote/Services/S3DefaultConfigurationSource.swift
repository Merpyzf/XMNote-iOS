/**
 * [INPUT]: 依赖 Foundation 与 S3 领域模型，承接 Android 默认配置的同源编码串
 * [OUTPUT]: 对外提供 S3DefaultConfigurationSource，解析仓库内置的默认 S3 配置
 * [POS]: Services 模块的默认 S3 配置来源，被 S3ConfigRepository 用作默认占位记录的真实配置映射
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// Android 同源的默认 S3 配置来源，负责把仓库中的编码串还原成运行时配置。
enum S3DefaultConfigurationSource {
    private static let encodedConfig = "65794169596e566a61325630496a6f67496e6874626d39305a5330784d6a55794e44457a4e54417949697767496e4e6c59334a6c64456c6b496a6f67496b464c53555131656d5678636d68585a334a76576a565761336c6a526d5a316432705351576b784e7a527464466c595443497349434a7a5a574e795a58524c5a586b694f6941696245316f646e5a6f52564e56536e4e46556c705a576b6c30534642486330564b5547567062474e4a626a4d694c434169636d566e61573975496a6f67496d46774c584e6f5957356e6147467049694239"

    /// 解析仓库内置的默认 S3 配置；若配置串损坏则抛出 invalidConfig。
    static func load() throws -> S3ConfigFormInput {
        let base64String = try decodeHexString(encodedConfig)
        guard let jsonData = Data(base64Encoded: base64String) else {
            throw S3StorageError.invalidConfig(message: "默认 S3 配置 Base64 解码失败")
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: jsonData)
            return S3ConfigFormInput(
                bucket: payload.bucket,
                secretId: payload.secretId,
                secretKey: payload.secretKey,
                region: payload.region
            )
        } catch {
            throw S3StorageError.invalidConfig(message: "默认 S3 配置解析失败")
        }
    }
}

private extension S3DefaultConfigurationSource {
    struct Payload: Decodable {
        let bucket: String
        let secretId: String
        let secretKey: String
        let region: String
    }

    /// 执行decodeHexString对应的数据处理步骤，并返回当前流程需要的结果。
    static func decodeHexString(_ value: String) throws -> String {
        guard value.count.isMultiple(of: 2) else {
            throw S3StorageError.invalidConfig(message: "默认 S3 配置格式错误")
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex

        while index < value.endIndex {
            let nextIndex = value.index(index, offsetBy: 2)
            let byteString = value[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw S3StorageError.invalidConfig(message: "默认 S3 配置格式错误")
            }
            bytes.append(byte)
            index = nextIndex
        }

        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw S3StorageError.invalidConfig(message: "默认 S3 配置格式错误")
        }
        return string
    }
}
