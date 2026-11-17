# GitHub Actions

编译、测试和验证产物统一通过 `.github/workflows/validate.yml` 生成。Windows 开发机负责源码编辑与工程生成，不执行本地构建或测试。

## 触发与执行

推送、Pull Request 和 `workflow_dispatch` 均可触发 Validate。并发控制会取消同一 Git ref 的旧运行；不同分支互不取消。工作流只有 `contents: read` 权限，不自动发布 Release、提交审核或使用签名秘密。

Apple 作业固定 `runs-on: xcode-27`，并通过 `IARCHIVER_XCODE_PATH` 固定公开的 Xcode 27.1，避免镜像新增工具链时无声改变验证环境。启动时要求 iOS SDK 27.1+，记录实际 Xcode、SDK、架构和模拟器。SDK 检测失败会在编译前停止。最低运行系统仍为 iOS / iPadOS 18.0。

1. SHA-256 验证锁定源码，生成并检查项目及资源。
2. 编译 macOS 主机原生引擎、arm64 iOS / Simulator XCFramework。
3. 运行真实 C ABI 归档集成测试与 Swift 核心 XCTest。
4. 分别构建 AppStore / Sideload 的 Release 设备和模拟器 App，保存 `.xcresult`。
5. 检查实际设备可执行文件中的 UnRAR 差异、许可、隐私清单、设备族和最低系统。
6. 在不高于构建 SDK 的 iOS 27 模拟器中选择 iPhone、iPad、Duo，两个版本分别执行 XCUITest。Xcode 27.1 对应普通 iPhone / iPad 的 27.0 runtime 和 Duo 的 27.1 runtime。先独立安装/启动 Release App 并截图，再用仅限模拟器的 ad hoc 签名运行 Debug UI 测试，不需要开发者证书。断言启动、文件列表、大屏左预览/右列表、设置打开与版本标识。任一类别缺失或断言失败都会使作业失败；安装或启动失败也保存模拟器服务日志。
7. 仅在前述阶段全部成功后打包未签名产物。

另一个 Windows 作业在 GitHub 的 `windows-2022` 机器编译两种原生引擎并运行跨平台回归。依赖缓存按 OS、CPU 架构、实际 Xcode 版本、锁文件、原生源码及构建/补丁脚本隔离。缓存恢复后仍进行源码哈希验证；桥接层每次调用 CMake 更新。

## 下载产物

打开成功运行页面，进入 **Artifacts**：

| 名称 | 内容 |
| --- | --- |
| `unsigned-apple-builds` | 两种设备 IPA、arm64 模拟器 App ZIP、dSYM、XCFramework、SHA-256 与提交清单 |
| `apple-diagnostics-*` | 工具链与编译日志、Swift 核心 JUnit XML、Release 构建结果、六份 UI 测试 `.xcresult`（含截图） |
| `windows-build-logs` | Windows 原生编译日志 |

默认保留 14 天。失败运行也上传已有诊断；未完成或被取消的运行不能提供完整验证证据。

设备 IPA **未经签名**，需要自己的 Apple 签名证书、Bundle ID、权限与描述文件，不能直接安装或上传 App Store Connect。模拟器 App 为 arm64，需要对应 Mac 模拟器环境。源码仓库不存放私钥、证书和个人描述文件。

## 发布边界

CI 界面测试覆盖启动、布局和基本导航，不等同于实际设备验收、Duo 全姿态测试、iCloud / 第三方 File Provider 测试或大文件压力测试。系统向下兼容由部署配置和可用性检查保障，iOS 18 / 26 的真实运行验收仍需补齐。详见 `DEVICE-ACCEPTANCE.md`。

正式签名、TestFlight 和 App Store 发布须另行配置开发者账户与受保护的签名流程。当前验证工作流不申请证书、不导入私钥、不自动发布。
