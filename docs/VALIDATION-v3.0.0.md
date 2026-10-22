# Hermes iOS v3.0.0 验证记录

日期：2026-10-23

基线：v2.0.0 / `d04fe73a9a6071814242dc0483adf631d0152061`

## 交付范围

- 项目资料库：编写、搜索标题/正文、查看全文、编辑、复制及单篇 Markdown 导出。
- UTF-8 `.txt` / `.md`（含 BOM）导入，有限读取 256 KiB，后台处理、安全作用域访问、取消与过期结果检查；导入仅预填编辑器，确认保存才写入。
- 每段对话显式保存有序引用，最多 5 份、正文合计 50,000 字符；实际请求与预览共用资料选择和系统提示词准备逻辑，不自动携带未选资料。
- 资料原子保存、删除后全量解除引用、分支继承及跨项目归属清理；备份 v7、旧版读取、稳定映射与重复导入。

## 验证结果

| 检查 | 结果 | 范围 |
|---|---|---|
| Mac Catalyst XCTest | 220 项通过，0 失败、0 跳过 | 新增 29 项资料逻辑回归和 3 项布局检查；结果包无 runtimeWarnings |
| iOS Simulator Release 通用目标 | 编译通过 | 无签名，应用版本 3.0.0；没有运行 iOS 模拟器 |
| 布局截图 | 已检查 | 390 × 844 与 1024 × 1000，隔离示例数据 |
| 独立代码复核 | 已完成 | 请求内容、数据保留、关系映射、连接隔离、文件读取及编辑输入保留 |

关键回归覆盖：旧记录缺少资料字段；标题、正文、集合和选择预算；UTF-8/BOM 与错误格式；只携带所选全文且顺序一致；实际 JSON 请求与预览一致；资料变化采用最新正文；保存失败保留旧状态；连接隔离；同项目整理保留引用、换项目清空；分支继承；解散和删除资料保留原聊天与草稿；回收站引用预算；删除/导入中断恢复；v7 降级与失联引用拒绝；跨项目相同资料标识的独立映射；重复导入保留已有编辑及对话选择；生成回复时阻止修改资料与选择。

复核修正了文件读取占用主线程、旧选择视图保存时缺少动作内复验、详情分支消失可能关闭编辑器的问题；最终版本还区分自身文件选择器/编辑弹窗与导航离开，避免因呈现方式变化丢弃文件结果。该部分已编译及静态复核，真实系统选择器与多窗口点击仍需补验。

## 截图

以下由 XCTest 在 Mac Catalyst 验证窗口生成，使用临时文件、内存凭据和阻断网络的示例记录；不是 iPhone/iPad 设备运行或触摸验收截图。

- [项目资料库窄宽布局](../preview/knowledge-v3-demo.png)
- [对话引用选择宽布局](../preview/reference-selection-v3-demo.png)
- [带资料的上下文预览窄宽布局](../preview/reference-context-v3-demo.png)

## 验证路径与复现

开发和验证在 `/private/tmp/hermes-v3-workspace` 完成，避开原目录 iCloud 占位文件读取等待。已核对原目录 104 个基线文件与 v2.0.0 对象摘要一致；新版本源码同步回原目录后再次逐文件核对，原文件保留在忽略的本地备份目录。发布使用本机 Git 副本，不纳入原目录的四个重复 Swift 文件。原目录 Git 元数据的读取等待不作为发布验证结果。

最终测试结果包：`/private/tmp/hermes-v3-release.xcresult`。

iOS 最终 Release 编译日志：`/private/tmp/hermes-v3-ios-release-final.log`。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /private/tmp/hermes-v3-validation \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  SUPPORTS_MACCATALYST=YES CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath /private/tmp/hermes-v3-release.xcresult test

xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/hermes-v3-ios-release \
  -clonedSourcePackagesDirPath /private/tmp/hermes-v1-validation/SourcePackages \
  CODE_SIGNING_ALLOWED=NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile build
```

复现时结果包路径需尚不存在；依赖缓存路径可按本机位置替换。实际验证禁止自动改动已解析的依赖版本。

## 限制

- 本机 CoreSimulator 1171.7 与 Xcode 27.1（27A9275）要求的 1174.9.2 不匹配，未运行 iOS 模拟器，未重置或删除用户模拟器。
- 原生工具再次确认 Mac 锁屏，无法进行原生点击。系统文件选择器/导出器、资料编辑与取消、多窗口变更时输入保留及窄屏导航仍需原生验收；布局截图不能替代交互验收。
- 未连接真实 Hermes API Server；请求一致性使用 URLProtocol 模拟响应检查，没有验证真实模型容量、引用准确性、模型路由或网络稳定性。
- 未验收真机文件 App 导入/导出、JSON 备份往返、后台/锁屏恢复或签名分发。本版为 Xcode 源码预览版，不含签名 IPA，也不表示已上架 App Store。
- 资料库仅支持本机文本，不解析 PDF、Word、网页、图片或 OCR，不提供向量检索或跨设备同步。所选资料全文作为系统提示词的一部分发送；字符预算不是模型令牌预算，引用编号由模型生成。
- JSON 备份包含全部资料和引用选择，已发送给服务器的内容不会因本机删除而撤回。删除后导入旧备份可能补回资料定义，已有对话选择以本机状态为准。
