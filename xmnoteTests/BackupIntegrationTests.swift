import Foundation
import GRDB
import SQLite3
import Testing
import ZIPFoundation
@testable import xmnote

struct BackupIntegrationTests {
    private static let cloudBackupServiceKey = "currCloudBackupService"

    @Test
    func backupFileInfoParsingKeepsAndroidCompatibleMetadata() throws {
        let calendar = Calendar(identifier: .gregorian)
        let backupDate = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 16, hour: 9, minute: 8, second: 7))
        )
        let fileName = BackupArchiveService.makeBackupFileName(
            date: backupDate,
            deviceName: "iPhone 15 / Pro"
        )

        let info = try #require(
            BackupArchiveService.parseBackupFileInfo(
                name: fileName,
                size: 2_048,
                lastModified: nil,
                provider: .aliyunDrive,
                remoteIdentifier: "file-id"
            )
        )

        #expect(info.name == fileName)
        #expect(info.deviceName == "iPhone_15___Pro")
        #expect(info.provider == .aliyunDrive)
        #expect(info.remoteIdentifier == "file-id")
        #expect(info.size == 2_048)
        #expect(info.backupDate == backupDate)
    }

    @Test
    func selectedProviderPersistsAcrossRepositoryReads() async throws {
        let suiteName = "backup.integration.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let database = try AppDatabase.empty()
        let repository = BackupRepository(
            databaseManager: DatabaseManager(database: database),
            serverRepository: StubBackupServerRepository(),
            aliyunDriveProvider: nil,
            userDefaults: userDefaults
        )

        let initialState = try await repository.fetchCloudBackupPageState()
        #expect(initialState.selectedProvider == .aliyunDrive)
        #expect(initialState.isAliyunAuthorized == false)

        try await repository.selectCloudBackupProvider(.webdav)

        let updatedState = try await repository.fetchCloudBackupPageState()
        #expect(updatedState.selectedProvider == .webdav)
        #expect(updatedState.isAliyunAuthorized == false)
        #expect(updatedState.aliyunAccountInfo == nil)
        #expect(updatedState.webdavServer == nil)
        #expect(updatedState.isCurrentProviderAvailable == false)
        #expect(userDefaults.integer(forKey: Self.cloudBackupServiceKey) == CloudBackupProvider.webdav.rawValue)
    }

    @Test
    func webdavBecomesDefaultProviderWhenServerExists() async throws {
        let suiteName = "backup.integration.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let database = try AppDatabase.empty()
        let repository = BackupRepository(
            databaseManager: DatabaseManager(database: database),
            serverRepository: StubBackupServerRepository(
                currentServer: BackupServerRecord(
                    id: 1,
                    title: "坚果云",
                    serverAddress: "https://dav.example.com",
                    account: "tester",
                    password: "secret",
                    isUsing: 1,
                    createdDate: 0,
                    updatedDate: 0,
                    lastSyncDate: 0,
                    isDeleted: 0
                )
            ),
            aliyunDriveProvider: nil,
            userDefaults: userDefaults
        )

        let pageState = try await repository.fetchCloudBackupPageState()
        #expect(pageState.selectedProvider == .webdav)
        #expect(pageState.webdavServer?.title == "坚果云")
        #expect(userDefaults.integer(forKey: Self.cloudBackupServiceKey) == CloudBackupProvider.webdav.rawValue)
    }

    @Test
    func openingAndroidLegacyDatabaseWithOrphanChapterCanOpen() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android_legacy_orphan_\(UUID().uuidString).db")
        defer { Self.removeDatabaseArtifacts(at: databaseURL) }

        try Self.prepareAndroidLegacyDatabase(at: databaseURL.path)
        let appDatabase = try AppDatabase(path: databaseURL.path)

        try appDatabase.dbPool.read { db in
            let chapterRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, book_id, title
                    FROM chapter
                    WHERE id = 21
                    """
            )
            let orphanChapter = try #require(chapterRow)
            #expect(orphanChapter["book_id"] == 378)
            #expect(orphanChapter["title"] == "相逢")

            let ownerRepairMarkerCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM grdb_migrations
                    WHERE identifier = 'v38-owner-repair'
                    """
            ) ?? 0
            #expect(ownerRepairMarkerCount == 0)
        }
    }

    @Test
    func selectingProviderUsesAndroidPreferenceKey() async throws {
        let suiteName = "backup.integration.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let database = try AppDatabase.empty()
        let repository = BackupRepository(
            databaseManager: DatabaseManager(database: database),
            serverRepository: StubBackupServerRepository(),
            aliyunDriveProvider: nil,
            userDefaults: userDefaults
        )

        try await repository.selectCloudBackupProvider(.webdav)
        #expect(userDefaults.integer(forKey: Self.cloudBackupServiceKey) == CloudBackupProvider.webdav.rawValue)
    }

    @Test
    func createBackupArchiveDoesNotDependOnCheckpoint() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup_archive_checkpoint_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let databasePath = temporaryRoot.appendingPathComponent(AppDatabase.databaseName).path
        let appDatabase = try AppDatabase(path: databasePath)
        let service = BackupArchiveService(database: appDatabase)

        var sqlitePointer: OpaquePointer?
        let openResult = sqlite3_open_v2(databasePath, &sqlitePointer, SQLITE_OPEN_READWRITE, nil)
        #expect(openResult == SQLITE_OK)
        defer {
            if let sqlitePointer {
                sqlite3_exec(sqlitePointer, "ROLLBACK;", nil, nil, nil)
                sqlite3_close(sqlitePointer)
            }
        }

        if let sqlitePointer {
            sqlite3_exec(sqlitePointer, "BEGIN IMMEDIATE;", nil, nil, nil)
        }

        let archive = try service.createBackupArchive(in: temporaryRoot)
        #expect(FileManager.default.fileExists(atPath: archive.localFileURL.path))
    }

    @Test
    func createBackupArchiveIncludesExistingSQLiteFileSet() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup_archive_fileset_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let databasePath = temporaryRoot.appendingPathComponent(AppDatabase.databaseName).path
        let appDatabase = try AppDatabase(path: databasePath)
        try appDatabase.dbPool.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS backup_archive_test (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO backup_archive_test (value) VALUES ('sample')")
        }

        let service = BackupArchiveService(database: appDatabase)
        let archiveArtifact = try service.createBackupArchive(in: temporaryRoot)
        let archive = try #require(Archive(url: archiveArtifact.localFileURL, accessMode: .read))

        let archiveEntryNames = Set(archive.map(\.path))
        let existingDatabaseNames = Set(
            appDatabase.databaseFiles
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0).lastPathComponent }
        )

        #expect(archiveEntryNames.contains(AppDatabase.databaseName))
        #expect(existingDatabaseNames.isSubset(of: archiveEntryNames))
    }

    @Test
    func backupSkipsCleaningWhenNoExpiredBackups() async throws {
        let provider = StubCloudBackupRemoteProvider(
            listedBackups: Self.makeBackupFileInfos(count: BackupArchiveService.maxHistoryCount)
        )
        let repository = try Self.makeBackupRepository(provider: provider)
        let progressStore = BackupProgressStore()

        try await repository.backup { progress in
            progressStore.append(progress)
        }

        let progressHistory = progressStore.snapshot()
        #expect(progressHistory.contains(.finalizing) == false)
        #expect(progressHistory.last == .completed)
        #expect(await provider.deletedCount() == 0)
    }

    @Test
    func backupStillCompletesWhenCleanupDeleteFails() async throws {
        let provider = StubCloudBackupRemoteProvider(
            listedBackups: Self.makeBackupFileInfos(count: BackupArchiveService.maxHistoryCount + 1),
            deleteError: NSError(domain: "backup.cleanup", code: 7, userInfo: nil)
        )
        let repository = try Self.makeBackupRepository(provider: provider)
        let progressStore = BackupProgressStore()

        try await repository.backup { progress in
            progressStore.append(progress)
        }

        let progressHistory = progressStore.snapshot()
        #expect(progressHistory.contains(.finalizing))
        #expect(progressHistory.last == .completed)
        #expect(await provider.deleteCallCount() == 1)
    }

    @Test
    @MainActor
    func selectProviderShowsBlockingLoadingImmediately() async {
        let repository = SlowBackupRepository()
        let viewModel = DataBackupViewModel(backupRepository: repository)

        let task = Task { await viewModel.selectProvider(.aliyunDrive) }
        await Task.yield()

        #expect(viewModel.blockingAction == .switchingProvider)

        await task.value
        #expect(viewModel.blockingAction == nil)
    }

    @Test
    @MainActor
    func fetchBackupHistoryShowsBlockingLoadingImmediately() async {
        let repository = SlowBackupRepository()
        let viewModel = DataBackupViewModel(backupRepository: repository)
        viewModel.pageState = CloudBackupPageState(
            selectedProvider: .aliyunDrive,
            webdavServer: nil,
            isAliyunAuthorized: true,
            aliyunAccountInfo: nil,
            aliyunAccountInfoErrorMessage: nil,
            lastBackupDate: nil
        )

        let task = Task { await viewModel.fetchBackupHistory() }
        await Task.yield()

        #expect(viewModel.blockingAction == .fetchingBackupHistory)

        let result = await task.value
        #expect(result == true)
        #expect(viewModel.blockingAction == nil)
        #expect(viewModel.backupList.count == 1)
    }

    @Test
    @MainActor
    func performBackupEntersProgressStateImmediately() async {
        let repository = SlowBackupRepository()
        let viewModel = DataBackupViewModel(backupRepository: repository)
        viewModel.pageState = CloudBackupPageState(
            selectedProvider: .aliyunDrive,
            webdavServer: nil,
            isAliyunAuthorized: true,
            aliyunAccountInfo: nil,
            aliyunAccountInfoErrorMessage: nil,
            lastBackupDate: nil
        )

        let task = Task { await viewModel.performCloudBackup() }
        await Task.yield()

        let isPreparing: Bool
        if case .backingUp(.preparing) = viewModel.operationState {
            isPreparing = true
        } else {
            isPreparing = false
        }
        #expect(isPreparing)

        await task.value
        #expect(viewModel.operationState == .idle)
    }
}

