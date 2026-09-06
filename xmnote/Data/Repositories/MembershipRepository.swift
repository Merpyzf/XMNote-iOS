/**
 * [INPUT]: 依赖 MembershipSource 验证后的权益与异步更新流
 * [OUTPUT]: 提供全应用唯一会员状态、购买编排、订阅与实时权限裁决
 * [POS]: Data 的会员 Repository，不向 UI 暴露存储或 SDK
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// Actor 串行发布权益，generation 拒绝重置前的异步结果；监听寿命属于应用，不属于页面。
actor MembershipRepository: MembershipRepositoryProtocol {
    static let shared = MembershipRepository(source: makeSource())
    private let source: any MembershipSource
    private var value = MembershipSnapshot()
    private var generation = 0
    private var updateTask: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<MembershipSnapshot>.Continuation] = [:]
    private var needsRefresh = false

    /// 注入经验证的权益来源，测试可替换为隔离的交易来源。
    init(source: any MembershipSource) { self.source = source }
    deinit { updateTask?.cancel() }

    /// 唯一生产组装点；编译条件使正式版本无法构造模拟来源。
    private static func makeSource() -> any MembershipSource {
        #if DEBUG
        SimulatedMembershipSource()
        #else
        UnavailableMembershipSource()
        #endif
    }

    /// 返回同一 Actor 内的完整快照，业务不缓存可写会员状态。
    func snapshot() -> MembershipSnapshot { value }
    /// 通过来源取得商品能力，挂起时不锁住权益查询。
    func product() async -> MembershipProduct { await source.product() }
    /// 按当前已加载权益裁决受限操作，不接受调用方声明的身份。
    func hasPremiumAccess() -> Bool { value.isPremium }

    /// 在业务副作用前区分状态未就绪与未持有权益。
    func requirePremium() throws {
        guard value.isLoaded else { throw MembershipError.notReady }
        guard value.isPremium else { throw MembershipError.required }
    }

    /// 注册时先交付快照，后续使用 newest 缓冲；取消只结束当前观察者。
    func states() -> AsyncStream<MembershipSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MembershipSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(value)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    /// 前台刷新可与来源通知合并；已有购买优先完成，然后重新核对来源。
    func refresh() async {
        if value.operation != nil { needsRefresh = true; return }
        let token = begin(.refreshing)
        await startListening()
        do {
            let entitlement = try await source.currentEntitlement()
            guard token == generation else { return }
            accept(entitlement)
        } catch {
            guard token == generation else { return }
            recordFailure(error)
        }
        await complete(token)
    }

    /// 购买和恢复互斥；只有来源返回的有效权益会解锁，取消不会影响已确认权益。
    func purchase() async {
        guard value.operation == nil, !value.isPremium, !value.entitlement.hasPendingPurchase else { return }
        let token = begin(.purchasing)
        do {
            let result = try await source.purchase()
            guard token == generation else { return }
            switch result {
            case .success(let entitlement):
                accept(entitlement)
                value.message = value.isPremium ? "永久会员已开通" : "未获得有效会员权益"
            case .cancelled: value.message = "已取消支付，会员权益未改变"
            case .pending:
                value.entitlement.hasPendingPurchase = true
                value.message = "支付待确认，确认前不会开通会员"
            }
        } catch {
            guard token == generation else { return }
            recordFailure(error)
        }
        await complete(token)
    }

    /// 显式恢复来源记录；与购买互斥，旧结果由 generation 丢弃。
    func restore() async {
        guard value.operation == nil else { return }
        let token = begin(.restoring)
        do {
            let entitlement = try await source.restore()
            guard token == generation else { return }
            accept(entitlement)
            value.message = value.isPremium ? "已恢复永久会员" : "没有可恢复的有效购买"
        } catch {
            guard token == generation else { return }
            recordFailure(error)
        }
        await complete(token)
    }

    #if DEBUG
    /// 测试重置/撤销优先于旧刷新；generation 保护 UI，模拟来源的同步原子写保护持久化。
    func simulate(_ command: MembershipSimulationCommand) async {
        guard let simulation = source as? any MembershipSimulationSource else { return }
        value.message = nil
        let token = begin(.refreshing)
        do {
            try await simulation.simulate(command)
            let entitlement = try await simulation.currentEntitlement()
            guard token == generation else { return }
            accept(entitlement)
            switch command {
            case .nextOutcome: break
            case .approvePending: value.message = value.isPremium ? "永久会员已开通" : "没有待确认的支付"
            case .rejectPending: value.message = "已拒绝待确认支付"
            case .revoke: value.message = "会员权益已撤销"
            case .reset: value.message = "已重置为未购买"
            }
        } catch {
            guard token == generation else { return }
            recordFailure(error)
        }
        await complete(token)
    }
    #endif

    /// 普通操作失败保留已确认权益；任何读取发现损坏交易，都立即停止依据该记录授权。
    private func recordFailure(_ error: Error) {
        if case MembershipError.corruptSimulation = error {
            value.entitlement = MembershipEntitlement()
            value.isLoaded = false
            value.message = nil
        }
        value.errorMessage = error.localizedDescription
    }

    /// 推进操作代次并发布等待状态，旧异步结果不能覆盖新操作。
    private func begin(_ operation: MembershipSnapshot.Operation) -> Int {
        generation += 1
        value.operation = operation
        if operation != .refreshing { value.message = nil }
        value.errorMessage = nil
        publish()
        return generation
    }

    /// 接受来源事实并隔离正式版本中的开发记录。
    private func accept(_ entitlement: MembershipEntitlement) {
        #if !DEBUG
        guard entitlement.source != .development else {
            value.errorMessage = "开发模拟权益不能用于正式版本"
            return
        }
        #endif
        if value.entitlement.status != entitlement.status { value.message = nil }
        value.entitlement = entitlement
        value.isLoaded = true
    }

    /// 仅结束当前代次并合并来源刷新，保留权益与操作结果的独立语义。
    private func complete(_ token: Int) async {
        guard token == generation else { return }
        value.operation = nil
        publish()
        if needsRefresh {
            needsRefresh = false
            await refresh()
        }
    }

    /// 应用级监听来源更新，弱引用和取消保证订阅不延长仓储寿命。
    private func startListening() async {
        guard updateTask == nil else { return }
        let stream = await source.updates()
        updateTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.sourceChanged()
            }
        }
    }

    /// 来源变更在操作完成后合并刷新，避免中途覆盖正在进行的交易。
    private func sourceChanged() async {
        if value.operation != nil { needsRefresh = true } else { await refresh() }
    }

    /// 向独立观察者发布同一快照，不等待界面消费。
    private func publish() { for observer in observers.values { observer.yield(value) } }
    /// 订阅结束时移除续体，其他场景的订阅继续运行。
    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
