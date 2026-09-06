/**
 * [INPUT]: 依赖 Foundation，描述购买来源验证后的永久权益与购买操作
 * [OUTPUT]: 提供会员快照、商品、购买结果及可替换的来源/仓储契约
 * [POS]: Domain 的会员权益边界，不依赖支付 SDK 或持久化实现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// 永久权益没有自然到期；撤销表示退款或来源撤回授权。
nonisolated enum MembershipStatus: String, Codable, Sendable {
    case notPurchased, lifetime, revoked
}

/// 来源已确认的权益；业务层不接受页面写入的会员布尔值。
nonisolated struct MembershipEntitlement: Codable, Equatable, Sendable {
    /// 区分未接入、开发模拟与未来 Apple 验证来源。
    enum Source: String, Codable, Sendable { case unavailable, development, apple }
    var status: MembershipStatus = .notPurchased
    var source: Source = .unavailable
    var transactionID: String?
    var purchasedAt: Date?
    var revokedAt: Date?
    var hasPendingPurchase = false

    var isPremium: Bool {
        status == .lifetime && source != .unavailable
            && transactionID?.isEmpty == false && purchasedAt != nil && revokedAt == nil
    }
}

/// 商品信息由实际来源提供，正式配置未接入时不伪造价格或商品编号。
nonisolated struct MembershipProduct: Equatable, Sendable {
    let title: String
    let purchaseAvailable: Bool
    let isSimulation: Bool
}

/// 购买操作与权益状态分离，取消或失败不撤销已有权益。
nonisolated enum MembershipPurchaseResult: Sendable {
    case success(MembershipEntitlement)
    case cancelled
    case pending
}

/// Repository 发布的完整状态，刷新错误不会替换已确认权益。
nonisolated struct MembershipSnapshot: Equatable, Sendable {
    /// 界面等待状态与已拥有的权益相互独立。
    enum Operation: Sendable { case refreshing, purchasing, restoring }
    var entitlement = MembershipEntitlement()
    var isLoaded = false
    var operation: Operation?
    var message: String?
    var errorMessage: String?
    var isPremium: Bool { isLoaded && entitlement.isPremium }
}

/// 统一受限动作的错误，加载/失败状态不会被误报成尚未付费。
nonisolated enum MembershipError: LocalizedError {
    case unavailable, notReady, required, corruptSimulation, simulatedFailure
    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple 支付暂未开放"
        case .notReady: "会员状态尚未就绪，请前往会员页刷新后重试"
        case .required: "此功能需要永久会员，请前往会员页查看权益"
        case .corruptSimulation: "模拟购买记录损坏，请在开发测试区重置"
        case .simulatedFailure: "模拟支付失败，会员权益未改变"
        }
    }
}

/// 支付适配端口。所有异步方法可被应用任务调用，来源负责验证与持久化，更新流只通知重新核对权益。
nonisolated protocol MembershipSource: Sendable {
    func product() async -> MembershipProduct
    func currentEntitlement() async throws -> MembershipEntitlement
    func purchase() async throws -> MembershipPurchaseResult
    func restore() async throws -> MembershipEntitlement
    func updates() async -> AsyncStream<Void>
}

/// 业务唯一权益入口；跨 Actor 查询当前状态，观察者取消只移除自身订阅，不停止全局监听。
nonisolated protocol MembershipRepositoryProtocol: Sendable {
    func snapshot() async -> MembershipSnapshot
    func states() async -> AsyncStream<MembershipSnapshot>
    func product() async -> MembershipProduct
    func refresh() async
    func purchase() async
    func restore() async
    func hasPremiumAccess() async -> Bool
    func requirePremium() async throws
}

#if DEBUG
/// 仅开发构建可选择的购买响应，不与真实支付 API 混用。
nonisolated enum MembershipSimulationOutcome: String, CaseIterable, Sendable {
    case success = "成功", cancelled = "取消", failure = "失败", pending = "待确认"
}

/// 测试命令通过来源执行，不直接修改 UI 状态。
nonisolated enum MembershipSimulationCommand: Sendable {
    case nextOutcome(MembershipSimulationOutcome), approvePending, rejectPending, revoke, reset
}

/// 模拟控制仅在开发构建编译，不向正式购买协议增加后门。
nonisolated protocol MembershipSimulationSource: MembershipSource {
    func simulate(_ command: MembershipSimulationCommand) async throws
}
#endif
