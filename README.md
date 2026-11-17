# iArchiver

一个以离线处理、简单界面和旧压缩包兼容为目标的原生 iOS 应用。商业模式按付费下载设计，无广告、账号、订阅或统计 SDK。

**当前交付是应用源码、双版本 Xcode 工程、经过 Windows 实测的原生引擎和 Mac 验证脚本。尚未运行 Xcode，尚无已签名 IPA，也尚未达到可提交 App Store 的状态。** 详细证据和剩余门槛见 [STATUS.md](STATUS.md)。

## 功能

- ZIP/ZIP64、7z、RAR/RAR5、TAR、TAR.GZ/TGZ、GZ、ISO9660 的浏览、选择提取和完整解压，具体边界如下。
- ZIP、7z、TAR、TAR.GZ、GZ 创建；ZIP AES-256、7z AES 与加密文件名。
- 文件名自动检测，以及 UTF-8、GB18030、GBK、Big5、CP932、CP437 手动选择；ZIP 编码选择提供名称样本。
- 按选定编码重新打包为标准 UTF-8 ZIP，保留原包，完整解码校验新包。可用于把旧编码包转成更便于系统工具识别的新包。
- 宽窗口左侧预览、右侧文件列表；窄窗口单列。iOS 27.1 使用公开的 reservedRegions 处理 Duo 折痕与摄像头区域；桌面折叠姿态使用上预览、下列表。
- ImageIO 图片缩略图与缩放、AVFoundation 音频播放/定位、Quick Look 其他类型预览。
- 系统文档选择器导入文件/文件夹、独立分卷选择入口、目录浏览、搜索、排序、多选、分享、重命名、删除、导出。
- 串行任务队列、进度、取消、内存内历史；导出重名支持保留两者、跳过、替换。导入及解压结果自动使用新名称。
- 可降低的条目/展开/预览限额；路径穿越、链接、特殊文件、名称冲突和异常展开比例检查。
- iOS 26+ 按系统授予情况使用 BGContinuedProcessingTask；旧系统使用有限后台时间，过期取消。没有真正断点续压或无限后台承诺。
- 简体中文与英文、系统深色模式、VoiceOver 标签和部分键盘快捷键。

| 能力 | App Store | Sideload |
| --- | --- | --- |
| ZIP / 7z / TAR / TAR.GZ / GZ 创建与解压 | 是 | 是 |
| ZIP AES、7z AES / 加密名称 | 是 | 是 |
| RAR / RAR5 基础解压 | libarchive，存在算法/固实包限制 | UnRAR 增强解码 |
| 加密 RAR / RAR5、RAR 固实包/分卷 | 不承诺；明确报错 | 已通过原生样本测试 |
| ISO9660 浏览、提取 | 是 | 是 |
| ISO9660 制作 | 未开放 | 已实现 |
| RAR 创建、UDF-only 镜像 | 不支持 | 不支持 |

两套构建的区别来自真实源码和链接配置。商店版不链接专用 UnRAR，不存在远程解锁或审核后开启开关。侧载也必须遵守组件许可，见 [DEPENDENCIES.md](DEPENDENCIES.md)。

## 在 Mac 上构建

最低部署版本为 iOS / iPadOS 18.0。**构建需要带 iOS 27.1 或更新 SDK 的 Xcode**，因为 Duo 的保留区域 API 在该 SDK 中提供；这不会把最低系统版本提升到 27.1。

使用 Apple silicon Mac；当前设备及模拟器切片均为 arm64。另需 Python 3.12+、CMake 3.24+ 和可下载锁定依赖的网络。Swift 和 Apple 编译器由 Xcode 提供。不需要 Homebrew 压缩库、CocoaPods、XcodeGen 或桌面解压命令行工具。工具链选择脚本自动选择满足条件的最高稳定 SDK；有意测试 beta 时需显式设置 DEVELOPER_DIR。

