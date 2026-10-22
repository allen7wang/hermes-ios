# Hermes iOS v3.4.0 验证记录

日期：2026-10-23

基线：v3.3.0 / `01e84514137a9e025a1d920d6f5ba8fef474db94`

## 交付范围

- 在同一连接、同一项目内选择目标资料及明确的对话集合，替换当前保存的资料引用。
- 支持进行中、归档与回收站混合选择、标题搜索、可见结果选择及隐藏选择提示，初始无目标、无对话选择。
- 检查每段对话替换前后的完整顺序、编号、篇数和字符量；目标已存在时按替换结果首次出现位置去重。
- 最终提交重算预算与方案、核对全部涉及资料和对话引用快照，单次原子保存后发布结果。
- 沿用 v1–v7 JSON 备份，无新增持久化字段、服务接口或依赖。

## 结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 307 项通过，0 失败、0 跳过 | 新增 26 项逻辑与 3 项布局检查；结果包无 runtimeWarnings |
| iOS Simulator Release | 编译通过 | 通用 iOS 模拟器目标，实际应用版本 3.4.0 |
| iOS 18.1 专项 | 58 项通过，0 失败、0 跳过 | 引用替换及已有资料/请求上下文检查；结果包无 runtimeWarnings |
| 布局截图 | 三张逐张检查 | 390 × 1100、1024 × 1200、390 × 1300 |
| 原生点击、真机触摸 | 未执行 | 本轮以自动测试及隔离布局证据交付 |

新增回归覆盖源位置、目标早于/晚于源时的首次出现去重、无源拒绝而不新增、混合状态、准确连接/项目范围、缺失资料、无效旧选择、50,000 字符边界与溢出；只读预览与全部涉及资料快照；显式子集与未选对话更新；完整引用、标题、状态、归属、永久删除及资料编辑后的过期方案；不相关资料编辑可保留；恢复保护；任一行超限整批拒绝；写入失败不发布；重启及 v7 编解码后的顺序、消息、工作区状态、收藏、日期、图片和草稿保留。

## 编译修正

首次编译在 AppModel 中的复合映射/排序表达式发生类型检查超时，未执行测试。将其拆成显式类型的数组、循环和排序后，使用最终源码重新编译与测试；初次失败不计入通过统计。最终日志为 `/private/tmp/hermes-v3-4-verified.log` 与 `/private/tmp/hermes-v3-4-ios-release-verified.log`。存储需要恢复时，替换入口直接显示不可用，避免把不可读状态当作零引用。

## 布局证据

使用隔离 UserDefaults、临时文件、无凭证示例数据；URLProtocol 守卫拒绝网络请求。图像由 Mac Catalyst XCTest 验证窗口生成，不是 iPhone/iPad 设备截图，也不证明实际点按、VoiceOver 或系统文件往返通过。

- [选择资料与对话](../preview/replacement-select-v3-4-demo.png)
- [替换前后方案 · 宽布局](../preview/replacement-review-wide-v3-4-demo.png)
- [替换前后方案 · 窄布局](../preview/replacement-review-compact-v3-4-demo.png)

## 复现

使用 Xcode 27.1（27A9275）。开发和发布验证在健康副本 `/private/tmp/hermes-v3-4-workspace` 完成；预期变更同步回原 iCloud 目录，替换前核对 v3.3 基线并保留原文件备份。原有四个重复 Swift 文件及本机数据不纳入发布。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-4-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v3-4-verified.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-4-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
```

专项使用本次新建的隔离 iPhone 16 Pro / iOS 18.1（22B81）；替换 UUID 后复现。结束后只清理本次设备，不重置已有模拟器。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<isolated-device-uuid>' \
  -derivedDataPath /private/tmp/hermes-v3-4-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:HermesTests/ProjectReferenceReplacementTests \
  -only-testing:HermesTests/ProjectReferenceReplacementModelTests \
  -only-testing:HermesTests/ProjectReferenceReplacementVisualTests \
  -only-testing:HermesTests/ProjectDocumentTests \
  -resultBundlePath /private/tmp/hermes-v3-4-ios-tests.xcresult test
```

结果包路径需尚不存在，依赖缓存位置可按本机调整。iOS 专项是另一平台上的执行，不与完整 Catalyst 数量相加。

## 限制

- 非草稿源码预览 prerelease，无签名 IPA，不代表 App Store 上架。
- 本轮未执行原生点击、VoiceOver、真机触摸、真实 Hermes API、跨设备恢复或系统文件往返。未验证 iOS 17、iOS 27 或完整 iOS 回归。
- 替换只影响当前保存的选择及后续请求；历史文字、编号和已发送资料不改写。字符量不是模型令牌容量，模型如何引用资料仍取决于服务端。
- 无一键撤销；可重新选择资料或使用备份。源资料和其他项目副本保留，未选对话不扩大到本次范围。
- 并发检查覆盖共享同一 AppModel 的窗口，不提供跨进程或跨设备锁。单次保存使用既有 conversations.json 原子写入；失败保留已发布状态，不新增多文件事务。
