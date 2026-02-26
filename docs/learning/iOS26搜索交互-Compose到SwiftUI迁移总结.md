# iOS26 搜索交互：Compose 到 SwiftUI 迁移总结

## 1. 本次知识点
- SwiftUI `Tab(role: .search)`：声明搜索语义 Tab。
- `tabViewSearchActivation(.searchTabSelection)`：iOS 26 搜索 Tab 激活策略。
- `searchable(text:isPresented:prompt:)`：把搜索输入状态提升到容器层统一管理。
- 使用状态机思想处理“先触发搜索，再进入页面”的双阶段交互。

## 2. Compose -> SwiftUI 思维映射
- Compose 常见方式：
  - 底部导航点击后手动弹搜索面板，再路由到搜索页。
- SwiftUI iOS 26 方式：
  - 用系统提供的搜索 Tab 激活机制，减少自定义面板实现成本。
  - 通过 `@State` + `onChange` 在容器层控制“激活”和“进入结果页”。

## 3. 最小可运行示例
```swift
import SwiftUI

enum DemoTab: Hashable { case home, search }

struct DemoSearchTabs: View {
    @State private var selectedTab: DemoTab = .home
    @State private var lastNonSearch: DemoTab = .home
    @State private var query = ""
    @State private var isSearchPresented = false

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
        .searchable(text: $query, isPresented: $isSearchPresented, prompt: "搜索内容")
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .search, query.isEmpty {
                isSearchPresented = true
                selectedTab = lastNonSearch
            } else if newValue != .search {
                lastNonSearch = newValue
            }
        }
        .onChange(of: query) { _, newValue in
            if !newValue.isEmpty {
                selectedTab = .search
            }
        }
    }
}
```

## 4. 迁移注意事项
- 不要在搜索页再放一个手写输入框，否则会与系统搜索入口冲突。
- 搜索状态应由 Tab 容器统一持有，避免多个页面各自维护 query 导致状态不一致。
