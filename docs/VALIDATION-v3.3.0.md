# Hermes iOS v3.3.0 验证记录

日期：2026-10-23

基线：v3.2.0 / `a8b555f5d5fea4d34e63cb79f271431a3ae2e8ba`

## 交付范围

- 当前项目资料的已引用/未引用筛选、标题与引用数量排序、逐篇引用数量。
- 进行中、归档、回收站的当前资料选择及实际编号；关联对话和最新资料全文只读检查。
- 单篇与批量共用删除影响检查页，按对话去重并分类计数；最终删除检查资料和引用快照是否仍有效。
- 无新增存储字段、网络接口或依赖，沿用现有资料上限及 v1–v7 JSON 备份。

## 结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 278 项通过，0 失败、0 跳过 | 新增 23 项逻辑检查及 3 项布局检查；结果包无 runtimeWarnings |
| iOS Simulator Release 通用目标 | 编译通过 | 应用实际版本 3.3.0，无签名 |
| iOS 18.1 模拟器专项 | 43 项通过，0 失败、0 跳过 | 新增引用检查与已有批量操作；结果包无 runtimeWarnings |
| 布局截图 | 三张逐张检查 | 390 × 1100、1024 × 1100、390 × 1200 |
| 原生点击 / 真机触摸 | 未执行 | 本轮按自动测试及隔离布局证据交付 |

新增检查覆盖：

- 当前连接与项目双重隔离；nil/空选择；旧消息文字与编号不推断引用；归档和回收站优先级；重复对话/资料防重复计数；实际选择编号、稳定排序、标题正文查询和引用筛选组合。
- 只读查询与检查不写文件、不切换聊天或改动草稿；新增/移除引用、相关对话改名、归档/回收站和编号变化使旧删除检查失效；未选资料和收藏备注的独立编辑可保留。
- 所选资料修改、失联、连接切换、项目解散及恢复状态阻止清理；正常删除保留其他引用顺序、原消息/收藏、草稿、日期及其他项目数据，重新启动后结果一致；零引用资料删除与 v7 兼容。

原有批量删除中断恢复、备份迁移、容量与保存失败回归也继续执行。

## 布局证据

以下使用临时示例数据、独立 UserDefaults 与文件目录，网络守卫会拒绝请求。截图在 XCTest 的 Mac Catalyst 验证窗口生成；不是 iPhone/iPad 设备截图，也不证明实际触摸、菜单点按、VoiceOver 或系统文件往返通过。

- [资料库引用筛选](../preview/usage-library-v3-3-demo.png)
- [按状态检查关联对话](../preview/usage-detail-v3-3-demo.png)
- [删除前影响检查](../preview/deletion-review-v3-3-demo.png)

## 复现

Xcode 27.1（27A9275）。验证在本机健康副本 `/private/tmp/hermes-v3-3-workspace` 完成，最终将预期变更同步回原 iCloud 工作区；替换前核对 v3.2 基线内容，保留本地备份。四个原有重复 Swift 文件及本机数据不纳入发布。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-3-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v3-3-final.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-3-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
```

iOS 专项使用新建隔离 iPhone 16 Pro / iOS 18.1（22B81），结束后仅清理本次设备，不重置已有模拟器。替换 UUID 后复现：

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v3-3-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:HermesTests/ProjectDocumentUsageTests \
  -only-testing:HermesTests/ProjectDocumentUsageModelTests \
  -only-testing:HermesTests/ProjectDocumentUsageVisualTests \
  -only-testing:HermesTests/ProjectDocumentBatchTests \
  -resultBundlePath /private/tmp/hermes-v3-3-ios-tests.xcresult test
```

结果包路径需尚不存在，缓存位置可按本机调整。iOS 专项是另一平台执行，不与完整 Catalyst 测试相加计算。

## 限制

- 发布为非草稿源码预览 prerelease，无签名 IPA，不代表 App Store 上架。
- 未连接真实 Hermes API，未验证真实模型引用质量、真机备份、跨设备恢复或系统文件导出往返；本轮未执行原生点击、VoiceOver 与真机触摸。
- 引用是当前保存的选择，不是历史请求/版本追踪；只读对话里的资料正文是最新内容。未引用不能作为从未发送或没有历史用途的证明。
- 删除无法直接撤销，继续使用既有恢复事务；已发送给服务端的内容不撤回。并发检查限共享同一 AppModel 的窗口，不提供跨进程或跨设备锁。
- 未验证 iOS 17、iOS 27 运行或完整 iOS 回归，运行证据仅覆盖上述 iOS 18.1 专项。
