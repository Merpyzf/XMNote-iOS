## ADDED Requirements

### Requirement: 年度书单支持单本书年度点评
系统 SHALL 允许用户在年度书单详情页为单本书编辑关系文本，并在 UI 中将该文本称为 `年度点评`。

#### Scenario: 年度书单空点评入口
- **WHEN** 年度书单中的书籍没有 relation 文本
- **THEN** 书籍 Item SHALL 显示轻量入口 `添加年度点评`

#### Scenario: 年度书单已有点评展示
- **WHEN** 年度书单中的书籍已有 relation 文本
- **THEN** 书籍 Item SHALL 以标题 `年度点评` 展示该文本

#### Scenario: 编辑年度点评
- **WHEN** 用户点击年度书单 Item 的点评入口或已有点评区
- **THEN** 系统 SHALL 打开编辑面板，并使用 `添加年度点评` 或 `编辑年度点评` 作为语义文案

#### Scenario: 保存年度点评
- **WHEN** 用户保存年度点评
- **THEN** 系统 SHALL 通过 Repository 写回当前 collection-book relation 的文本，并显示年度点评语义的保存反馈

### Requirement: 普通书单与年度书单的 relation 文案保持区分
系统 SHALL 根据书单类型为同一 relation 文本使用不同产品语义，普通书单为 `收藏理由`，年度书单为 `年度点评`。

#### Scenario: 普通书单保持收藏理由
- **WHEN** 用户查看或编辑手动书单中的 relation 文本
- **THEN** 系统 SHALL 使用 `收藏理由`、`添加收藏理由`、`编辑收藏理由` 文案

#### Scenario: 年度书单使用年度点评
- **WHEN** 用户查看或编辑年度书单中的 relation 文本
- **THEN** 系统 SHALL 使用 `年度点评`、`添加年度点评`、`编辑年度点评` 文案

#### Scenario: 可访问性文案按语义区分
- **WHEN** VoiceOver 聚焦普通书单或年度书单中的 relation 文本
- **THEN** 系统 SHALL 分别朗读 `收藏理由` 或 `年度点评` 语义

### Requirement: 年度书单结构保持自动同步
系统 SHALL 保持年度书单成员由读完记录自动同步的产品语义，同时允许编辑年度点评。

#### Scenario: 年度书单不显示结构编辑操作
- **WHEN** 用户打开年度书单详情页
- **THEN** 系统 SHALL NOT 显示添加书籍、移出书籍、调整排序、删除书单或编辑书单标题简介的操作

#### Scenario: 年度书单状态表达自动同步
- **WHEN** 用户查看年度书单详情内容标题区
- **THEN** 系统 SHALL 使用 `自动同步` 语义表达书籍成员来自读完记录，而不是使用会否定点评编辑能力的 `只读`

#### Scenario: 年度点评不改变成员关系
- **WHEN** 用户新增、编辑或清空年度点评
- **THEN** 系统 MUST NOT 改变年度书单的成员、排序、读完年份或书籍阅读状态

### Requirement: 年度点评不新增数据库结构
系统 SHALL 复用现有 `collection_book.recommend` relation 字段保存年度点评，不新增数据库字段或迁移。

#### Scenario: 写入年度点评
- **WHEN** 用户保存年度点评
- **THEN** 系统 SHALL 更新当前 relation 的 `recommend` 文本

#### Scenario: 清空年度点评
- **WHEN** 用户保存空白年度点评
- **THEN** 系统 SHALL 清空当前 relation 的 `recommend` 文本，但 MUST NOT 移除该书籍与年度书单的关系
