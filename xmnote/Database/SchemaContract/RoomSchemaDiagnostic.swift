/**
 * [INPUT]: 接收 Room v40 schema 校验过程中定位到的表、字段、索引和外键差异
 * [OUTPUT]: 对外提供 RoomSchemaDiagnostic，用于生成可定位的数据库结构错误说明
 * [POS]: Database/SchemaContract 的诊断模型，被 RoomCanonicalSchemaV40 物理结构校验使用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 描述 iOS staging 库与 Android Room schema 合同之间的首个物理结构差异。
nonisolated struct RoomSchemaDiagnostic: Equatable, CustomStringConvertible {
    let tableName: String?
    let objectName: String?
    let detail: String

    var description: String {
        [tableName, objectName, detail]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " / ")
    }
}
