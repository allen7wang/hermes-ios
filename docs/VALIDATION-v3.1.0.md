# Hermes iOS v3.1.0 验证记录

日期：2026-10-23

基线：v3.0.0 / `03fd5820f3e56ecab2858b1cb38990c848bf9fd3`

## 交付范围

- 从项目聊天的独立按钮/消息菜单、消息库详情采集单条文字；预填来源项目编辑器，确认后才保存，不自动引用或发送。
- 独立查看并上下调整已选资料的请求顺序；保存后生效，预览与备份顺序一致。
- 资料编辑及引用选择保存前检查同一 App 内的窗口更新冲突，拒绝过期覆盖；支持复制输入和确认载入最新资料。
- 继续使用备份 v7 和现有资料预算，无新增持久化字段或依赖。

## 最终结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 235 项通过，0 失败、0 跳过 | 新增 12 项逻辑回归和 3 项布局检查；结果包无 runtimeWarnings |
| iOS Simulator Release 通用目标 | 编译通过 | 实际应用版本 3.1.0，无签名 |
| iOS 18.1 模拟器专项 | 44 项通过，0 失败、0 跳过 | iPhone 16 Pro，新建隔离设备；Debug，结果包无 runtimeWarnings |
| Mac Catalyst 原生点击 | 两次隔离会话通过 | 菜单采集保存、独立按钮采集保存、引用排序及冲突处理 |
| 布局截图 | 已逐张检查 | 390 × 844、1024 × 1100、390 × 1200；临时示例数据 |

逻辑回归覆盖采集不修改消息/项目/草稿；当前对话与来源项目分离；长消息完整预填且超限不截断；空消息/纯图片/过大消息拒绝；图片和备注排除；失联消息、回收站、未分配项目及过期连接；归档采集与确认后保存；资料旧快照拒绝覆盖、载入新快照后继续保存；空引用旧快照拒绝覆盖；引用重排后预览与 v7 备份顺序一致；项目不符时拒绝旧引用。

## 原生交互检查

使用独立临时 XCTest 宿主，将与发布版本逐文件一致的 `Hermes/*.swift` 放入隔离示例窗口；不使用真实账号、聊天或密钥，夹具会阻断网络请求。交互宿主及测试控制文件位于 `/private/tmp/hermes-v3-1-native-validation`，不纳入发布。

已通过原生工具实际点按并核对：

1. 从消息卡片菜单打开采集编辑器，正文与来源正确，确认保存后资料数从 2 变为 3；聊天草稿、原消息和原引用保持不变。
2. 将第一份引用下移并保存，返回后显示逆序结果，底层断言核对持久化选择。
3. 模拟同一模型被另一窗口更新后打开旧快照编辑器；输入新的未保存标题，保存按钮保持禁用，原正文与输入仍存在。
4. “载入最新资料”先显示确认；选择保留输入后文字不变，再确认载入后显示最新标题/正文，取消编辑保留已保存版本。
5. 原生检查发现正文右键会优先显示系统文字菜单，因此加入独立“存为项目资料”按钮；最终代码再次实际点按该按钮、确认保存并核对原草稿及引用不变。

临时宿主首次没有挂接实际 Scene 窗口，无法完成交互；修正宿主后重新运行并通过。最终原生结果包分别为 `/private/tmp/hermes-v3-1-native-final.xcresult` 和 `/private/tmp/hermes-v3-1-capture-button.xcresult`，各 1 项通过，不计入上述 235 项自动测试。模拟外部更新使用夹具触发，没有操作两个真实设备或检验跨进程写入。

## iOS 专项运行

本轮模拟器服务可用，已新建隔离 iPhone 16 Pro / iOS 18.1（22B81）运行 `KnowledgeIterationTests` 与 `ProjectDocumentTests`，44 项全部通过。44 项是另一平台上的专项执行，不并入 235 项完整 Catalyst 回归统计。没有重置已有模拟器；测试完成后仅删除本次创建的设备，结果包保留在 `/private/tmp/hermes-v3-1-ios-debug-tests.xcresult`。

最初使用 Release 配置运行测试时，`@testable` 无法导入未开启测试权限的应用模块，未执行测试；切换 Debug 配置后运行成功。Release 应用编译仍使用独立的原始配置，未因测试放宽发布构建设置。

## 截图

以下是 XCTest 在 Mac Catalyst 验证窗口生成的布局证据，不是 iPhone/iPad 设备截图。

- [消息采集编辑器](../preview/capture-v3-1-demo.png)
- [引用顺序整理](../preview/reference-order-v3-1-demo.png)
- [资料编辑冲突](../preview/edit-conflict-v3-1-demo.png)

## 复现自动测试与编译

开发及发布验证在 `/private/tmp/hermes-v3-1-workspace` 完成，避免原目录 iCloud 占位文件读取等待。最终源码同步回原目录并逐文件核对；原有文件保留在忽略的本地备份目录，四个重复 Swift 文件不纳入提交。原目录 Git 元数据的读取状态不作为发布验证结果。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-1-final-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v3-1-final.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-1-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
```

iOS 专项复现使用 Debug 配置和已有的隔离设备 UUID；替换下例的 UUID 后运行：

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v3-1-ios-test-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:HermesTests/KnowledgeIterationTests \
  -only-testing:HermesTests/ProjectDocumentTests \
  -resultBundlePath /private/tmp/hermes-v3-1-ios-debug-tests.xcresult test
```

结果包路径需尚不存在；依赖缓存位置可按本机调整。最终编译日志位于 `/private/tmp/hermes-v3-1-ios-release-final.log`。

## 限制

- 本轮使用 Xcode 27.1（27A9275），iOS 运行证据仅覆盖 18.1 模拟器上的 44 项专项；没有验证 iOS 17、iOS 27 的运行，也没有执行完整 235 项 iOS 回归。
- Mac Catalyst 原生检查不等同于 iPhone/iPad 触摸验收。消息库采集入口、系统文件往返、真机备份恢复、后台恢复和真机窄屏导航仍需补验。
- 未连接真实 Hermes API Server，未验证真实模型容量与引用质量，不含签名 IPA，也不表示已经上架 App Store。
- 冲突检查覆盖共享同一 AppModel 的窗口，不提供跨进程/跨设备并发锁。编辑器文字不自动保存为草稿，关闭前可复制保留。
- 采集来源是静态文字，调整引用顺序不会改写历史回复里的编号。资料上限及 v7 备份行为沿用 v3.0。
