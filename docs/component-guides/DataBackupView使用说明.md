# DataBackupView 使用说明

## 组件定位
- 源码路径：`xmnote/Views/Personal/Backup/DataBackupView.swift`
- 角色：数据备份入口页，负责云备份 provider 切换、授权状态展示、手动备份与恢复动作触发。
- 适用场景：个人中心中的“数据备份”功能入口。

## 快速接入
```swift
NavigationStack {
    DataBackupView()
        .environment(AppState())
        .environment(repositoryContainer)
}
```

## 参数说明
- 对外无业务参数，依赖环境注入：
  - `AppState`：恢复成功后触发页面数据刷新。
  - `RepositoryContainer`：注入 `backupRepository`。

关键状态与交互约束（本次更新）：
- 云备份方式切换入口位于右侧值区（`providerSelectionMenu`），左侧标题区保持稳定。
- `selectedProviderSummary` 在阿里云盘场景返回 `nil`，避免“阿里云盘 + 未登录”重复文案。
- WebDAV 与阿里云登录行默认弱化前置图标，文本信息优先。
- provider 行使用 `providerRowVerticalPadding = Spacing.cozy`，与卡片其他行节奏一致。

## 示例
- 示例 1：标准接入（个人中心导航）。
```swift
NavigationLink(value: PersonalRoute.dataBackup) {
    Text("数据备份")
}
.navigationDestination(for: PersonalRoute.self) { route in
    if route == .dataBackup {
        DataBackupView()
            .environment(appState)
            .environment(repositoryContainer)
    }
}
```

- 示例 2：调试 provider 切换行为。
```swift
let vm = DataBackupViewModel(backupRepository: repo)
Task {
    await vm.loadPageData()
    await vm.selectProvider(.aliyunDrive)
}
```

## 常见问题
### 1) 为什么不把整行都做成备份方式切换入口？
整行参与过渡会导致标题区域抖动与空白错觉。右侧值区触发更符合 iOS 设置页认知。

### 2) 选中阿里云盘后为什么不显示“未登录”？
登录状态由阿里云授权行承接；在“云备份方式”行重复状态会造成信息冗余。

### 3) 空字段怎么处理？
WebDAV 未配置时统一显示“未配置”；阿里云未授权时显示登录入口，不额外拼接冗余提示。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
