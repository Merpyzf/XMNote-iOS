# NoteTagsView 使用说明

## 组件定位
- 源码路径：xmnote/Views/Note/NoteTagsView.swift
- 角色：NoteTagsView 页面核心组件，承载对应功能主流程与关键交互。

## 快速接入
~~~swift
NoteTagsView(viewModel: viewModel)
~~~

## 参数说明
- 该组件对外参数以源码声明为准：xmnote/Views/Note/NoteTagsView.swift
- 接入时优先保持“容器层负责状态、组件层负责渲染”的边界。

## 示例
- 示例 1：在对应容器页中直接作为主内容承载。
- 示例 2：通过路由参数初始化后在导航栈中展示。

## 常见问题
### 1) 这个组件是否可抽到 UIComponents？
不建议。该组件属于核心页面壳层/页面核心业务组件，默认保留在 xmnote/Views。

### 2) 是否允许在组件内直接访问 Repository？
遵循现有架构：通过页面层或 ViewModel 注入，不在纯展示子组件中直连数据层。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