首次设置：

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r Scripts/requirements-dev.txt
export DEVELOPER_DIR="$(python Scripts/apple_toolchain.py)"
python Scripts/bootstrap.py
python Scripts/generate_resources.py
python Scripts/generate_project.py
```

执行完整 Apple 验证：

```bash
bash Scripts/validate_apple.sh
```

这会运行主机原生测试、Swift 核心 XCTest，构建 device/simulator 静态 XCFramework，再对两个 App Scheme 执行无签名的模拟器及设备构建，并检查设备产物中的 UnRAR 差异。所需 SDK 不存在时脚本明确失败，不会把跳过验证当作通过。

只生成 iOS 依赖与工程：

```bash
python Scripts/build_native.py --apple
python Scripts/generate_project.py
open iArchiver.xcodeproj
```

可选的 `--simulator-only` 仅适合模拟器开发；正式归档前必须重新生成完整 XCFramework。日志位于 `Build/logs`。

## 签名与导出

复制 `Config/Local.xcconfig.example` 为 `Config/Local.xcconfig`，填写自己的 Team ID 和 Bundle ID 前缀。该本地配置、私钥、证书、描述文件、IPA 与归档均已加入忽略列表。

两个 Scheme：`iArchiver-AppStore` 和 `iArchiver-Sideload`，使用独立 Bundle ID，可同时安装。完成上述 Apple 验证与签名配置后，可用 Xcode Organizer，或执行：

```bash
xcodebuild -project iArchiver.xcodeproj -scheme iArchiver-AppStore \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath Build/iArchiver-AppStore.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath Build/iArchiver-AppStore.xcarchive \
  -exportOptionsPlist Config/ExportOptions-AppStore.plist -exportPath Build/Export-AppStore

xcodebuild -project iArchiver.xcodeproj -scheme iArchiver-Sideload \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath Build/iArchiver-Sideload.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath Build/iArchiver-Sideload.xcarchive \
  -exportOptionsPlist Config/ExportOptions-Sideload.plist -exportPath Build/Export-Sideload
```

侧载导出配置使用 development/debugging 分发，安装设备和有效期由实际签名资质及描述文件决定。个人免费签名账户是否允许该导出方式应在自己的 Xcode 中确认；直接 Build & Run 与导出可分发 IPA 是两件事。

商店上架仍须完成 [发布检查](Docs/RELEASE.md)、加密出口合规回答、真机验收及开发者账户设置。工程没有替你声明加密出口豁免。

## Windows 验证

需要 Visual Studio 2022 的 C++ 桌面开发组件、CMake 及 Python：

```powershell
python -m venv .venv
.venv/Scripts/python.exe -m pip install -r Scripts/requirements-dev.txt
.venv/Scripts/python.exe Scripts/verify_local.py --build
```

此命令能够证明主机引擎和工程结构检查的结果，不能证明 Swift 类型检查、Apple 链接或 iPhone/iPad 界面可用。Windows DLL 仅用于开发测试，不会放入 iOS 应用。

## 开发入口

| 位置 | 内容 |
| --- | --- |
| `Sources/App` | SwiftUI、文件协调、预览、任务队列与后台请求 |
| `Sources/ArchiveKit` | 异步归档操作、编码采样、安全策略与布局几何 |
| `Native` | C ABI、libarchive、7z SDK 及侧载专用 UnRAR 适配 |
| `Scripts` | 锁定依赖、可重复安全补丁、原生构建、资源/工程生成、验证 |
| `Tests/native` | ctypes 调用真实二进制的集成测试 |
| `Tests/ArchiveKitTests` | Swift 核心与几何 XCTest、无用户数据的样本 |
| `Docs` | 发布、隐私、审核说明及真机验收草稿 |

生成的 Xcode 工程、资源和测试样本保留在项目中；增加 Swift 文件或修改资源源字典后重新运行对应生成脚本。`Vendor` 中保留公有领域 LZMA SDK 源码包，其他依赖由 SHA-256 锁定后下载。仓库没有选择应用自身的公开开源许可证。
