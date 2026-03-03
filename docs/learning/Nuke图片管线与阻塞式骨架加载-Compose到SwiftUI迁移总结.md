# Nuke 图片管线与阻塞式骨架加载（Android Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- 图片加载不要散落在页面：先定义统一请求构造器（URL 校验、超时、缓存、防盗链头），再让 UI/Data 都复用。
- UI 组件层负责“展示状态机”（占位、成功、失败、GIF），数据层负责“业务结果”（如取色与缓存），两者职责必须分离。
- GIF 场景不能只看 URL 后缀，必须补响应头与二进制签名探测，否则会漏掉伪装链接。
- 骨架屏设计应与最终内容同构，避免“加载态和完成态是两套布局”导致用户二次认知成本。
- 异步颜色准备要保证收敛：`pending` 必须有终态（`resolved/failed`），否则 loading 可能悬挂。

## 2. Compose -> SwiftUI 思维对照
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
|---|---|---|---|
| 统一图片请求 | Glide/Coil 封装工具类 | `XMImageRequestBuilder + XMImagePipelineFactory` | 先统一策略，再谈页面接入 |
| 页面图片渲染 | `AsyncImage/CoilImage` + placeholder | `XMRemoteImage`（静态图 + GIF + 降级） | 展示状态机下沉到复用组件 |
| GIF 播放 | `rememberAsyncImagePainter`/Glide 自动处理 | `XMGIFImageView`（Gifu 桥接） | 明确播放生命周期与释放点 |
| 颜色未就绪展示 | 骨架/占位 + 条件渲染 | 阻塞式同构骨架 + shimmer mask | 加载结构必须与真实结构一致 |
| 失败回退 | 默认色/默认图 | `failed` 回退色 + 文案提示 | pending 绝不悬挂 |

## 3. 可运行 SwiftUI 示例（阻塞式同构骨架）
```swift
import SwiftUI

enum BarColorState { case pending, resolved(Color), failed(Color) }

struct RankingRow: Identifiable {
    let id: Int
    let title: String
    let seconds: Int
    let state: BarColorState
}

struct BlockingRankingDemo: View {
    let rows: [RankingRow]
    @State private var shimmerPhase: CGFloat = -1

    var isReady: Bool { rows.allSatisfy { if case .pending = $0.state { return false } else { return true } } }

    var body: some View {
        Group {
            if isReady {
                VStack(alignment: .leading, spacing: 8) {
                    Text("阅读时长").font(.headline)
                    ForEach(rows) { row in
                        HStack {
                            RoundedRectangle(cornerRadius: 6).fill(barColor(row.state)).frame(width: 64, height: 40)
                            Text(row.title).lineLimit(1)
                            Spacer()
                        }
                    }
                }
            } else {
                skeletonContent
                    .overlay(skeletonContent.foregroundStyle(.white.opacity(0.55)).mask(shimmerBand))
                    .onAppear {
                        withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                            shimmerPhase = 1
                        }
                    }
            }
        }
        .padding()
    }

    var skeletonContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(0.30)).frame(width: 90, height: 14)
            ForEach(0..<3, id: \.self) { _ in
                HStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.30)).frame(width: 64, height: 40)
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.28)).frame(width: 120, height: 10)
                    Spacer()
                }
            }
        }
    }

    var shimmerBand: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            LinearGradient(colors: [.clear, .white, .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: max(100, w * 0.5))
                .rotationEffect(.degrees(16))
                .offset(x: shimmerPhase * (w + 120))
        }
    }

    func barColor(_ state: BarColorState) -> Color {
        switch state {
        case .pending: return .gray.opacity(0.4)
        case .resolved(let color), .failed(let color): return color
        }
    }
}
```

## 4. Compose 对照示例（核心意图）
```kotlin
@Composable
fun BlockingRanking(rows: List<RowState>) {
    val ready = rows.none { it is RowState.Pending }
    if (ready) {
        // 正式内容
    } else {
        // 与正式内容同构的 skeleton，不显示真实排行
        SkeletonRanking()
    }
}
```

## 5. 迁移结论
- 先统一请求与缓存策略，再统一 UI 组件，最后接入业务仓储，这是最稳的迁移顺序。
- “同构骨架 + 阻塞展示 + 失败回退”是避免二次动画、空白态和状态悬挂的关键组合。
- 该模式可直接复用于“月榜/年榜/封面色驱动条形图”等异步依赖 UI 场景。
