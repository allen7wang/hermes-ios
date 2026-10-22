# Hermes iOS v3.2.0 验证记录

日期：2026-10-23

基线：v3.1.0 / `6faf59afe17fa4e519e400bf9adc746f3f6c07b5`

## 交付范围

- 项目资料多选、搜索结果选择/取消、隐藏选择提示及清空选择。
- 检查已选资料快照后，复制完整汇编或导出 Markdown 文件。
- 在同一连接的项目间复制资料，确认前后均检查目标容量，保存后提供独立副本。
- 确认后批量删除资料，统一清理进行中、归档和回收站对话引用，并支持中断恢复。
- 沿用现有资料上限和 v7 JSON 备份，无新增持久化字段或第三方依赖。

## 结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 252 项通过，0 失败、0 跳过 | 新增 14 项逻辑回归和 3 项布局检查；结果包无 runtimeWarnings |
| iOS Simulator Release 通用目标 | 编译通过 | 应用实际版本 3.2.0，无签名 |
| iOS 18.1 模拟器专项 | 46 项通过，0 失败、0 跳过 | `ProjectDocumentBatchTests` 与 `ProjectDocumentTests`；结果包无 runtimeWarnings |
| Mac Catalyst 原生点击 | 未完成 | 宿主已启动，原生工具检测到锁屏，停止交互验收 |
| 布局截图 | 三张逐张检查 | 390 × 1000、1024 × 1000、390 × 1000 |

逻辑回归覆盖全部 20 篇的批量选择、空/缺失/重复选择拒绝；完整正文与检查顺序导出；独立标识和时间、同名项及重复复制；来源过期检查与未选资料编辑；同项目/失联项目/过期连接拒绝；最新目标篇数和字符容量、边界及整批拒绝；写入失败不发布结果；批量删除后的剩余引用顺序、聊天/收藏/草稿保留；旧确认和缺失资料拒绝；中断日志恢复；复制副本的 v7 跨安装备份迁移与来源删除后的独立性。

## 原生交互检查

临时 XCTest 宿主位于 `/private/tmp/hermes-v3-2-native-validation`，只使用临时文件和示例数据，网络协议会拒绝请求。生产视图与发布源码逐文件一致。宿主和控制文件均不纳入发布，也不计入 252 项自动测试。

宿主已成功启动，但原生工具检测到 Mac 锁屏，且自动解锁因物理输入而暂停。用户明确选择先完成自动验收与发布，因此中止本次交互会话，没有点按多选、复制、删除确认框或系统文件导出面板。该中止会话不作为通过证据，`/private/tmp/hermes-v3-2-native.xcresult` 不计入测试统计。

批量操作的数据行为由上述自动测试覆盖；窄宽布局截图已经逐张检查。系统文件选择、保存及重新读取的完整往返、实际 VoiceOver 导航和 iPhone/iPad 触摸仍待验证。

## 截图

以下为 Mac Catalyst 验证窗口的布局证据，不是 iPhone/iPad 设备截图。

- [资料搜索多选](../preview/batch-v3-2-demo.png)
- [项目复制与容量](../preview/copy-v3-2-demo.png)
- [资料汇编检查](../preview/export-v3-2-demo.png)

## 复现

使用 Xcode 27.1（27A9275）。开发与发布验证在本机健康副本 `/private/tmp/hermes-v3-2-workspace` 完成；最终源码同步回原 iCloud 工作区，替换前核对基线文件内容并保留本地备份。原目录四个重复 Swift 文件及本机数据不纳入发布。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-2-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v3-2-final.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-2-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
```

iOS 专项使用新建隔离 iPhone 16 Pro / iOS 18.1（22B81）。替换下例 UUID 后执行；46 项为另一平台专项执行，不与 252 项相加计算。本次创建的设备在测试结束后单独清理，不改动已有模拟器。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v3-2-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:HermesTests/ProjectDocumentBatchTests \
  -only-testing:HermesTests/ProjectDocumentTests \
  -resultBundlePath /private/tmp/hermes-v3-2-ios-tests.xcresult test
```

结果包路径需尚不存在，依赖缓存位置可按本机调整。Catalyst 结果包为 `/private/tmp/hermes-v3-2-final.xcresult`，Release 日志为 `/private/tmp/hermes-v3-2-ios-release.log`。

## 限制

- 无签名 IPA；发布类型继续为 Xcode 源码预览 prerelease，不代表 App Store 上架。
- 未连接真实 Hermes API，未验证真实服务端、模型引用质量、真机备份及 iPhone/iPad 触摸交互。本轮仅完成自动测试与布局检查，未完成原生点击及系统文件导出往返。
- 批量操作在当前连接内完成，副本独立，同名项不会自动合并；Markdown 汇编不保留项目结构和引用关系，完整恢复使用 JSON 备份。
- 资料检查覆盖共享同一 AppModel 的窗口；不提供跨进程/跨设备并发锁。导出快照在检查页打开后固定，重新打开才获取最新正文。
- 本轮不验证 iOS 17、iOS 27 运行或跨设备同步。
