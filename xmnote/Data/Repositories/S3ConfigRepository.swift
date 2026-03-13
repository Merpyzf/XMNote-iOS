import Foundation
import GRDB

/**
 * [INPUT]: 依赖 AppDatabase 提供 cos_config 表读写，依赖 S3DefaultConfigurationSource 与 S3ObjectStorageServicing 执行默认配置解析和联通性校验
 * [OUTPUT]: 对外提供 S3ConfigRepository（S3ConfigRepositoryProtocol 的实现）
 * [POS]: Data 层 S3 配置仓储，统一封装默认配置映射、自定义配置 CRUD 与连通性测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// S3 配置仓储实现，负责把数据库占位记录解析成真实运行时配置，并承接自定义配置读写。
struct S3ConfigRepository: S3ConfigRepositoryProtocol {
    typealias ClientFactory = (S3ResolvedConfiguration) -> any S3ObjectStorageServicing

    private let databaseManager: DatabaseManager
    private let clientFactory: ClientFactory

    init(
        databaseManager: DatabaseManager,
        clientFactory: @escaping ClientFactory = { S3ObjectStorageService(configuration: $0) }
    ) {
        self.databaseManager = databaseManager
        self.clientFactory = clientFactory
    }

    /// 拉取全部未删除 S3 配置，默认占位记录会被映射为 Android 同源默认配置。
    func fetchConfigs() async throws -> [S3Config] {
        let records = try await databaseManager.database.dbPool.read { db in
            try CosConfigRecord
                .filter(Column("is_deleted") == 0)
                .order(Column("is_using").desc, Column("id").asc)
                .fetchAll(db)
        }

        if records.isEmpty {
            return [try makeBundledDefaultConfig(isUsing: true)]
        }
        return try records.map(resolveConfig(from:))
    }

    /// 读取当前启用的 S3 配置；若数据库未命中，则回退到仓库内置默认配置。
    func fetchCurrentConfig() async throws -> S3Config? {
        if let record = try await databaseManager.database.dbPool.read({ db in
            try CosConfigRecord
                .filter(Column("is_deleted") == 0)
                .filter(Column("is_using") == 1)
                .fetchOne(db)
        }) {
            return try resolveConfig(from: record)
        }
        return try makeBundledDefaultConfig(isUsing: true)
    }

    /// 新增或更新自定义 S3 配置；默认占位配置不允许被编辑覆盖。
    func saveConfig(_ input: S3ConfigFormInput, editingConfig: S3Config?) async throws -> S3Config {
        let normalized = input.normalized
        let resolved = try S3ResolvedConfiguration(input: normalized)
        _ = resolved

        if let editingConfig, editingConfig.isBundledDefault {
            throw S3StorageError.protectedDefaultConfig
        }

        return try await databaseManager.database.dbPool.write { db in
            if let editingConfig, var record = try CosConfigRecord.fetchOne(db, key: editingConfig.id) {
                record.bucket = normalized.bucket
                record.secretId = normalized.secretId
                record.secretKey = normalized.secretKey
                record.region = normalized.region
                record.touchUpdatedDate()
                try record.update(db)
                return try resolveConfig(from: record)
            }

            var record = CosConfigRecord()
            record.bucket = normalized.bucket
            record.secretId = normalized.secretId
            record.secretKey = normalized.secretKey
            record.region = normalized.region
            record.isUsing = 0
            record.touchCreatedDate()
            try record.insert(db)
            return try resolveConfig(from: record)
        }
    }

    /// 删除指定自定义 S3 配置；内置默认配置属于受保护配置，不参与删除。
    func delete(_ config: S3Config) async throws {
        guard !config.isBundledDefault else {
            throw S3StorageError.protectedDefaultConfig
        }

        try await databaseManager.database.dbPool.write { db in
            guard var record = try CosConfigRecord.fetchOne(db, key: config.id) else { return }
            record.markAsDeleted()
            record.isUsing = 0
            try record.update(db)
        }
    }

    /// 切换当前启用的 S3 配置，保证全表最多只有一条启用记录。
    func select(_ config: S3Config) async throws {
        try await databaseManager.database.dbPool.write { db in
            // SQL 目的：清空 cos_config 当前启用标记，保证“当前配置”在事务提交后全表唯一。
            // 过滤条件：对全表执行置零操作，随后仅恢复目标记录的 is_using = 1。
            try db.execute(sql: "UPDATE cos_config SET is_using = 0")

            if let target = try CosConfigRecord.fetchOne(db, key: config.id) {
                var record = target
                record.isUsing = 1
                record.touchUpdatedDate()
                try record.update(db)
                return
            }

            if config.isBundledDefault {
                var record = CosConfigRecord()
                record.id = 1
                record.touchCreatedDate()
                record.isUsing = 1
                try record.insert(db)
            }
        }
    }

    /// 使用表单输入即时验证 S3 兼容网关是否可上传且可删除测试对象。
    func testConnection(_ input: S3ConfigFormInput) async throws {
        let configuration = try S3ResolvedConfiguration(input: input)
        let client = clientFactory(configuration)
        try await client.testConnection()
    }
}

private extension S3ConfigRepository {
    func resolveConfig(from record: CosConfigRecord) throws -> S3Config {
        if record.id == 1 {
            let bundled = try S3DefaultConfigurationSource.load()
            return S3Config(
                id: 1,
                bucket: bundled.bucket,
                secretId: bundled.secretId,
                secretKey: bundled.secretKey,
                region: bundled.region,
                isUsing: record.isUsing == 1,
                isBundledDefault: true
            )
        }

        guard let id = record.id else {
            throw S3StorageError.invalidConfig(message: "S3 配置缺少主键")
        }
        return S3Config(
            id: id,
            bucket: record.bucket,
            secretId: record.secretId,
            secretKey: record.secretKey,
            region: record.region,
            isUsing: record.isUsing == 1,
            isBundledDefault: false
        )
    }

    func makeBundledDefaultConfig(isUsing: Bool) throws -> S3Config {
        let bundled = try S3DefaultConfigurationSource.load()
        return S3Config(
            id: 1,
            bucket: bundled.bucket,
            secretId: bundled.secretId,
            secretKey: bundled.secretKey,
            region: bundled.region,
            isUsing: isUsing,
            isBundledDefault: true
        )
    }
}
