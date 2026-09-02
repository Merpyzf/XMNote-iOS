/**
 * [INPUT]: 依赖 BookAlignmentDatabaseFixture 与 DEBUG UITestLaunchConfiguration
 * [OUTPUT]: 验证 B0 字节克隆、生产恢复迁移、主机同算法摘要、无事务 checkpoint 以及书籍对齐启动路径
 * [POS]: xmnoteTests/BookAlignment 基础设施测试，私有 B0 缺失时仅跳过同库套件
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import GRDB
import Testing
@testable import xmnote

@MainActor
struct BookAlignmentLaunchConfigurationTests {
    @Test
    func dedicatedBookAlignmentPathWinsAndLegacyParityPathRemainsCompatible() {
        let dedicatedPath = "/private/tmp/book-alignment.db"
        let legacyPath = "/private/tmp/web-parity.db"

        #expect(UITestLaunchConfiguration.resolvedDatabasePath(in: [
            UITestLaunchConfiguration.bookAlignmentDatabasePathEnvironment: "  \(dedicatedPath)  ",
            UITestLaunchConfiguration.webAPIParityDatabasePathEnvironment: legacyPath
        ]) == dedicatedPath)
        #expect(UITestLaunchConfiguration.resolvedDatabasePath(in: [
            UITestLaunchConfiguration.bookAlignmentDatabasePathEnvironment: "   ",
            UITestLaunchConfiguration.webAPIParityDatabasePathEnvironment: " \(legacyPath) "
        ]) == legacyPath)
        #expect(UITestLaunchConfiguration.resolvedDatabasePath(in: [:]) == nil)
        #expect(UITestLaunchConfiguration.argumentValue(
            after: UITestLaunchConfiguration.bookAlignmentSceneArgument,
            in: [
                UITestLaunchConfiguration.bookAlignmentSceneArgument,
                UITestLaunchConfiguration.defaultBookshelfAlignmentScene
            ]
        ) == UITestLaunchConfiguration.defaultBookshelfAlignmentScene)
        #expect(UITestLaunchConfiguration.argumentValue(
            after: UITestLaunchConfiguration.bookAlignmentSceneArgument,
            in: [UITestLaunchConfiguration.bookAlignmentSceneArgument]
        ) == nil)
        #expect(UITestLaunchConfiguration.isBookAlignmentSceneRequested(in: [
            UITestLaunchConfiguration.bookAlignmentSceneArgument,
            UITestLaunchConfiguration.defaultBookshelfAlignmentScene
        ]))
        #expect(!UITestLaunchConfiguration.isBookAlignmentSceneRequested(in: []))
        #expect(UITestLaunchConfiguration.bookAlignmentReplayRequest(in: [
            UITestLaunchConfiguration.bookAlignmentReplayCaseArgument,
            "a-09-soft-vs-hard-delete",
            UITestLaunchConfiguration.bookAlignmentReplayModeArgument,
            "operation"
        ])?.caseID == "a-09-soft-vs-hard-delete")
        #expect(UITestLaunchConfiguration.bookAlignmentReplayRequest(in: [
            UITestLaunchConfiguration.bookAlignmentReplayCaseArgument,
            "a-09-soft-vs-hard-delete"
        ])?.caseID == nil)
    }
}

struct BookAlignmentDigestContractTests {
    @Test
    func foreignKeyDeltaUsesMultisetSemanticsInsteadOfCountOrSetEquality() {
        let baseline = BookAlignmentForeignKeySummary(
            violationCount: 3,
            violationDigests: ["digest-a", "digest-a", "digest-b"],
            setDigest: "baseline-set-digest"
        )
        let after = BookAlignmentForeignKeySummary(
            violationCount: 4,
            violationDigests: ["digest-a", "digest-b", "digest-b", "digest-c"],
            setDigest: "after-set-digest"
        )

        let added = BookAlignmentDatabaseFixture.addedForeignKeyViolationDigests(
            after: after,
            baseline: baseline
        )

        #expect(added == ["digest-b", "digest-c"])
    }
}

@MainActor
struct AppDatabaseCheckpointTests {
    @Test
    func checkpointTruncatesWALWithoutEnteringAWritingTransaction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-alignment-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try AppDatabase(path: directory.appendingPathComponent("checkpoint.db").path)
        try database.dbPool.write { db in
            // SQL 目的：制造一条已提交 WAL 写入，验证 AppDatabase.checkpoint 能在事务外执行并保留数据。
            // 涉及表：test-only alignment_checkpoint_probe；关键过滤：无；时间字段：不参与。
            // 副作用用途：checkpoint 后主库仍可读取该行，且调用不得返回 SQLITE_LOCKED。
            try db.execute(sql: "CREATE TABLE alignment_checkpoint_probe (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO alignment_checkpoint_probe (id) VALUES (1)")
        }

        try database.checkpoint()

        let count = try database.dbPool.read { db in
            // SQL 目的：确认 checkpoint 只合并 WAL，不丢失已提交测试行。
            // 涉及表：test-only alignment_checkpoint_probe；关键过滤：无；时间字段：不参与。
            // 返回用途：证明无事务 checkpoint 完成后的数据库仍可正常读取。
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM alignment_checkpoint_probe") ?? 0
        }
        #expect(count == 1)
    }
}

@Suite(.enabled(
    if: BookAlignmentPrivateBaseline.isAvailable,
    "SKIP: missing private baseline (set XMNOTE_BOOK_ALIGNMENT_BASELINE_PATH or provide artifacts/book-alignment/current/B0.db)"
))
@MainActor
struct BookAlignmentPrivateBaselineTests {
    private static let pixel7aSchemaSHA256 = "fe319f31d096bbee8d1516c3390cf4745077e455e94c3e446b0d36fd55b17dcd"
    private static let pixel7aForeignKeySetDigest = "2d3a51435d496cdabde18d56f5fbb34fffc1908401c6b7f596bba7cd401abc49"

    @Test
    func privateBaselineIsClonedByteForByteBeforeProductionRestoreAndMigration() throws {
        let fixture = try BookAlignmentDatabaseFixture.clonePrivateBaseline()
        defer { fixture.cleanup() }

        #expect(fixture.preOpenCloneSHA256 == fixture.metadata.sha256)
        #expect(fixture.metadata.databaseVersion == 47)
        #expect(fixture.metadata.roomIdentityHash == RoomCanonicalSchemaV47.identityHash)
        #expect(fixture.metadata.sha256.count == 64)
        #expect(fixture.metadata.schemaSHA256 == Self.pixel7aSchemaSHA256)
        #expect(fixture.metadata.foreignKeySummary.violationCount == 116)
        #expect(fixture.metadata.foreignKeySummary.violationDigests.count == 116)
        #expect(fixture.metadata.foreignKeySummary.setDigest == Self.pixel7aForeignKeySetDigest)

        try fixture.database.dbPool.read { db in
            #expect(try RoomCanonicalSchemaV48.hasValidIdentityHash(db))
            try RoomCanonicalSchemaV48.validatePhysicalSchema(db)
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 48)

            // SQL 目的：摘要比较 B0 打开前后的外键违规 multiset，确认 iOS 首次打开没有新增历史异常。
            // 涉及表：全部 Room 实体外键；关键过滤：无；时间字段：不参与。
            // 返回用途：允许旧异常消失，但等量替换仍会产生新 digest；不输出任何原始违规行。
            let postOpenSummary = try BookAlignmentDatabaseFixture.foreignKeySummary(db)
            let addedDigests = BookAlignmentDatabaseFixture.addedForeignKeyViolationDigests(
                after: postOpenSummary,
                baseline: fixture.metadata.foreignKeySummary
            )
            #expect(addedDigests.isEmpty)
        }
    }
}
