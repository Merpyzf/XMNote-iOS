import Foundation
import Observation

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库实例，依赖各 Repository 实现完成组装
 * [OUTPUT]: 对外提供 RepositoryContainer，集中暴露业务可用的仓储入口（含阅读日历封面取色仓储）
 * [POS]: App 级依赖注入容器，被视图层通过 Environment 获取并创建 ViewModel
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@Observable
final class RepositoryContainer {
    let bookRepository: any BookRepositoryProtocol
    let noteRepository: any NoteRepositoryProtocol
    let backupServerRepository: any BackupServerRepositoryProtocol
    let backupRepository: any BackupRepositoryProtocol
    let statisticsRepository: any StatisticsRepositoryProtocol
    let coverImageLoader: any XMCoverImageLoading
    let readCalendarColorRepository: any ReadCalendarColorRepositoryProtocol

    /// 在应用启动阶段一次性组装所有仓储依赖，并注入共享数据库管理器。
    init(databaseManager: DatabaseManager) {
        let backupServerRepository = BackupServerRepository(databaseManager: databaseManager)

        self.bookRepository = BookRepository(databaseManager: databaseManager)
        self.noteRepository = NoteRepository(databaseManager: databaseManager)
        self.backupServerRepository = backupServerRepository
        self.backupRepository = BackupRepository(
            databaseManager: databaseManager,
            serverRepository: backupServerRepository
        )
        self.statisticsRepository = StatisticsRepository(databaseManager: databaseManager)
        self.coverImageLoader = NukeCoverImageLoader()
        self.readCalendarColorRepository = ReadCalendarColorRepository(imageLoader: coverImageLoader)
    }
}
