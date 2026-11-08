# Hermes iOS v4.0.1 模拟器预览包

日期：2026-11-09。应用版本 **4.0.1 / build 2**，Bundle ID 为 `com.a7w.hermes`。

本版基于 main 已有的远端图片发送提交 `0fcdfe66fa06ba86e61649ff3d77109f7eb0584e`，补齐可下载的 iOS 模拟器包；没有新增服务端依赖。发布继续标记为 prerelease。

## 下载与安装

[GitHub Release](https://github.com/allen7wang/hermes-ios/releases/tag/v4.0.1) 提供：

- `Hermes-4.0.1-iOS-Simulator-arm64.zip`：完整 `Hermes.app`，面向 Apple Silicon Mac 的 iOS 模拟器。
- `BUILDINFO.json`：版本、构建号、源码提交、Xcode / SDK、目标平台、架构、依赖锁文件及可执行文件的摘要。
- `SHA256SUMS`：三个附件的 SHA-256 校验值。
- `INSTALL.txt`：移动端验收台与 `simctl` 的安装步骤。

下载后先在附件目录执行 `shasum -a 256 -c SHA256SUMS`，再解压 ZIP。在移动端验收台选择「iOS 模拟器」，启动 / 连接后，通过「安装测试包」选择 `Hermes.app`。

这是 **iPhoneSimulator / arm64** 构建，不是能装到真实 iPhone 的 IPA，不包含个人签名、设备描述文件或账号凭据。构建部署目标为 iOS 17.0；本轮实际运行环境为 Xcode 27.2 / iOS 27.2 模拟器，其他运行时未追加验证。

## 纳入本版的现有功能

- 远端会话可选择单张照片，发送纯图片或图文。文字请求继续使用旧的字符串输入格式，图片请求使用内容分段。
- 发送失败后重新读取服务端消息，按已确认保存的内容恢复未发送的文字或图片；已保存内容不再重新放入待发送区。
- 发送前可预览和移除图片。历史图片展示以服务端返回内容为准，没有在本轮追加图片历史缩略图或 OCR。

## 本轮验证

| 检查 | 结果 |
| --- | --- |
| ARM64 iOS Simulator Release 构建 | 通过；实际版本 4.0.1 / build 2 |
| 包元数据与二进制 | `iPhoneSimulator`、`arm64`、Mach-O `IOSSIMULATOR`；无 `embedded.mobileprovision` |
| `SessionChatPayloadTests` | 3 项通过，覆盖纯文字、图文、纯图片载荷 |
| `RemoteImageSendTests` | 6 项通过，覆盖发送、空输入、失败恢复、已保存内容及非法图片 |
| iOS 27.2 定向 XCTest | 合计 9 项通过，0 失败、0 跳过 |
| 版本源 | Xcode 工程和工程生成脚本均为 4.0.1 / build 2 |
| 本地 Release 候选包安装与启动 | 通过；iOS 27.2 验收模拟器已显示工作台，无需开发服务器 |

本轮只重跑上述 9 项定向回归；v4.0.0 的 475 项历史结果不作为本版全量回归。网络测试使用 `URLProtocol` 替身及隔离存储，没有连接真实 Hermes Agent。

## 复现

从干净的发布标签检出打包：

```sh
git checkout v4.0.1
python3 tools/package_simulator.py
```

打包工具在构建前核对版本标签与当前提交一致、工作目录干净；构建固定使用已提交的 `Package.resolved`，不会自动升级依赖。输出位于 `build/release-v4.0.1/`。

定向回归：将 `<SIMULATOR_UDID>` 替换为自己的模拟器 ID，结果包路径需尚不存在。

```sh
xcodebuild -project Hermes.xcodeproj -scheme HermesTests \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
  -derivedDataPath build/simulator-tests -jobs 2 \
  -parallel-testing-enabled NO \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -only-testing:HermesTests/SessionChatPayloadTests \
  -only-testing:HermesTests/RemoteImageSendTests \
  -resultBundlePath build/simulator-tests.xcresult \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO test
```

## 验收范围

模拟器安装与启动用于确认包可以运行；不代表真实 Hermes API、照片系统选择器、消息与审批业务、系统文件往返或真机流程已完成验收。聊天与远端操作仍需在 App 中配置自己的服务地址和密钥。
