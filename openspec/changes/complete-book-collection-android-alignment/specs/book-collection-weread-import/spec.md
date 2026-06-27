## ADDED Requirements

### Requirement: 支持微信读书书单链接导入入口
系统 SHALL 提供微信读书书单链接导入入口，并将外部分享或粘贴链接导向同一套导入预览流程。

#### Scenario: 应用内导入入口
- **WHEN** 用户在书单模块选择 `导入微信读书书单`
- **THEN** 系统 SHALL 提供输入或粘贴微信读书书单链接的界面

#### Scenario: 系统分享链接
- **WHEN** iOS 接收到用户分享给 XMNote 的微信读书书单链接或包含该链接的文本
- **THEN** 系统 SHALL 识别该链接并进入微信读书书单导入流程

#### Scenario: 非微信读书书单链接
- **WHEN** 用户输入或分享的内容不是微信读书书单链接
- **THEN** 系统 SHALL 拒绝进入导入保存流程，并展示可理解的错误反馈

### Requirement: 导入前展示预览
系统 SHALL 在保存前解析微信读书书单链接并展示导入预览，用户确认后才写入本地数据。

#### Scenario: 解析成功
- **WHEN** 系统成功解析微信读书书单链接
- **THEN** 系统 SHALL 展示书单标题、简介、书籍数量、书籍标题、作者和推荐语预览

#### Scenario: 用户取消导入
- **WHEN** 用户在导入预览页取消
- **THEN** 系统 MUST NOT 写入书单、书籍或书单关系数据

#### Scenario: 解析失败
- **WHEN** 链接不可访问、页面结构不支持或标题为空
- **THEN** 系统 SHALL 展示失败反馈，并且 MUST NOT 写入半成品数据

### Requirement: 确认导入后创建书单与关系
系统 SHALL 在用户确认后创建手动书单，并按 Android 对齐语义保存书籍与 relation 文本。

#### Scenario: 保存导入书单
- **WHEN** 用户确认导入预览
- **THEN** 系统 SHALL 创建一个手动书单，并写入解析出的标题与简介

#### Scenario: 保存导入书籍
- **WHEN** 导入书单包含本地不存在的书籍
- **THEN** 系统 SHALL 保存为可在书单中展示和恢复的占位书关系

#### Scenario: 保存推荐语
- **WHEN** 微信读书书单中的单本书包含推荐语或描述
- **THEN** 系统 SHALL 将该文本保存为对应 `collection_book` relation 文本，并在普通书单中展示为 `收藏理由`

#### Scenario: 事务失败
- **WHEN** 创建书单、保存书籍或写入关系的任一步骤失败
- **THEN** 系统 SHALL 回滚本次导入事务，避免留下部分书单数据

### Requirement: 导入流程遵守网络与数据边界
系统 SHALL 通过 Repository 或 Repository 管理的服务完成微信读书页面抓取、解析和保存。

#### Scenario: ViewModel 发起导入解析
- **WHEN** ViewModel 收到微信读书链接
- **THEN** ViewModel SHALL 调用 Repository 导入预览能力，而不是直接发起网络请求或解析 HTML
