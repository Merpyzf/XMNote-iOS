import Foundation
import Observation

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库实例，依赖各 Repository 实现完成组装
 * [OUTPUT]: 对外提供 RepositoryContainer，集中暴露业务可用的仓储入口（含书籍搜索与录入仓储、S3 配置与上传仓储、阅读首页、阅读日历封面取色与时间线仓储）
 * [POS]: App 级依赖注入容器，被视图层通过 Environment 获取并创建 ViewModel
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@Observable
/// 仓储依赖容器，在应用启动时一次性组装各业务仓储。
final class RepositoryContainer {
    let bookRepository: any BookRepositoryProtocol
    let noteRepository: any NoteRepositoryProtocol
    let bookSearchRepository: any BookSearchRepositoryProtocol
    let bookEditorRepository: any BookEditorRepositoryProtocol
    let ocrRepository: any OCRRepositoryProtocol
    let backupServerRepository: any BackupServerRepositoryProtocol
    let backupRepository: any BackupRepositoryProtocol
    let s3ConfigRepository: any S3ConfigRepositoryProtocol
    let s3UploadRepository: any S3UploadRepositoryProtocol
    let statisticsRepository: any StatisticsRepositoryProtocol
    let readingDashboardRepository: any ReadingDashboardRepositoryProtocol
    let coverImageLoader: any XMCoverImageLoading
    let readCalendarColorRepository: any ReadCalendarColorRepositoryProtocol
    let timelineRepository: any TimelineRepositoryProtocol

    /// 在应用启动阶段一次性组装所有仓储依赖，并注入共享数据库管理器。
    init(databaseManager: DatabaseManager) {
        let backupServerRepository = BackupServerRepository(databaseManager: databaseManager)
        let s3ConfigRepository = S3ConfigRepository(databaseManager: databaseManager)
        #if DEBUG
        let defaultOCRPreferences = OCRRepository.androidAlignedDebugDefaults
        #else
        let defaultOCRPreferences = OCRPreferences.default
        #endif

        self.bookRepository = BookRepository(databaseManager: databaseManager)
        self.noteRepository = NoteRepository(databaseManager: databaseManager)
        self.bookSearchRepository = BookSearchRepository()
        self.bookEditorRepository = BookEditorRepository(databaseManager: databaseManager)
        self.ocrRepository = OCRRepository(
            runtimeBridge: BaiduOCRSDKRuntimeBridge(),
            defaultPreferences: defaultOCRPreferences
        )
        self.backupServerRepository = backupServerRepository
        self.backupRepository = BackupRepository(
            databaseManager: databaseManager,
            serverRepository: backupServerRepository
        )
        self.s3ConfigRepository = s3ConfigRepository
        self.s3UploadRepository = S3UploadRepository(configRepository: s3ConfigRepository)
        self.statisticsRepository = StatisticsRepository(databaseManager: databaseManager)
        self.readingDashboardRepository = ReadingDashboardRepository(databaseManager: databaseManager)
        self.coverImageLoader = NukeCoverImageLoader()
        self.readCalendarColorRepository = ReadCalendarColorRepository(imageLoader: coverImageLoader)
        self.timelineRepository = TimelineRepository(databaseManager: databaseManager)
    }
}
