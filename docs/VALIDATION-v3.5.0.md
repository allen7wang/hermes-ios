# Hermes iOS v3.5.0 验证记录

日期：2026-10-23

基线：v3.4.0 / `1e6e307542a4460d424d17ab22396ee20b30a2b6`

## 交付范围

- 当前连接的本机消息库支持多选、当前结果选择与清空；搜索、收藏/全部、角色等筛选隐藏的选择仍计入操作，显示隐藏数量。最多 100 条，包含进行中与归档，排除回收站和其他连接。
- 检查所选完整消息后导出或复制 Markdown 汇编；按消息时间从新到旧稳定排序，包含来源对话、项目、标签、角色、UTC 时间与归档状态。收藏备注默认不包含，明确开启后才加入；图片只留占位说明。
- 批量收藏只为未收藏项添加收藏，保留既有日期与备注；批量取消收藏说明将移除的非空备注数量，再最终确认。提交前核对完整所选快照、连接名称和项目标识，单次原子保存后更新界面。
- 所选完整正文、备注与来源元数据最多 500,000 字符，生成 Markdown 最多 1,000,000 字符；超限整批拒绝，不截断。计数使用 Swift 字符数量，不表示模型令牌量。
- 没有新增持久化字段、依赖或服务接口。备份兼容读取 v1–v7，按内容使用最低所需版本；只含收藏时为 v2，含项目资料或引用时为 v7。

## 结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 339 项通过，0 失败、0 跳过 | 新增 14 项格式/边界、15 项模型与 3 项布局检查；结果包无 runtimeWarnings |
| iOS Simulator Release | 编译通过 | 通用 iOS 模拟器目标，实际应用版本 3.5.0 |
| iOS 18.1 专项 | 52 项通过，0 失败、0 跳过 | 新增消息批量检查及已有消息库回归；结果包无 runtimeWarnings |
| 布局截图 | 三张逐张检查 | 390 × 1100 两张、1024 × 1100 一张 |
| 原生点击、真机触摸 | 未执行 | 本轮按已授权的自动验收与发布范围交付 |

新增检查覆盖空选择、重复组合标识、跨对话同消息标识、100 条和 500,000 字符边界、完整长正文、备注默认排除/显式加入、图片占位、Markdown 元数据转义、稳定排序及输出上限。模型检查覆盖混合收藏状态、无变化不写文件、取消收藏的备注数量、原子写入失败、过期备注/标题/标签/归档/项目名称/同名项目归属、删除/回收站/其他连接、连接改名及切换、存储恢复保护，以及生成期间整理既有消息并保留新回复。重启、备份编解码、图片、消息、配置、日期、草稿和当前聊天保持均有检查。

导出使用打开时的不可变快照，来源后续变化不会自动改写汇编；需关闭后重新选择获取更新。备注开关与已生成文字绑定，旧版本计算结果不能覆盖新选择；文件与复制按钮使用同一份已完成文字。收藏提交则重新校验所有已选内容；未选消息新增或其他不相关设置变化不会扩大操作范围。

## 环境修复与复验

首次 Catalyst 编译因临时磁盘空间不足，模块产物写入失败，未执行测试。清理临时构建产物后，最终源码通过 339 项完整测试及 Release 构建。首次 iOS 专项控制台显示 52 项通过，但结果包因再次空间不足未完整保存（summary 为 unknown / 0），不计入验收。保留日志和结果包，清理旧版生成的 DerivedData，并在新建的隔离设备重新执行，以最终完整结果包为准；没有为环境问题改动应用源码。

## 布局证据

使用隔离 UserDefaults、临时文件和无凭证示例数据；URLProtocol 守卫拒绝网络请求。以下图像由 Mac Catalyst XCTest 验证窗口生成，不是 iPhone/iPad 设备截图，也不证明实际点按、VoiceOver 或系统文件往返已通过。

- [消息库多选 · 窄布局](../preview/message-batch-select-v3-5-demo.png)
- [完整消息汇编与备注开关 · 窄布局](../preview/message-batch-export-v3-5-demo.png)
- [取消收藏及备注影响检查 · 宽布局](../preview/message-batch-bookmarks-v3-5-demo.png)

## 复现

使用 Xcode 27.1（27A9275）。开发与验证在健康副本 `/private/tmp/hermes-v3-5-workspace` 完成；预期变更同步回原 iCloud 目录，替换前核对 v3.4 基线并保留原文件备份。原有四个重复 Swift 文件及本机数据不纳入发布。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-5-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v3-5-final.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-5-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
```

专项使用本次新建的隔离 iPhone 16 Pro / iOS 18.1（22B81），设备 UUID 为 `E75B4DF5-5EED-4AF3-8F67-7FCAEDFD07C6`。复现时替换为自己的隔离设备；结束后只清理本次设备，不重置已有模拟器。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v3-5-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:HermesTests/MessageLibraryBatchTests \
  -only-testing:HermesTests/MessageLibraryBatchModelTests \
  -only-testing:HermesTests/MessageLibraryBatchVisualTests \
  -only-testing:HermesTests/MessageLibraryTests \
  -resultBundlePath /private/tmp/hermes-v3-5-ios-verified.xcresult test
```

日志为 `/private/tmp/hermes-v3-5-final.log`、`/private/tmp/hermes-v3-5-ios-release.log` 和 `/private/tmp/hermes-v3-5-ios-verified.log`。结果包路径需尚不存在，依赖缓存路径可按本机调整。iOS 专项属于另一平台上的执行，不与完整 Catalyst 数量相加。

## 限制

- 非草稿源码预览 prerelease，无签名 IPA，不代表 App Store 上架。
- 本轮未执行原生点击、VoiceOver、真机触摸、真实 Hermes API、跨设备恢复或系统文件导出/导入往返；未验证 iOS 17、iOS 27 或完整 iOS 回归。
- Markdown 用于阅读与分享，不恢复对话结构、附件或收藏；完整迁移使用 JSON 备份。所选正文与明确加入的备注按原文输出，连接配置、项目资料库正文和未选消息不会自动附加。
- 取消收藏也会移除其备注，没有一键撤销；确认页展示数量与现有备注，可返回导出包含备注的汇编或使用备份。
- 并发检查覆盖共享同一 AppModel 的窗口，不提供跨进程或跨设备锁。保存使用既有 conversations.json 原子写入，失败不发布部分结果；不新增多文件事务。