private struct StubBackupServerRepository: BackupServerRepositoryProtocol {
    var currentServer: BackupServerRecord? = nil

    func fetchServers() async throws -> [BackupServerRecord] { [] }
    func fetchCurrentServer() async throws -> BackupServerRecord? { currentServer }
    func saveServer(_ input: BackupServerFormInput, editingServer: BackupServerRecord?) async throws {}
    func delete(_ server: BackupServerRecord) async throws {}
    func select(_ server: BackupServerRecord) async throws {}
    func testConnection(_ input: BackupServerFormInput) async throws {}
}

private final class BackupProgressStore: @unchecked Sendable {
    private let lock = NSLock()
    private var progresses: [BackupProgress] = []

    func append(_ progress: BackupProgress) {
        lock.lock()
        progresses.append(progress)
        lock.unlock()
    }

    func snapshot() -> [BackupProgress] {
        lock.lock()
        defer { lock.unlock() }
        return progresses
    }
}

private actor StubCloudBackupRemoteProvider: CloudBackupRemoteProvider {
    nonisolated let provider: CloudBackupProvider = .webdav

    private let listedBackups: [BackupFileInfo]
    private let deleteError: Error?
    private var deleteCalls: Int = 0

    init(listedBackups: [BackupFileInfo], deleteError: Error? = nil) {
        self.listedBackups = listedBackups
        self.deleteError = deleteError
    }

    func listBackups() async throws -> [BackupFileInfo] {
        listedBackups
    }

    func uploadBackup(
        localFileURL: URL,
        fileName: String,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws {
        progress?(0.4)
        progress?(1)
    }

    func downloadBackup(
        _ backup: BackupFileInfo,
        to localURL: URL,
        progress: (@Sendable (Double?) -> Void)?
    ) async throws {}

    func deleteBackup(_ backup: BackupFileInfo) async throws {
        deleteCalls += 1
        if let deleteError {
            throw deleteError
        }
    }

    func deleteCallCount() -> Int {
        deleteCalls
    }

    func deletedCount() -> Int {
        deleteError == nil ? deleteCalls : 0
    }
}

@MainActor
private final class SlowBackupRepository: BackupRepositoryProtocol {
    private var selectedProvider: CloudBackupProvider = .webdav

    func fetchLastLocalBackupDate() async -> Date? { nil }

    func fetchCloudBackupPageState() async throws -> CloudBackupPageState {
        try await Task.sleep(nanoseconds: 120_000_000)

        var webdavServer: BackupServerRecord?
        if selectedProvider == .webdav {
            var server = BackupServerRecord()
            server.id = 1
            server.title = "坚果云"
            server.serverAddress = "https://dav.example.com"
            server.account = "tester"
            server.password = "secret"
            server.isUsing = 1
            webdavServer = server
        }

        return CloudBackupPageState(
            selectedProvider: selectedProvider,
            webdavServer: webdavServer,
            isAliyunAuthorized: true,
            aliyunAccountInfo: nil,
            aliyunAccountInfoErrorMessage: nil,
            lastBackupDate: nil
        )
    }

    func fetchLatestCloudBackupDate() async throws -> Date? { nil }

    func selectCloudBackupProvider(_ provider: CloudBackupProvider) async throws {
        try await Task.sleep(nanoseconds: 120_000_000)
        selectedProvider = provider
    }

    func authorizeAliyunDrive() async throws {}

    func revokeAliyunDriveAuthorization() async {}

    func prepareLocalExport() async throws -> LocalBackupExportTicket {
        throw BackupError.backupFileCorrupted
    }

    func finalizeLocalExport(_ ticket: LocalBackupExportTicket, succeeded: Bool) async {}

    func prepareLocalImport(from url: URL) async throws -> LocalBackupImportTicket {
        throw BackupError.backupFileCorrupted
    }

    func restoreLocalBackup(
        using ticket: LocalBackupImportTicket,
        progress: (@Sendable (RestoreProgress) -> Void)?
    ) async throws {}

    func discardLocalImport(_ ticket: LocalBackupImportTicket) async {}

    func backup(progress: (@Sendable (BackupProgress) -> Void)?) async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
        progress?(.completed)
    }

    func fetchBackupHistory() async throws -> [BackupFileInfo] {
        try await Task.sleep(nanoseconds: 120_000_000)
        return [
            BackupFileInfo(
                id: "backup-1",
                name: "2026-03-16-10-00-00-iPhone-v3",
                remoteIdentifier: "file-id",
                size: 1024,
                lastModified: Date(),
                deviceName: "iPhone",
                backupDate: Date(),
                provider: .aliyunDrive
            )
        ]
    }

    func restore(_ backup: BackupFileInfo, progress: (@Sendable (RestoreProgress) -> Void)?) async throws {}
}

