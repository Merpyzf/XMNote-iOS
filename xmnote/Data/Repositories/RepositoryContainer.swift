import Foundation
import Observation

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库实例，依赖统一会员权益与各 Repository 实现与可注入 UserDefaults 完成生产或 Debug 隔离组装
 * [OUTPUT]: 对外提供 RepositoryContainer，集中暴露业务仓储，并在 Debug 提供 Sheet 数据副本的隔离组装入口
 * [POS]: App 级依赖注入容器，被视图层通过 Environment 获取并创建 ViewModel
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@Observable
/// 仓储依赖容器，在应用启动时一次性组装各业务仓储。
final class RepositoryContainer {
    let membershipRepository: any MembershipRepositoryProtocol
    let premiumNoteImportRepository: any NoteImportRepositoryProtocol
    let bookRepository: any BookRepositoryProtocol
    let noteRepository: any NoteRepositoryProtocol
    let contentRepository: any ContentRepositoryProtocol
    let aiRepository: any AIRepositoryProtocol
    let chapterManagementRepository: any ChapterManagementRepositoryProtocol
    let globalSearchRepository: any GlobalSearchRepositoryProtocol
    let bookSearchRepository: any BookSearchRepositoryProtocol
    let bookEditorRepository: any BookEditorRepositoryProtocol
    let ocrRepository: any OCRRepositoryProtocol
    let backupServerRepository: any BackupServerRepositoryProtocol
    let backupRepository: any BackupRepositoryProtocol
    let s3ConfigRepository: any S3ConfigRepositoryProtocol
    let s3UploadRepository: any S3UploadRepositoryProtocol
    let appBackendConfigRepository: any AppBackendConfigRepositoryProtocol
    let noteImageUploadQuotaRepository: any NoteImageUploadQuotaRepositoryProtocol
    let tagSelectionLayoutPreferenceRepository: any TagSelectionLayoutPreferenceRepositoryProtocol
    let tagManagementRepository: any TagManagementRepositoryProtocol
    let externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol
    let bookGroupManagementRepository: any BookGroupManagementRepositoryProtocol
    let sourceManagementRepository: any SourceManagementRepositoryProtocol
    let statisticsRepository: any StatisticsRepositoryProtocol
    let readCalendarRepository: any ReadCalendarRepositoryProtocol
    let bookReadingDetailRepository: any BookReadingDetailRepositoryProtocol
    let readingDashboardRepository: any ReadingDashboardRepositoryProtocol
    let readingTimerRepository: any ReadingTimerRepositoryProtocol
    let coverImageLoader: any XMCoverImageLoading
    let readCalendarColorRepository: any ReadCalendarColorRepositoryProtocol
    let timelineRepository: any TimelineRepositoryProtocol
    let wereadImportRepository: any WereadImportRepositoryProtocol
    let noteImportRepository: any NoteImportRepositoryProtocol

    /// 在应用启动阶段一次性组装所有仓储依赖，并注入共享数据库管理器。
    convenience init(databaseManager: DatabaseManager) {
        self.init(databaseManager: databaseManager, userDefaults: .standard)
    }

    #if DEBUG
    /// 为 Sheet 校准页组装数据库与轻量偏好均隔离的生产仓储集合。
    convenience init(
        sheetPreviewDatabaseManager databaseManager: DatabaseManager,
        userDefaults: UserDefaults
    ) {
        self.init(databaseManager: databaseManager, userDefaults: userDefaults)
    }
    #endif

