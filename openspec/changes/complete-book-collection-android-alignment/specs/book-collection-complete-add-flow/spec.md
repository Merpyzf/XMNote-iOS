## ADDED Requirements

### Requirement: 手动书单支持完整添加来源
系统 SHALL 在手动书单详情中通过现有 `添加书籍` 入口支持本地书籍、在线搜索结果、手动创建结果和多选结果加入当前书单。

#### Scenario: 手动书单打开添加书籍
- **WHEN** 用户在手动书单详情点击底部 `添加书籍`
- **THEN** 系统 SHALL 打开支持本地搜索、在线搜索、手动创建和多选的书籍选择流程

#### Scenario: 年度书单不显示添加入口
- **WHEN** 用户打开年度书单详情页
- **THEN** 系统 MUST NOT 显示底部 `添加书籍` 入口

#### Scenario: 排序态不显示添加入口
- **WHEN** 手动书单详情处于排序编辑态
- **THEN** 系统 MUST NOT 显示底部 `添加书籍` 入口

### Requirement: 添加结果写入当前书单关系
系统 SHALL 将用户选择或创建的书籍写入当前手动书单的 `collection_book` 关系，并保留 Android 对齐的排序、去重和 relation 语义。

#### Scenario: 添加本地有效书
- **WHEN** 用户从本地搜索结果选择一本或多本有效书籍并确认加入
- **THEN** 系统 SHALL 通过 Repository 将这些书籍加入当前书单

#### Scenario: 添加在线搜索书籍
- **WHEN** 用户从在线搜索结果选择未入库书籍并确认加入当前书单
- **THEN** 系统 SHALL 保存可用于书单展示的书籍记录，并将其作为当前书单关系写入

#### Scenario: 添加手动创建书籍
- **WHEN** 用户在添加流程中手动创建书籍并保存到当前书单
- **THEN** 系统 SHALL 将创建结果加入当前书单关系

#### Scenario: 重复选择已有关系书籍
- **WHEN** 用户选择已经存在于当前书单的书籍
- **THEN** 系统 SHALL 避免重复创建相同 `collection_book` 关系，并给出非打断式反馈或在选择器中保持已选不可重复状态

### Requirement: 添加流程提供写操作反馈
系统 SHALL 在添加书籍写入期间提供即时反馈并禁用重复提交入口。

#### Scenario: 添加写入中
- **WHEN** 系统正在把选择结果写入当前书单
- **THEN** 系统 SHALL 显示写入中反馈，并禁用重复确认或重复点击添加入口

#### Scenario: 添加成功
- **WHEN** 书籍成功加入当前书单
- **THEN** 系统 SHALL 刷新书单详情并展示添加成功反馈

#### Scenario: 添加失败
- **WHEN** Repository 写入添加结果失败
- **THEN** 系统 SHALL 保持原书单数据不被部分破坏，并展示失败反馈

### Requirement: 添加能力遵守数据访问边界
系统 SHALL 通过 Repository 完成书籍搜索结果保存、手动创建结果保存和书单关系写入，ViewModel MUST NOT 直接访问数据库或网络客户端。

#### Scenario: 保存添加结果
- **WHEN** ViewModel 处理书籍选择器返回结果
- **THEN** ViewModel SHALL 调用 Repository 暴露的书单添加能力，而不是直接访问数据库、网络客户端或 WebDAV 客户端
