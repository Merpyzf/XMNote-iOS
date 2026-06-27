## ADDED Requirements

### Requirement: 书单详情提供当前书单导出入口
系统 SHALL 在书单详情页右上角更多菜单中提供 `导出此书单` 入口，并将该入口表达为当前书单级操作。

#### Scenario: 手动书单显示导出入口
- **WHEN** 用户打开已加载完成的手动书单详情页
- **THEN** 更多菜单 SHALL 显示 `导出此书单`

#### Scenario: 年度书单显示导出入口
- **WHEN** 用户打开已加载完成的年度书单详情页
- **THEN** 更多菜单 SHALL 显示 `导出此书单`

#### Scenario: 导出入口不进入高频浮层
- **WHEN** 用户查看书单详情页
- **THEN** `导出此书单` SHALL NOT 显示在底部 Liquid Glass `添加书籍` 浮层中

#### Scenario: 导出入口不进入书籍行菜单
- **WHEN** 用户打开书单内单本书的 context menu 或 swipe action
- **THEN** 系统 SHALL NOT 在该书籍行操作中显示整本书单的导出入口

### Requirement: 导出入口在导出模块未完成时给出占位反馈
系统 SHALL 在用户点击 `导出此书单` 时给出非打断式占位反馈，并且 MUST NOT 启动未完成的导出流程。

#### Scenario: 点击导出入口
- **WHEN** 用户点击 `导出此书单`
- **THEN** 系统 SHALL 显示说明导出模块迁移中的顶部反馈

#### Scenario: 不打开未完成流程
- **WHEN** 用户点击 `导出此书单`
- **THEN** 系统 MUST NOT 打开系统分享面板、文件选择器、个人页批量导出占位页或真实导出任务

#### Scenario: 写操作进行中
- **WHEN** 书单详情页正在执行添加、保存、排序或删除类写操作
- **THEN** `导出此书单` 入口 SHALL 被禁用或阻止重复触发

#### Scenario: 空书单点击导出入口
- **WHEN** 用户在没有书籍的书单详情页点击 `导出此书单`
- **THEN** 系统 SHALL 给出不会暗示已成功导出的占位反馈
