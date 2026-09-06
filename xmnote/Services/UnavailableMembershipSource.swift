/**
 * [INPUT]: 依赖会员来源契约
 * [OUTPUT]: 提供正式支付尚未接入时的明确不可用结果
 * [POS]: Services 的生产默认支付适配器，不读取开发模拟记录
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import Foundation

/// 上线前替换为 StoreKit 2 来源；不会因为本地模拟记录而授予正式权益。
nonisolated struct UnavailableMembershipSource: MembershipSource {
    /// 正式支付未配置时只返回不可购买的商品说明。
    func product() async -> MembershipProduct {
        .init(title: "永久会员", purchaseAvailable: false, isSimulation: false)
    }
    /// 正式默认来源不读取任何模拟或旧偏好记录。
    func currentEntitlement() async throws -> MembershipEntitlement { .init() }
    /// 明确拒绝尚未接入的购买操作，不发布成功。
    func purchase() async throws -> MembershipPurchaseResult { throw MembershipError.unavailable }
    /// 未接入真实来源时不能从本地模拟记录恢复权益。
    func restore() async throws -> MembershipEntitlement { throw MembershipError.unavailable }
    /// 不可用来源没有交易更新，立即结束通知流。
    func updates() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
