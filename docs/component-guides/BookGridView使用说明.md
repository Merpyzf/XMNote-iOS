# BookGridView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Book/BookGridView.swift`
- 角色：`BookGridView` 是书籍子页的 SwiftUI 内容入口，负责维度 rail、搜索态提示、编辑态顶部/底部栏、Sheet 和集合区参数编排。
- 边界：`BookGridView` 不直接承担书籍集合区的 UIKit 滚动、拖拽排序和 TabBar 联动实现；默认书架集合区由 `xmnote/Views/Book/Components/BookshelfDefaultCollectionView.swift` 承接。
- 架构方向：首页书架管理范围内，所有书籍列表集合区统一对齐 `BookshelfDefaultCollectionView` 的 `UIViewRepresentable + UICollectionView + UIHostingConfiguration` 方案。

## 快速接入
~~~swift
BookGridView(
    viewModel: viewModel,
    isPageActive: selectedSubTab == .books,
    onOpenRoute: onOpenBookRoute
)
~~~

## 参数说明
- `viewModel`：提供书架快照、维度状态、搜索态、显示设置、编辑态、选择集合和写操作状态。
- `isPageActive`：标识当前书籍子页是否正在显示。默认书架 UIKit collection 只有在页面可见时才登记为 TabBar observed scroll view，避免隐藏页抢占底部栏滚动联动。
- `onOpenRoute`：UIKit cell 点击后的导航桥。collection view 负责命中 item，真实导航仍回到 SwiftUI `NavigationStack`。
- 该组件对外参数以源码声明为准：`xmnote/Views/Book/BookGridView.swift`
- 接入时优先保持“容器层负责状态、组件层负责渲染”的边界。

## 集合区架构约束
- SwiftUI 层：保留页面壳层、维度切换、编辑态栏、Sheet 和路由。
- UIKit 层：书籍列表集合区统一使用 `UICollectionView`，承接滚动、Grid/List layout、系统拖拽排序、边缘自动滚动、TabBar 最小化和 iOS 26 bottom edge effect。
- Cell 视觉层：继续复用 SwiftUI 书籍/分组/列表行视图，通过 `UIHostingConfiguration` 嵌入 `UICollectionViewCell`。
- 默认书架：以 `BookshelfDefaultCollectionView` 为基准实现，排序只在默认维度、编辑态、手动排序、非搜索态启用。
- 二级书籍列表：`BookshelfBookListView` 等后续需要迁移到同一 collection 架构；只读列表不启用拖拽排序。
- 禁止事项：新增首页书架管理内的书籍列表时，不得复制旧 SwiftUI `ScrollView`、`LazyVGrid`、`LazyVStack` 或手写拖拽基建作为生产实现。

## 示例
- 示例 1：在对应容器页中直接作为主内容承载。
- 示例 2：通过路由参数初始化后在导航栈中展示。

## 常见问题
### 1) 这个组件是否可抽到 UIComponents？
不建议。该组件属于核心页面壳层/页面核心业务组件，默认保留在 xmnote/Views。

### 2) 是否允许在组件内直接访问 Repository？
遵循现有架构：通过页面层或 ViewModel 注入，不在纯展示子组件中直连数据层。

### 3) 新增书籍列表页面应该怎么做？
优先复用或对齐默认书架 collection 架构。SwiftUI 只负责页面状态和导航，列表滚动与 item 布局交给 `UICollectionView`；只读列表不需要实现拖拽，但仍应保持相同的桥接方式和 cell 承载方式。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
