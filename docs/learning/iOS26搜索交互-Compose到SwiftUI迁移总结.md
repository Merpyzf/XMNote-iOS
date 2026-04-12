# iOS26 搜索交互：Compose 到 SwiftUI 迁移总结

## 1. 本次知识点
- SwiftUI `Tab(role: .search)`：声明搜索语义 Tab。
- `tabViewSearchActivation(.searchTabSelection)`：iOS 26 搜索 Tab 激活策略。
- `searchable(text:prompt:)`：把搜索输入状态提升到容器层统一管理。
- `searchable` 的 owner 边界和 `@State` 一样重要；挂在错误的共享容器上，会把系统搜索宿主污染到其他导航栈。
- 页面级 `.searchable(... navigationBarDrawer(.always))` 不只是 UI 装饰，还可能触发系统搜索宿主重绑。

## 2. Compose -> SwiftUI 思维映射
- Compose 常见方式：
  - 用页面内搜索框或 `SearchActivity` 承接搜索，搜索 owner 比较局部。
- SwiftUI iOS 26 方式：
  - 可以让 `TabView` 直接拥有系统搜索语义，但必须把 owner 控制在正确的共享范围内。
  - “搜索状态提升到容器层”不等于“所有 tab 永远共享同一个根级搜索宿主”。

## 3. 系统搜索宿主的 owner 边界
- 错误心智：
  - Compose 里页面内搜索通常是局部能力，所以容易把 SwiftUI `searchable` 当成“只要挂在根上就统一省事”的全局能力。
- 正确心智：
  - SwiftUI `searchable` 会参与系统导航栏和滚动宿主协作，它的 owner 必须按实际共享边界控制。
  - 若只有搜索 Tab 需要根级系统搜索宿主，就只在搜索 Tab 激活时挂载；不要让其他 Tab 的 `NavigationStack` 常驻这套系统状态。

## 4. 最小可运行示例
### 4.1 错误写法：所有 Tab 常驻根级搜索宿主
```swift
import SwiftUI

enum DemoTab: Hashable { case home, search }

struct BadSearchTabs: View {
    @State private var selectedTab: DemoTab = .home
    @State private var query = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("首页", systemImage: "house", value: .home) {
                Text("Home")
            }
            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                Text(query.isEmpty ? "输入关键词开始搜索" : "搜索: \\(query)")
            }
        }
        .tabViewSearchActivation(.searchTabSelection)
        .searchable(text: $query, prompt: "搜索内容")
    }
}
```

### 4.2 正确写法：按搜索 Tab 条件挂载
```swift
import SwiftUI

enum DemoTab: Hashable { case home, search }

struct GoodSearchTabs: View {
    @State private var selectedTab: DemoTab = .home
    @State private var query = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("首页", systemImage: "house", value: .home) {
                Text("Home")
            }
            Tab("搜索", systemImage: "magnifyingglass", value: .search, role: .search) {
                Text(query.isEmpty ? "输入关键词开始搜索" : "搜索: \\(query)")
            }
        }
        .modifier(
            SearchHostModifier(
                isEnabled: selectedTab == .search,
                query: $query
            )
        )
    }
}

private struct SearchHostModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var query: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .tabViewSearchActivation(.searchTabSelection)
                .searchable(text: $query, prompt: "搜索内容")
        } else {
            content
        }
    }
}
```

## 5. 迁移注意事项
- 不要在搜索页再放一个手写输入框，否则会与系统搜索入口冲突。
- 搜索状态应由 Tab 容器统一持有，避免多个页面各自维护 query 导致状态不一致。
- 当多个根页共用同一条 `NavigationStack` 时，出现滚动/回弹异常要先查共享系统 modifier owner，不要先改受害页面的 `ScrollView`。