    /// 集中组装可注入轻量偏好的仓储；生产固定使用标准容器，Debug 快照传入临时 suite。
    private init(databaseManager: DatabaseManager, userDefaults: UserDefaults) {
        let membership = MembershipRepository.shared
        self.membershipRepository = membership
        self.premiumNoteImportRepository = NoteImportRepository(
            databaseManager: databaseManager, defaults: userDefaults, requiredMembership: membership
        )
        let backupServerRepository = BackupServerRepository(databaseManager: databaseManager)
        let aliyunDriveProvider = try? AliyunDriveBackupRemoteProvider(
            configuration: AliyunDriveOpenPlatformConfiguration()
        )
        let s3ConfigRepository = S3ConfigRepository(databaseManager: databaseManager)
        let s3UploadRepository = S3UploadRepository(configRepository: s3ConfigRepository)
        let appBackendConfigRepository = AppBackendConfigRepository(userDefaults: userDefaults)
        let bookRemoteSearchService = BookRemoteSearchService()
        let noteImageUploadQuotaRepository = NoteImageUploadQuotaRepository(
            configRepository: s3ConfigRepository,
            appBackendConfigRepository: appBackendConfigRepository,
            userDefaults: userDefaults
        )
        let coverImageLoader = NukeCoverImageLoader()
        let bookSearchRepository = BookSearchRepository(
            service: bookRemoteSearchService,
            userDefaults: userDefaults
        )
        let defaultOCRPreferences = OCRRepository.androidAlignedDebugDefaults

        let noteRepository = NoteRepository(
            databaseManager: databaseManager,
            userDefaults: userDefaults,
            s3UploadRepository: s3UploadRepository,
            noteReviewSettingStore: NoteReviewSettingStore(defaults: userDefaults)
        )
        self.bookRepository = BookRepository(
            databaseManager: databaseManager,
            displaySettingStore: BookshelfDisplaySettingStore(defaults: userDefaults),
            bookCollectionDisplaySettingStore: BookCollectionDisplaySettingStore(defaults: userDefaults)
        )
        self.noteRepository = noteRepository
        self.contentRepository = ContentRepository(
            databaseManager: databaseManager,
            userDefaults: userDefaults
        )
        self.aiRepository = AIRepository(
            databaseManager: databaseManager,
            noteRepository: noteRepository
        )
        self.chapterManagementRepository = ChapterManagementRepository(
            databaseManager: databaseManager,
            remoteSearchService: bookRemoteSearchService,
            appBackendConfigRepository: appBackendConfigRepository
        )
        self.globalSearchRepository = GlobalSearchRepository(
            databaseManager: databaseManager,
            userDefaults: userDefaults
        )
        self.tagSelectionLayoutPreferenceRepository = TagSelectionLayoutPreferenceRepository(
            defaults: userDefaults
        )
        self.tagManagementRepository = TagManagementRepository(databaseManager: databaseManager)
        self.externalAppIntegrationRepository = ExternalAppIntegrationRepository(
            databaseManager: databaseManager,
            settingStore: ExternalAppIntegrationSettingStore(defaults: userDefaults)
        )
        self.bookGroupManagementRepository = BookGroupManagementRepository(databaseManager: databaseManager)
        self.sourceManagementRepository = SourceManagementRepository(databaseManager: databaseManager)
        self.bookSearchRepository = bookSearchRepository
        self.bookEditorRepository = BookEditorRepository(
            databaseManager: databaseManager,
            userDefaults: userDefaults,
            s3UploadRepository: s3UploadRepository,
            coverImageLoader: coverImageLoader
        )
        self.ocrRepository = OCRRepository(
            runtimeBridge: BaiduOCRSDKRuntimeBridge(),
            userDefaults: userDefaults,
            defaultPreferences: defaultOCRPreferences
        )
        self.backupServerRepository = backupServerRepository
        self.backupRepository = BackupRepository(
            databaseManager: databaseManager,
            serverRepository: backupServerRepository,
            aliyunDriveProvider: aliyunDriveProvider,
            userDefaults: userDefaults
        )
        self.s3ConfigRepository = s3ConfigRepository
        self.s3UploadRepository = s3UploadRepository
        self.appBackendConfigRepository = appBackendConfigRepository
        self.noteImageUploadQuotaRepository = noteImageUploadQuotaRepository
        self.statisticsRepository = StatisticsRepository(databaseManager: databaseManager)
        self.readCalendarRepository = ReadCalendarRepository(databaseManager: databaseManager)
        self.bookReadingDetailRepository = BookReadingDetailRepository(
            databaseManager: databaseManager,
            settingStore: BookReadingDetailSettingStore(defaults: userDefaults)
        )
        self.readingDashboardRepository = ReadingDashboardRepository(databaseManager: databaseManager)
        self.readingTimerRepository = ReadingTimerRepository(
            databaseManager: databaseManager,
            userDefaults: userDefaults
        )
        self.coverImageLoader = coverImageLoader
        self.readCalendarColorRepository = ReadCalendarColorRepository(imageLoader: coverImageLoader)
        self.timelineRepository = TimelineRepository(databaseManager: databaseManager)
        self.wereadImportRepository = WereadImportRepository(
            databaseManager: databaseManager,
            defaults: userDefaults,
            bookSearchRepository: bookSearchRepository,
            s3UploadRepository: s3UploadRepository
        )
        self.noteImportRepository = NoteImportRepository(
            databaseManager: databaseManager,
            defaults: userDefaults,
            bookSearchRepository: bookSearchRepository
        )
    }
}
