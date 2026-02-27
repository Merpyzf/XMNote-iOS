import Foundation
import Observation

/**
 * [INPUT]: 依赖 DatabaseManager 提供数据库实例，依赖各 Repository 实现完成组装
 * [OUTPUT]: 对外提供 RepositoryContainer，集中暴露业务可用的仓储入口
 * [POS]: App 级依赖注入容器，被视图层通过 Environment 获取并创建 ViewModel
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

@Observable
final class RepositoryContainer {
    let bookRepository: any BookRepositoryProtocol
    let noteRepository: any NoteRepositoryProtocol
    let backupServerRepository: any BackupServerRepositoryProtocol
    let backupRepository: any BackupRepositoryProtocol

    init(databaseManager: DatabaseManager) {
        let backupServerRepository = BackupServerRepository(databaseManager: databaseManager)

        self.bookRepository = BookRepository(databaseManager: databaseManager)
        self.noteRepository = NoteRepository(databaseManager: databaseManager)
        self.backupServerRepository = backupServerRepository
        self.backupRepository = BackupRepository(
            databaseManager: databaseManager,
            serverRepository: backupServerRepository
        )
    }
}
