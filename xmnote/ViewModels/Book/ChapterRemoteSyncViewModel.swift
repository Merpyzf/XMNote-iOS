/**
 * [INPUT]: 依赖 ChapterManagementRepositoryProtocol 提供文曲目录发现与事务导入，接收 bookID 路由参数
 * [OUTPUT]: 对外提供 ChapterRemoteSyncViewModel，维护候选、目录筛选、多选、导入及错误恢复状态
 * [POS]: ViewModels/Book 的远端目录同步 Sheet 状态源，由 ChapterManagerViewModel 创建并交给业务 Sheet
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 远端目录 Sheet 的读取阶段；加载、候选、目录预览和空错误状态互斥。
enum ChapterRemoteSyncPhase: Hashable {
    case loading
    case candidates
    case catalog
    case empty(String)
    case error(String)
}

/// 远端目录同步状态源；网络发现与数据库导入均经 Repository，MainActor 只串行维护页面状态。
@MainActor
@Observable
final class ChapterRemoteSyncViewModel: Identifiable {
    let id = UUID()
    let bookID: Int64

    var phase: ChapterRemoteSyncPhase = .loading
    var discovery: ChapterRemoteCatalogDiscovery?
    var configurationState: ChapterRemoteConfigurationState?
    var selectedCandidate: ChapterRemoteCatalogCandidate?
    var catalogItems: [ChapterRemoteCatalogItem] = []
    var selectedItemIDs: Set<String> = []
    var searchText = ""
    var isImporting = false
    var importErrorMessage: String?
    var isCompleted = false

    private let repository: any ChapterManagementRepositoryProtocol
    private var loadTask: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?

    /// 注入书籍 ID 与统一章节仓储；读取由呈现入口显式启动，避免初始化阶段产生副作用。
    init(bookID: Int64, repository: any ChapterManagementRepositoryProtocol) {
        self.bookID = bookID
        self.repository = repository
    }

    /// Sheet 释放时取消仍在执行的 URLSession/数据库等待，避免离场后回写 UI。
    isolated deinit {
        loadTask?.cancel()
        configurationTask?.cancel()
        importTask?.cancel()
    }

    var candidates: [ChapterRemoteCatalogCandidate] {
        discovery?.candidates ?? []
    }

    var visibleCatalogItems: [ChapterRemoteCatalogItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return catalogItems }
        return catalogItems.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
    }

    var selectedCount: Int { selectedItemIDs.count }

    var isAllSelected: Bool {
        !catalogItems.isEmpty && selectedItemIDs.count == catalogItems.count
    }

    var canReturnToCandidates: Bool {
        discovery?.matchMode == .bookTitleCandidates && selectedCandidate != nil
    }

    /// 建立一次可取消发现任务；重试会先取消旧任务，且错误只映射为可行动页面状态。
    func load() {
        loadTask?.cancel()
        configurationTask?.cancel()
        phase = .loading
        configurationState = nil
        importErrorMessage = nil
        configurationTask = Task { [weak self] in
            guard let self else { return }
            let state = await repository.fetchRemoteConfigurationState()
            guard !Task.isCancelled else { return }
            configurationState = state
            configurationTask = nil
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.discoverRemoteCatalog(bookID: bookID)
                guard !Task.isCancelled else { return }
                discovery = result
                if result.candidates.isEmpty {
                    phase = .empty("未匹配到当前书籍的目录信息")
                } else if result.matchMode == .exactDoubanID, let candidate = result.candidates.first {
                    selectCandidate(candidate)
                } else {
                    phase = .candidates
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                phase = .error(error.localizedDescription)
            }
            loadTask = nil
        }
    }

    /// 进入一本候选书的目录预览；空目录保留候选返回路径，不伪造章节数据。
    func selectCandidate(_ candidate: ChapterRemoteCatalogCandidate) {
        selectedCandidate = candidate
        searchText = ""
        catalogItems = candidate.catalogTitles.enumerated().map { index, title in
            ChapterRemoteCatalogItem(
                id: "\(candidate.id)-chapter-\(index)",
                title: title,
                originalIndex: index
            )
        }
        selectedItemIDs = Set(catalogItems.map(\.id))
        phase = catalogItems.isEmpty
            ? .empty("文曲已匹配到这本书，但暂未收录目录")
            : .catalog
    }

    /// 从预览返回书名候选；精确豆瓣匹配没有候选层，不提供该操作。
    func returnToCandidates() {
        guard discovery?.matchMode == .bookTitleCandidates else { return }
        selectedCandidate = nil
        catalogItems = []
        selectedItemIDs = []
        searchText = ""
        phase = candidates.isEmpty ? .empty("未匹配到当前书籍的目录信息") : .candidates
    }

    /// 切换单条目录选择；导入期间冻结选择，阻止请求参数与界面状态竞态。
    func toggleItem(_ itemID: String) {
        guard !isImporting, catalogItems.contains(where: { $0.id == itemID }) else { return }
        if selectedItemIDs.contains(itemID) {
            selectedItemIDs.remove(itemID)
        } else {
            selectedItemIDs.insert(itemID)
        }
    }

    /// 在全部目录范围切换全选，搜索仅影响可见行，不隐式丢弃隐藏选择。
    func toggleSelectAll() {
        guard !isImporting else { return }
        selectedItemIDs = isAllSelected ? [] : Set(catalogItems.map(\.id))
    }

    /// 按服务端原始行号提交选中目录；成功通过主页面观察流刷新并关闭 Sheet。
    func importSelected() {
        guard !isImporting else { return }
        let selectedTitles = catalogItems
            .filter { selectedItemIDs.contains($0.id) }
            .sorted { $0.originalIndex < $1.originalIndex }
            .map(\.title)
        guard !selectedTitles.isEmpty else {
            importErrorMessage = "请先选择要导入的章节"
            return
        }

        importErrorMessage = nil
        isImporting = true
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImporting = false
                importTask = nil
            }
            do {
                _ = try await repository.importRemoteCatalog(bookID: bookID, titles: selectedTitles)
                guard !Task.isCancelled else { return }
                isCompleted = true
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                importErrorMessage = error.localizedDescription
            }
        }
    }

    /// 消费导入错误，供 XMSystemAlert 关闭后恢复页面交互。
    func consumeImportError() {
        importErrorMessage = nil
    }
}
