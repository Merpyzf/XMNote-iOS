import Foundation
import GRDB

/**
 * [INPUT]: 依赖 GRDB 的 ValueObservation 异步序列能力
 * [OUTPUT]: 对外提供 ValueObservation 到 AsyncThrowingStream 的桥接工具
 * [POS]: Infra 的仓储支持层，消除 Repository 实现中的重复样板代码
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

enum ObservationStream {
    static func make<Value: Sendable>(
        in dbPool: DatabasePool,
        tracking: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Value, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let observation = ValueObservation.tracking(tracking)
                do {
                    for try await value in observation.values(in: dbPool) {
                        guard !Task.isCancelled else { return }
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
