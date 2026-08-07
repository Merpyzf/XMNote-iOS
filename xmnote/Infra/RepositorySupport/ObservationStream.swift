import Foundation
import GRDB

/**
 * [INPUT]: 依赖 GRDB 的 ValueObservation 异步序列能力
 * [OUTPUT]: 对外提供 ValueObservation 的快照流与跳过首个基线值的变化信号流
 * [POS]: Infra 的仓储支持层，消除 Repository 实现中的重复样板代码
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// GRDB 观察流桥接器，把数据库观察转换为 AsyncThrowingStream。
enum ObservationStream {
    /// 创建数据库观察流并桥接为 AsyncThrowingStream，失败时抛出错误。
    nonisolated static func make<Value: Sendable>(
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

    /// 创建无载荷变化信号；首个数据库结果只建立基线，后续值真正变化时才发送事件。
    nonisolated static func makeChangeSignal<Value: Equatable & Sendable>(
        in dbPool: DatabasePool,
        tracking: @escaping @Sendable (Database) throws -> Value
    ) -> AsyncThrowingStream<Void, Error> {
        let source = make(in: dbPool, tracking: tracking)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var iterator = source.makeAsyncIterator()
                    guard var previousValue = try await iterator.next() else {
                        continuation.finish()
                        return
                    }

                    while let value = try await iterator.next() {
                        guard !Task.isCancelled else { return }
                        guard value != previousValue else { continue }
                        previousValue = value
                        continuation.yield(())
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
