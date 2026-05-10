# 跨端数据库 Room Canonical 同步 - Compose 到 SwiftUI 迁移总结

## 1. 学习背景
Android Room 与 iOS GRDB 都建立在 SQLite 之上，但框架层对 schema 的识别方式不同。跨端数据库迁移不能只看 SQL 查询是否能返回数据，还要保证同一份数据库文件能被两端框架安全打开。

这次 Database 基建收敛后的核心经验是：跨端数据库的事实源必须唯一。XMNote 选择 Android Room v40 schema JSON 作为物理合同，iOS 按这份合同创建和校验数据库，再在 Repository 和 UI 层处理平台表达差异。

## 2. Android Compose 开发者需要转变的视角
在 Android 端，Room 通过 Entity、DAO、Migration 和 `room_master_table` 管理 schema。开发者通常不会直接关心 SQLite 文件是否能被另一个框架打开。

迁移到 iOS 后，GRDB 不知道 Room Entity，也不会自动生成 Room 的 identity hash。因此 iOS 必须显式做三件事：
- 用 Room schema JSON 创建同等物理表结构。
- 写入 Room `room_master_table` 与 `user_version`。
- 在恢复外部备份前，用 staging 库完成 schema 与数据完整性校验。

这不是“把 Room 搬到 iOS”，而是让 iOS 生成的 SQLite 文件满足 Android Room 的识别合同。

## 3. 关键设计经验
### 3.1 schema 合同优先于手写建表
过去 iOS 手写 GRDB table builder，容易出现 nullable、外键、索引、默认值与 Android 不一致。Room canonical 方案改为直接读取 Android 导出的 JSON，减少人为漂移。

Compose 迁移类比：
- Android 的 `@Entity` 是开发者视角的模型。
- Room schema JSON 是跨端视角的合同。
- iOS 的 Record 只是读取合同后的平台模型，不应反过来定义物理 schema。

### 3.2 普通打开与备份恢复必须分层
普通 App 打开本机库时，只应该打开连接、执行本机 migration、补必要的内部标记。

备份恢复是外部输入，必须走 staging：
1. 解压临时库。
2. 校验版本与 schema。
3. 安全整理历史外键缺口。
4. 验证核心 Record 可解码。
5. 全部通过后替换正式库。

这和 Compose/Room 中“不要在 Activity 首屏加载时顺手修远端导入数据”是同一个原则：生命周期不同，副作用边界也不同。

### 3.3 nullable 不应用改表结构解决
Android Room 中很多文本列可以为 null。iOS 如果为了方便解码把列改成 `NOT NULL DEFAULT ''`，短期能少写可选处理，长期会破坏 Android Room schema validation。

正确做法是：
- 物理 schema 保持 Android nullable。
- Record 允许 nil。
- mapper 或 UI 层按业务场景显示空字符串、占位文案或空态。

### 3.4 tombstone 是恢复整理，不是业务数据
Android 历史备份可能存在缺失父行。iOS staging 恢复可以创建软删除 tombstone 父行来补齐外键闭包，但这些记录不能进入书架、统计、搜索或详情页。

对应到 Android 思维：tombstone 是同步/恢复协议的一部分，不是用户真实内容。

## 4. SwiftUI 侧接入边界
SwiftUI 页面和 ViewModel 不应该理解 Room schema、staging、tombstone 或外键修复。它们仍然只通过 Repository 获取 domain model。

正确边界：
- Database 层负责物理结构与恢复安全。
- Repository 层负责业务查询过滤和模型映射。
- ViewModel 负责页面状态。
- SwiftUI View 负责渲染。

这样即使数据库底层从手写 schema 切到 Room canonical，页面层也不需要知道实现细节。

## 5. 后续数据库升级工作法
当 Android 端修改 Entity 或 migration：
1. Android 提升 `DBConfig.DB_VERSION`。
2. Android 导出新版本 Room schema JSON。
3. iOS 更新 canonical schema 合同。
4. 双端验证新库、旧库迁移和备份恢复。
5. 如果两端审核不同步，低版本端阻断高版本备份恢复，本机继续可用。

这套流程把“代码是否同步发版”的不确定性，转成“数据库版本是否可识别”的明确产品规则。

## 6. 最小示例
Android Room schema 中 `note.content` 可为空：

```json
{
  "fieldPath": "content",
  "columnName": "content",
  "affinity": "TEXT"
}
```

iOS 不应把它建成 `TEXT NOT NULL DEFAULT ''`。更合理的处理是：

```swift
struct NoteRecord: FetchableRecord, PersistableRecord {
    var content: String?
}

struct NoteSummary {
    let contentText: String

    init(record: NoteRecord) {
        contentText = record.content ?? ""
    }
}
```

物理结构忠于 Room，界面表达由 iOS 自己完成。

## 7. 结论
跨端数据库同步的核心不是“Swift 写得像 Kotlin”，而是让两端承认同一份数据库事实。Room canonical schema 解决物理识别问题，staging 恢复解决外部备份安全问题，Repository 和 UI 映射解决平台表达问题。三者分清后，Database 包才有长期演进的基础。
