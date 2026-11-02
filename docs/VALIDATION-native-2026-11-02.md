# 原生验收复验 · 2026-11-02

对应任务：[hermes-ios#1](https://github.com/allen7wang/hermes-ios/issues/1)。本轮继续使用 GitHub macOS runner 上的独立 iPhone 16 Pro / iOS 18.5（22F77）模拟器，Xcode 16.4（16F6）、macOS 15.8.2。交互由 XCUITest 执行，不代表真机触摸或真实 Hermes API 验收。

## 验收结果与来源

下列结果均来自最终产品提交 `b535433` 的同一次[完整运行](https://github.com/allen7wang/hermes-ios/actions/runs/41411899570)。聊天返回栏修正后的截图已复核，记录不混用旧提交的检查。

| 检查 | 结果 | 来源 |
| --- | --- | --- |
| 现有领域、模型及布局回归 | 475 通过，0 失败、0 跳过 | [摘要](evidence/native-2026-11-02/regression-summary.json) |
| iOS Simulator Release 构建 | 通过 | 同一完整运行的 Verify Release build 步骤、[步骤状态](evidence/native-2026-11-02/full-run-jobs.json) |
| 全部原生交互及系统文件往返 | 4 通过、1 失败、0 跳过 | [摘要](evidence/native-2026-11-02/native-run-summary.json) |

原生部分为 **4 通过、1 失败**：连接切换、项目/资料与归档范围、草稿重启恢复和写入失败保护通过；系统文件用例失败，不能称该轮整体通过。此前 `7e08707` 的文件用例曾等待已消失的 Browse 按钮失败，[早期摘要](evidence/native-2026-11-02/full-run-native-summary.json)保留这一结果；该目录恢复竞态已修正。

最终运行中导出成功；点选 JSON 后系统选择器仍未退出，补点一次后仍超时。未观察到该轮的导入预览，冲突与空安装恢复检查没有执行，不能称完整系统往返稳定通过。文件提供器存在条目 URL 解析失败的日志，见[诊断摘录](evidence/native-2026-11-02/file-provider-diagnostic.txt)；这尚不能证明是 App 导入逻辑的根因。

系统日志还记录了从已脱离层级的控制器呈现提示框的 UIKit 警告，见[运行时摘录](evidence/native-2026-11-02/runtime-diagnostic.txt)。该轮交互通过项不等于没有运行时警告，此问题仍需后续排查。

另试验了系统复制导入模式，[专项运行](https://github.com/allen7wang/hermes-ios/actions/runs/41409599807)为 0 通过、1 失败，见[摘要](evidence/native-2026-11-02/copy-picker-trial-summary.json)。该试验未通过原生文件用例，已在 `57bd1de` 回退。

## 系统备份往返

以下完整往返曾在 `bf011d5` 的[首轮复验](https://github.com/allen7wang/hermes-ios/actions/runs/41393761381)中通过，保留[当时摘要](evidence/native-2026-11-02/earlier-backup-run-summary.json)及[恢复截图](evidence/native-2026-11-02/earlier-backup-restored.png)。该轮整体原生仍为 4 通过、1 失败，后续复跑未稳定复现文件往返。操作通过产品的 fileExporter / fileImporter 和系统文件界面执行，未以直接调用导入模型替代点击操作：

1. 将 JSON 保存到“在我的 iPhone 上 → Hermes”，核对导出成功反馈。
2. 将本机草稿改为 `ORIGINAL-DRAFT-LOCAL`，从系统选择器打开旧备份并确认合并；核对保留 4 段已有对话及本机新草稿。
3. 使用新 run UUID 建立空安装数据，再从系统选择器导入同一文件；核对新增 2 个连接、4 段对话、3 份草稿、1 个项目及 1 份资料。
4. 切换至导入连接，从统一检索打开原草稿；核对 `ORIGINAL-DRAFT`、项目归属及“参考资料 1”。

该夹具没有图片、收藏或自建模板，上述原生往返不扩展为这些内容的系统交互验收。

## 导航与执行修正

- 保留底部标签选择，将整组标签页及其导航状态绑定到当前连接；切换时结束旧连接的整组页面，避免单独替换未显示的导航容器。工作台集中管理检索、全部对话、全部草稿、项目/资料详情及聊天导航；详情携带打开时的连接 ID。聊天保留原有隐藏系统导航栏的呈现方式。
- 删除工作台和检索页各自驱动详情跳转的状态，避免父路径清空时多个详情状态同时弹出页面。值导航与路径管理方式参考 [Apple 导航说明](https://developer.apple.com/documentation/swiftui/understanding-the-navigation-stack)。
- 在同一模拟器上的回归及原生测试统一使用本地 ad-hoc 签名；系统选择器等待明确的控件出现与可点按状态，缺少控件时停止，不通过整屏滑动寻找控件。
- 选择器会在导航栏出现后自动恢复上次文件夹。测试先等待 Hermes 文件夹，再按当前可见页面选择位置，避免等待已经消失的 Browse 按钮。选文件使用元素点按；首次点按后选择器仍未退出时最多补点一次，并保留诊断截图；仍未退出、没有预览或导入结果不符时照常失败。
- CI 在原生测试后输出结构化摘要，并继续保留完整 xcresult、日志、截图、辅助功能树和崩溃记录；复现命令见 [NATIVE-ACCEPTANCE.md](NATIVE-ACCEPTANCE.md)。

旧记录中“选择文件后仍停留在选择器”反映的是当时结果。复查[已签名的旧运行](https://github.com/allen7wang/hermes-ios/actions/runs/41291152187)可见两次导入已完成，随后在切换至导入连接并返回工作台时崩溃；不能将该运行记为完整恢复通过。更早的导航栏崩溃摘要保存在 [crash-before-fix.json](evidence/native-2026-11-01/crash-before-fix.json)。

## 本轮截图

- [切回原连接后继续新对话草稿](evidence/native-2026-11-02/connection-navigation-latest.png)
- [草稿写入失败阻止新对话](evidence/native-2026-11-02/draft-write-failure.png)
- [重启后完整草稿仍在](evidence/native-2026-11-02/draft-after-restart.png)
- [归档对话不可发送](evidence/native-2026-11-02/archived-read-only.png)
- [选择 JSON 后仍停留在选择器](evidence/native-2026-11-02/import-selection-pending.png)
- [修复前的旧项目页面残留](evidence/native-2026-11-02/before-navigation-reset.png)

截图已逐张检查；原始附件名、运行、提交及 SHA-256 见 [provenance.json](evidence/native-2026-11-02/provenance.json)。完整日志与 xcresult 由 CI 保留 14 天。

## 保留边界

本轮没有执行真实 Hermes API 对话、工具审批或真机触摸，也未生成签名 IPA。真实 API 继续按 [NATIVE-ACCEPTANCE.md](NATIVE-ACCEPTANCE.md) 的隔离服务步骤验收；本地拒绝网络的夹具不替代服务端验证。系统备份往返稳定性及真实 API 验收未完成前，Issue 保持打开。