private extension BackupIntegrationTests {
    nonisolated static func makeBackupRepository(
        provider: StubCloudBackupRemoteProvider
    ) throws -> BackupRepository {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup_repository_\(UUID().uuidString)")
            .appendingPathComponent(AppDatabase.databaseName)
        let database = try AppDatabase(path: databaseURL.path)
        try database.dbPool.write { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS backup_repository_seed (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        value TEXT NOT NULL DEFAULT ''
                    )
                    """
            )
            try db.execute(sql: "INSERT INTO backup_repository_seed (value) VALUES ('seed')")
        }
        return BackupRepository(
            databaseManager: DatabaseManager(database: database),
            serverRepository: StubBackupServerRepository(),
            aliyunDriveProvider: nil,
            remoteProviderFactory: { _, _ in provider }
        )
    }

    nonisolated static func makeBackupFileInfos(count: Int) -> [BackupFileInfo] {
        let now = Date()
        return (0..<count).map { index in
            let backupDate = now.addingTimeInterval(TimeInterval(-index * 60))
            return BackupFileInfo(
                id: "backup-\(index)",
                name: BackupArchiveService.makeBackupFileName(date: backupDate, deviceName: "iPhone"),
                remoteIdentifier: "remote-\(index)",
                size: Int64(1_024 + index),
                lastModified: backupDate,
                deviceName: "iPhone",
                backupDate: backupDate,
                provider: .webdav
            )
        }
    }

    nonisolated static func removeDatabaseArtifacts(at databaseURL: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
        }
    }

    nonisolated static func prepareAndroidLegacyDatabase(at path: String) throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: path, configuration: configuration)

        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = 38")

            try db.execute(sql: """
                CREATE TABLE book (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    user_id INTEGER NOT NULL DEFAULT 0,
                    source_id INTEGER NOT NULL DEFAULT 0,
                    read_status_id INTEGER NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE TABLE chapter (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    book_id INTEGER NOT NULL DEFAULT 0,
                    parent_id INTEGER NOT NULL DEFAULT 0,
                    title TEXT NOT NULL DEFAULT '',
                    remark TEXT NOT NULL DEFAULT '',
                    chapter_order INTEGER NOT NULL DEFAULT 0,
                    is_import INTEGER NOT NULL DEFAULT 0,
                    created_date INTEGER NOT NULL DEFAULT 0,
                    updated_date INTEGER NOT NULL DEFAULT 0,
                    last_sync_date INTEGER NOT NULL DEFAULT 0,
                    is_deleted INTEGER NOT NULL DEFAULT 0,
                    FOREIGN KEY(book_id) REFERENCES book(id)
                )
            """)

            try db.execute(
                sql: """
                    INSERT INTO chapter (id, book_id, parent_id, title, remark, chapter_order, is_import, created_date, updated_date, last_sync_date, is_deleted)
                    VALUES (21, 378, 0, '相逢', '', 0, 0, 1580278862958, 0, 1, 0)
                    """
            )
        }
    }
}
