/**
 * [INPUT]: 依赖会员契约、Foundation 原子文件写入
 * [OUTPUT]: 提供开发专用永久会员模拟交易、撤销、恢复和持久化
 * [POS]: Services 的 Debug 支付来源；Release 不包含该类型或存储入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
#if DEBUG
import Foundation

/// Actor 内同步原子落盘后才通知成功；无异步中断点，重置与购买不会交叉写入半份记录。
actor SimulatedMembershipSource: MembershipSimulationSource {
    /// 带版本的完整交易记录，不参与书籍数据库或偏好备份。
    private struct Record: Codable {
        var version = 1
        var entitlement = MembershipEntitlement(source: .development)
    }
    private let fileURL: URL
    private var nextOutcome: MembershipSimulationOutcome = .success
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// 为当前安装或测试注入独立交易文件，默认不参与应用数据备份。
    init(fileURL: URL = URL.applicationSupportDirectory
        .appending(path: "DevelopmentMembership/transaction.json")) {
        self.fileURL = fileURL
    }

    /// 返回明确的开发商品能力，不构造真实价格或 Apple 商品标识。
    func product() async -> MembershipProduct {
        .init(title: "永久会员", purchaseAvailable: true, isSimulation: true)
    }

    /// 读取已落盘的完整交易状态，损坏记录不会自动开通。
    func currentEntitlement() async throws -> MembershipEntitlement { try read().entitlement }

    /// 仅成功和待确认结果写入交易；取消和失败保持原有权益。
    func purchase() async throws -> MembershipPurchaseResult {
        var record = try read()
        if record.entitlement.isPremium { return .success(record.entitlement) }
        if record.entitlement.hasPendingPurchase { return .pending }
        let outcome = nextOutcome
        nextOutcome = .success
        switch outcome {
        case .cancelled: return .cancelled
        case .failure: throw MembershipError.simulatedFailure
        case .pending:
            record.entitlement.hasPendingPurchase = true
            try save(record)
            return .pending
        case .success:
            record.entitlement = newPurchase()
            try save(record)
            return .success(record.entitlement)
        }
    }

    /// 恢复只读取实际模拟账本，撤销记录不会变回有效。
    func restore() async throws -> MembershipEntitlement { try read().entitlement }

    /// 提供合并变更通知；取消观察只移除本订阅，不修改交易。
    func updates() async -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    /// 重置允许覆盖损坏测试记录；其他命令必须先成功读取，避免隐式掩盖损坏。
    func simulate(_ command: MembershipSimulationCommand) async throws {
        if case .nextOutcome(let outcome) = command { nextOutcome = outcome; return }
        if case .reset = command { nextOutcome = .success; try save(Record()); return }
        var record = try read()
        switch command {
        case .approvePending:
            guard record.entitlement.hasPendingPurchase else { return }
            record.entitlement = newPurchase()
        case .rejectPending:
            record.entitlement.hasPendingPurchase = false
        case .revoke:
            guard record.entitlement.isPremium else { return }
            record.entitlement.status = .revoked
            record.entitlement.revokedAt = Date()
            record.entitlement.hasPendingPurchase = false
        case .reset, .nextOutcome: return
        }
        try save(record)
    }

    /// 每次新购买生成独立交易身份，撤销旧交易后重新开通不会复用旧编号。
    private func newPurchase() -> MembershipEntitlement {
        .init(status: .lifetime, source: .development, transactionID: UUID().uuidString, purchasedAt: Date())
    }

    /// 校验版本和交易结构，拒绝不完整或损坏的模拟权益。
    private func read() throws -> Record {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Record() }
        do {
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: fileURL))
            let value = record.entitlement
            guard record.version == 1, value.source == .development,
                  value.status == .notPurchased || (value.transactionID?.isEmpty == false && value.purchasedAt != nil),
                  value.status != .lifetime || value.revokedAt == nil,
                  value.status != .revoked || value.revokedAt != nil else { throw MembershipError.corruptSimulation }
            return record
        } catch { throw MembershipError.corruptSimulation }
    }

    /// 先原子落盘并排除备份，再通知观察者；失败不发布成功。
    private func save(_ record: Record) throws {
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(record).write(to: fileURL, options: .atomic)
        for continuation in observers.values { continuation.yield(()) }
    }

    /// 释放已经终止的通知续体。
    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
#endif
