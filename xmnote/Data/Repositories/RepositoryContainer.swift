import Foundation
import Observation

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库实例，依赖各 Repository 实现完成组装
 * [OUTPUT]: 对外提供 RepositoryContainer，集中暴露目录、搜索录入、AI、S3、图片额度、备份、标签、书籍分组、阅读首页/计时/日历/单书详情与外部应用集成仓储
 * [POS]: App 级依赖注入容器，被视图层通过 Environment 获取并创建 ViewModel
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@Observable
/// 仓储依赖容器，在应用启动时一次性组装各业务仓储。
final class RepositoryContainer {
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
    let tagManagementRepository: any TagManagementRepositoryProtocol
    let externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol
    let bookGroupManagementRepository: any BookGroupManagementRepositoryProtocol
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
    init(databaseManager: DatabaseManager) {
        let backupServerRepository = BackupServerRepository(databaseManager: databaseManager)
        let aliyunDriveProvider = try? AliyunDriveBackupRemoteProvider(
            configuration: AliyunDriveOpenPlatformConfiguration()
        )
        let s3ConfigRepository = S3ConfigRepository(databaseManager: databaseManager)
        let s3UploadRepository = S3UploadRepository(configRepository: s3ConfigRepository)
        let appBackendConfigRepository = AppBackendConfigRepository()
        let bookRemoteSearchService = BookRemoteSearchService()
        let noteImageUploadQuotaRepository = NoteImageUploadQuotaRepository(
            configRepository: s3ConfigRepository,
            appBackendConfigRepository: appBackendConfigRepository
        )
        let coverImageLoader = NukeCoverImageLoader()
        let bookSearchRepository = BookSearchRepository(service: bookRemoteSearchService)
        let defaultOCRPreferences = OCRRepository.androidAlignedDebugDefaults

        let noteRepository = NoteRepository(
            databaseManager: databaseManager,
            s3UploadRepository: s3UploadRepository
        )
        self.bookRepository = BookRepository(databaseManager: databaseManager)
        self.noteRepository = noteRepository
        self.contentRepository = ContentRepository(databaseManager: databaseManager)
        self.aiRepository = AIRepository(
            databaseManager: databaseManager,
            noteRepository: noteRepository
        )
        self.chapterManagementRepository = ChapterManagementRepository(
            databaseManager: databaseManager,
            remoteSearchService: bookRemoteSearchService,
            appBackendConfigRepository: appBackendConfigRepository
        )
        self.globalSearchRepository = GlobalSearchRepository(databaseManager: databaseManager)
        self.tagManagementRepository = TagManagementRepository(databaseManager: databaseManager)
        self.externalAppIntegrationRepository = ExternalAppIntegrationRepository(databaseManager: databaseManager)
        self.bookGroupManagementRepository = BookGroupManagementRepository(databaseManager: databaseManager)
        self.bookSearchRepository = bookSearchRepository
        self.bookEditorRepository = BookEditorRepository(
            databaseManager: databaseManager,
            s3UploadRepository: s3UploadRepository,
            coverImageLoader: coverImageLoader
        )
        self.ocrRepository = OCRRepository(
            runtimeBridge: BaiduOCRSDKRuntimeBridge(),
            defaultPreferences: defaultOCRPreferences
        )
        self.backupServerRepository = backupServerRepository
        self.backupRepository = BackupRepository(
            databaseManager: databaseManager,
            serverRepository: backupServerRepository,
            aliyunDriveProvider: aliyunDriveProvider
        )
        self.s3ConfigRepository = s3ConfigRepository
        self.s3UploadRepository = s3UploadRepository
        self.appBackendConfigRepository = appBackendConfigRepository
        self.noteImageUploadQuotaRepository = noteImageUploadQuotaRepository
        self.statisticsRepository = StatisticsRepository(databaseManager: databaseManager)
        self.readCalendarRepository = ReadCalendarRepository(databaseManager: databaseManager)
        self.bookReadingDetailRepository = BookReadingDetailRepository(databaseManager: databaseManager)
        self.readingDashboardRepository = ReadingDashboardRepository(databaseManager: databaseManager)
        self.readingTimerRepository = ReadingTimerRepository(databaseManager: databaseManager)
        self.coverImageLoader = coverImageLoader
        self.readCalendarColorRepository = ReadCalendarColorRepository(imageLoader: coverImageLoader)
        self.timelineRepository = TimelineRepository(databaseManager: databaseManager)
        self.wereadImportRepository = WereadImportRepository(
            databaseManager: databaseManager,
            bookSearchRepository: bookSearchRepository,
            s3UploadRepository: s3UploadRepository
        )
        self.noteImportRepository = NoteImportRepository(
            databaseManager: databaseManager,
            bookSearchRepository: bookSearchRepository
        )
    }
}
