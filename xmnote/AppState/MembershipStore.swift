/**
 * [INPUT]: 依赖会员 Repository 的只读状态流
 * [OUTPUT]: 提供主线程会员状态投影与页面动作入口
 * [POS]: AppState 的界面投影，不持有购买事实或本地存储
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation
import Observation

/// 主线程发布状态；应用持有订阅，页面退出不取消购买或权益监听。
@MainActor @Observable
final class MembershipStore {
    private(set) var snapshot = MembershipSnapshot()
    private(set) var product: MembershipProduct?
    let repository: any MembershipRepositoryProtocol
    @ObservationIgnored private var observation: Task<Void, Never>?

    /// 注入业务唯一权益仓储，默认使用应用共享实例。
    init(repository: any MembershipRepositoryProtocol = MembershipRepository.shared) {
        self.repository = repository
    }
    deinit { observation?.cancel() }

    var isPremium: Bool { snapshot.isPremium }
    var title: String {
        if !snapshot.isLoaded { return "会员状态待确认" }
        switch snapshot.entitlement.status {
        case .notPurchased: return "开通会员"
        case .lifetime: return isPremium ? "永久会员" : "会员状态待确认"
        case .revoked: return "会员已失效"
        }
    }

    /// 首次订阅后加载权益，多 scene 重复调用不会新增订阅。
    func start() async {
        guard observation == nil else { return }
        let repository = repository
        observation = Task { [weak self] in
            let stream = await repository.states()
            for await value in stream {
                guard !Task.isCancelled else { return }
                self?.snapshot = value
            }
        }
        product = await repository.product()
        await repository.refresh()
    }

    /// 转发前台或用户刷新，来源监听不随调用页面取消。
    func refresh() async { await repository.refresh() }
    /// 转发购买操作，界面不持有交易事实。
    func purchase() async { await repository.purchase() }
    /// 由用户触发恢复，结果通过应用级状态流回到主线程。
    func restore() async { await repository.restore() }

    #if DEBUG
    /// 仅开发构建转发模拟命令，仍由仓储管理代次与状态。
    func simulate(_ command: MembershipSimulationCommand) async {
        guard let repository = repository as? MembershipRepository else { return }
        await repository.simulate(command)
    }
    #endif
}
