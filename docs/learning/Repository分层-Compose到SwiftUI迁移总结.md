# Repository 分层迁移总结（Android Compose -> SwiftUI）

## 1. 本次 iOS 关键知识点

- **Repository 作为数据访问唯一入口**
  ViewModel 不再直接触达 `AppDatabase`/`WebDAVClient`，只依赖 `Repository` 协议。
- **协议 + 实现分离**
  `Domain` 定义协议，`Data` 提供实现，便于测试替换（Mock Repository）。
- **`@Environment` 注入仓储容器**
  在 View 壳层读取 `RepositoryContainer`，再构造 ViewModel，避免在 `init` 中访问环境。
- **GRDB 观察流桥接**
  使用 `AsyncThrowingStream` 封装 `ValueObservation`，让 ViewModel 用统一异步流消费数据。

## 2. Android Compose 对照思路

| Android | iOS | 对照说明 |
|---|---|---|
| `ViewModel -> Repository` | `ViewModel -> RepositoryProtocol` | 同样保持单向依赖 |
| `RepositoryImpl` | `struct XxxRepository: XxxRepositoryProtocol` | 实现细节下沉 |
| `Flow` | `AsyncThrowingStream` | 都是可持续观察数据流 |
| `Hilt/Koin` | `RepositoryContainer + @Environment` | 都是依赖注入 |

## 3. 可运行示例（最小骨架）

```swift
import SwiftUI

protocol CounterRepositoryProtocol {
    func observeCount() -> AsyncThrowingStream<Int, Error>
    func increase() async throws
}

struct CounterRepository: CounterRepositoryProtocol {
    func observeCount() -> AsyncThrowingStream<Int, Error> {
        AsyncThrowingStream { continuation in
            var value = 0
            continuation.yield(value)
            let task = Task {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    value += 1
                    continuation.yield(value)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func increase() async throws {
        // 实际项目里写数据库/网络，这里省略
    }
}

@Observable
class CounterViewModel {
    var count: Int = 0
    private let repository: any CounterRepositoryProtocol
    private var task: Task<Void, Never>?

    init(repository: any CounterRepositoryProtocol) {
        self.repository = repository
        task = Task {
            for try await value in repository.observeCount() {
                await MainActor.run { self.count = value }
            }
        }
    }
}

struct CounterView: View {
    @State private var vm = CounterViewModel(repository: CounterRepository())

    var body: some View {
        Text("count: \(vm.count)")
    }
}
```

## 4. 迁移经验

- 优先先建协议，再搬实现，最后改 ViewModel 注入；风险最小。
- 先保证行为不变，再做命名和目录美化。
- 当你发现 ViewModel 开始拼 SQL/组 URL，就该立即下沉到 Repository。

## 5. 本次优化补充（连接测试去重）

- 问题：`WebDAVServerViewModel` 的“测试连接”和“保存”会对同一参数重复发起连接校验。
- 优化：在 ViewModel 中缓存最近一次校验成功的 `BackupServerFormInput`；保存时只有参数变化才重新校验。
- 结果：避免重复网络请求，减少保存等待时间，同时保留“保存前必须可连通”的安全约束。
