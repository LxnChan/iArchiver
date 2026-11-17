# GitHub Actions

编译、测试和验证产物统一通过 `.github/workflows/validate.yml` 生成。Windows 开发机负责源码编辑与工程生成，不执行本地构建或测试。

## 触发与执行

向 `main` 推送、打开或更新 Pull Request，以及 `workflow_dispatch` 均可触发 Validate。功能分支使用 PR 检查，避免每次提交重复启动两套 Apple 验证。并发控制会取消同一 Git ref 的旧运行；不同分支互不取消。工作流只有 `contents: read` 权限，不自动发布 Release、提交审核或使用签名秘密。

Apple 作业固定 `runs-on: xcode-27`，并通过 `IARCHIVER_XCODE_PATH` 固定公开的 Xcode 27.1，避免镜像新增工具链时无声改变验证环境。启动时要求 iOS SDK 27.1+，记录实际 Xcode、SDK、架构和模拟器。SDK 检测失败会在编译前停止。最低运行系统仍为 iOS / iPadOS 18.0。

1. SHA-256 验证锁定源码，生成并检查项目及资源。
2. 编译 macOS 主机原生引擎、arm64 iOS / Simulator XCFramework。
3. 运行真实 C ABI 归档集成测试与 Swift 核心 XCTest。
4. 分别构建 AppStore / Sideload 的 Release 设备和模拟器 App，保存 `.xcresult`。
5. 检查实际设备可执行文件中的 UnRAR 差异、许可、隐私清单、设备族和最低系统。
6. 三个独立 Apple 作业并行验证 iPhone、iPad、Duo，隔离 CoreSimulator 的进程、内存与磁盘状态；每台主机只运行一种机型，两版 App 各执行一次 Release XCUITest。不高于构建 SDK：普通 iPhone / iPad 使用 27.0 runtime，Duo 使用 27.1 runtime。Xcode 在独立构建目录对测试包进行仅限模拟器的 ad hoc 签名、安装和启动，不需要开发者证书。断言文件列表、大屏左预览/右列表、设置打开与实际版本值，保存 Browser / Settings 截图；缺少机型或任一断言失败都会使作业失败，并保留服务诊断。
7. 构建作业通过带 SHA-256 和源提交校验的归档传递原始四个 App、dSYM、XCFramework，保留执行权限。UI 作业不会改写这些未签名产物。仅在 Windows 回归、Apple 构建/核心测试和三组机型作业全部成功后，独立打包作业才发布最终验证包。

UI 作业将 `build-for-testing` 与 `test-without-building` 分开执行：每版冷构建限时 15 分钟，安装、界面执行及结果收集限时 10 分钟。Duo 的系统菜单可能触发 XCTest 的 60 秒动画等待，必须为默认系统交互与结果收集保留时间。两段分别保存日志和耗时，避免 SDK 模块首次编译挤占实际测试时间；未完成的测试仍视为失败。

另一个 Windows 作业在 GitHub 的 `windows-2022` 机器编译两种原生引擎并运行跨平台回归。依赖缓存按 OS、CPU 架构、实际 Xcode 版本、锁文件、原生源码及构建/补丁脚本隔离。缓存恢复后仍进行源码哈希验证；桥接层每次调用 CMake 更新。

## 下载产物

打开成功运行页面，进入 **Artifacts**：

| 名称 | 内容 |
| --- | --- |
| `unsigned-apple-builds` | 两种设备 IPA、arm64 模拟器 App ZIP、dSYM、XCFramework、SHA-256 与提交清单 |
| `apple-build-diagnostics-*` | 工具链、原生/Swift 核心 XCTest 日志、四个 Release 构建结果 |
| `apple-ui-diagnostics-iPhone-*` / `iPad-*` / `Duo-*` | 对应机型的两份 Release UI `.xcresult`、截图及服务诊断 |
| `apple-build-inputs` | 同一次运行内传递的原始未签名构建目录与 SHA-256 / 提交清单；尚未代表 UI 验收通过 |
| `windows-build-logs` | Windows 原生编译日志 |

默认保留 14 天。失败运行也上传已有诊断；未完成或被取消的运行不能提供完整验证证据。

设备 IPA **未经签名**，需要自己的 Apple 签名证书、Bundle ID、权限与描述文件，不能直接安装或上传 App Store Connect。模拟器 App 为 arm64，需要对应 Mac 模拟器环境。源码仓库不存放私钥、证书和个人描述文件。

## 发布边界

CI 界面测试覆盖启动、布局和基本导航，不等同于实际设备验收、Duo 全姿态测试、iCloud / 第三方 File Provider 测试或大文件压力测试。系统向下兼容由部署配置和可用性检查保障，iOS 18 / 26 的真实运行验收仍需补齐。详见 `DEVICE-ACCEPTANCE.md`。

正式签名、TestFlight 和 App Store 发布须另行配置开发者账户与受保护的签名流程。当前验证工作流不申请证书、不导入私钥、不自动发布。
