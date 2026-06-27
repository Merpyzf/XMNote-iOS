## ADDED Requirements

### Requirement: 书单详情展示占位书状态
系统 SHALL 在书单详情中展示仅存在于书单关系、尚未加入书架的占位书，并用 iOS 语义表达其可恢复状态。

#### Scenario: 显示占位书
- **WHEN** 当前书单包含 `book.is_deleted = 1` 的书籍关系
- **THEN** 书籍 Item SHALL 继续显示该书的封面、标题、作者和 relation 文本

#### Scenario: 占位书状态文案
- **WHEN** 用户查看占位书 Item
- **THEN** 系统 SHALL 显示 `未加入书架`、`加入书架` 或同等明确恢复语义，而不是只显示普通阅读状态

#### Scenario: 占位书不破坏普通书籍展示
- **WHEN** 当前书单同时包含有效书籍和占位书
- **THEN** 系统 SHALL 分别展示普通阅读状态与占位书恢复状态，不得把有效书错误标记为占位书

### Requirement: 支持恢复占位书
系统 SHALL 允许用户将占位书恢复为书架中的有效书籍，并保留书单关系。

#### Scenario: 点击占位书恢复入口
- **WHEN** 用户点击占位书 Item 的 `加入书架` 或等价恢复入口
- **THEN** 系统 SHALL 通过 Repository 执行恢复写入，并提供即时写操作反馈

#### Scenario: 恢复成功
- **WHEN** 占位书恢复成功
- **THEN** 系统 SHALL 将该书更新为有效书籍状态，刷新书单详情，并保留原 `collection_book` relation 文本与排序

#### Scenario: 恢复失败
- **WHEN** 占位书恢复写入失败
- **THEN** 系统 SHALL 保持原占位状态，并展示失败反馈

### Requirement: 占位书打开行为明确
系统 SHALL 为占位书提供可理解的打开行为，避免进入无法操作或数据缺失的详情页。

#### Scenario: 点击占位书主体
- **WHEN** 用户点击占位书 Item 主体
- **THEN** 系统 SHALL 打开带有恢复入口的书籍信息页或占位书预览页

#### Scenario: 占位书详情恢复
- **WHEN** 用户在占位书信息页或预览页点击恢复入口
- **THEN** 系统 SHALL 执行与书单 Item 恢复入口一致的 Repository 写入逻辑

### Requirement: 占位书关系参与书单操作
系统 SHALL 让占位书关系参与手动书单的关系级操作，但不得误当作有效书架书籍参与年度同步。

#### Scenario: 手动书单移出占位书
- **WHEN** 用户从手动书单移出占位书
- **THEN** 系统 SHALL 只删除或软删除当前书单关系，不得强制删除可被其他关系引用的书籍记录

#### Scenario: 年度书单同步
- **WHEN** 系统同步年度书单成员
- **THEN** 系统 MUST NOT 将占位书作为读完记录自动加入年度书单
