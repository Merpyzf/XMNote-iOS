# Backup/
> L2 | 父级: Personal/CLAUDE.md

数据备份与恢复功能模块，View + ViewModel 共置。

## 成员清单

- `DataBackupView.swift`: 备份与恢复入口页面
- `DataBackupViewModel.swift`: 备份恢复状态编排，含 BackupOperationState 枚举
- `WebDAVServerListView.swift`: 备份服务器列表管理
- `WebDAVServerFormView.swift`: 备份服务器新增编辑
- `WebDAVServerViewModel.swift`: 服务器配置管理状态编排
- `BackupHistorySheetView.swift`: 备份历史展示与恢复确认弹层

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
