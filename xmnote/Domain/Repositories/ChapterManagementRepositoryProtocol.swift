/**
 * [INPUT]: 依赖 ChapterManagementModels/ChapterBatchImportModels 定义目录快照、批量草稿、结构恢复与业务错误
 * [OUTPUT]: 对外提供 ChapterManagementRepositoryProtocol，约束章节树观察、远端目录发现、批量导入及可撤销原子写入能力
 * [POS]: Domain/Repositories 的书内目录管理仓储契约，由 Data 实现并注入 Book 模块
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 章节管理仓储契约；所有本地数据读写必须通过该接口进入数据库事务。
protocol ChapterManagementRepositoryProtocol {
    /// 观察单本书的完整章节树与书摘计数；流由页面退出时取消。
    func observeSnapshot(bookID: Int64) -> AsyncThrowingStream<ChapterManagementSnapshot, Error>

    /// 按 Android 规则发现文曲目录：优先豆瓣 ID 精确查询，否则按本地书名返回候选。
    func discoverRemoteCatalog(bookID: Int64) async throws -> ChapterRemoteCatalogDiscovery

    /// 获取并缓存独立的 WENQU-CONFIG；该状态不得阻塞或改变目录 API 的请求结果。
    func fetchRemoteConfigurationState() async -> ChapterRemoteConfigurationState

    /// 将用户选中的远端一级目录按原始顺序事务导入；同名根章节复用并移动到导入区末尾。
    func importRemoteCatalog(bookID: Int64, titles: [String]) async throws -> ChapterRemoteImportResult

    /// 按手工录入草稿的先序结构原子导入最多五级目录，并保留 Android 目录导入元数据。
    func importChapterBatch(
        bookID: Int64,
        draft: ChapterBatchImportDraft
    ) async throws -> ChapterBatchImportResult

    /// 在根目录或指定父章节末尾新增章节，并返回数据库主键。
    func createChapter(bookID: Int64, parentID: Int64, title: String) async throws -> Int64

    /// 重命名单个有效章节，并同步刷新自身及后代路径元数据。
    func renameChapter(bookID: Int64, chapterID: Int64, title: String) async throws

    /// 更新章节星标；未指定章节不参与星标。
    func setChapterStarred(bookID: Int64, chapterID: Int64, isStarred: Bool) async throws

    /// 以完整同级 ID 顺序原子重写排序；成功返回写事务内生成的真实撤销快照。
    func reorderSiblings(
        bookID: Int64,
        parentID: Int64,
        orderedChapterIDs: [Int64]
    ) async throws -> ChapterStructureRestoreSnapshot

    /// 把归一化后的选中子树移动到目标父级末尾，并返回写事务内生成的真实撤销快照。
    func moveChapters(
        bookID: Int64,
        chapterIDs: [Int64],
        targetParentID: Int64
    ) async throws -> ChapterStructureRestoreSnapshot

    /// 当前结构仍匹配撤销令牌时，事务恢复移动或重排前的 parent/order 并重算派生元数据。
    func restoreChapterStructure(_ snapshot: ChapterStructureRestoreSnapshot) async throws

    /// 软删除所选章节及其后代，并把受影响书摘移到未分章节。
    func deleteChapters(bookID: Int64, chapterIDs: [Int64]) async throws -> ChapterDeletionResult

    /// 保留父章节，软删除其全部后代，并把后代书摘移到未分章节。
    func deleteDescendants(bookID: Int64, parentID: Int64) async throws -> ChapterDeletionResult
}
