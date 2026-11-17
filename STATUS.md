# 实施状态与验证边界

记录日期：2026-11-17。源码编辑在 Windows，**编译与测试统一由 GitHub Actions 执行**。Apple 作业使用 `xcode-27` 的 Apple silicon 主机，现固定 Xcode 27.1 / iOS 27.1 SDK；此前也通过了 Xcode 27.2 的核心测试和四个 App 构建。最低部署仍为 iOS 18。尚无已签名发行包，尚未提交 App Store。

## 已有产物

- 两个原生 iOS App Target / shared Scheme、最低 iOS 18 的配置、带 iOS 27.1 Duo 公共 API 的布局源码。
- 原生文件浏览、左预览/右列表、图片/音频/Quick Look、编码样本、重打包、压缩/解压、导入/导出、队列、取消、后台接口、双语资源与原创图标。
- 依赖版本与哈希锁定、可重放的 libarchive 内存预算修改、双版本 C/C++ 适配、Apple XCFramework 构建脚本。
- 隐私清单、按构建区分的许可资源、签名/导出模板、无签名 Apple 验证入口和 CI 配置。
- 隐私政策、支持说明、商店文案、审核说明和发布检查草稿。

## 实际通过的检查

| 检查 | 结果及范围 |
| --- | --- |
| MSVC Release 编译 | App Store / Sideload 两个 ArchiveCore.dll 编译成功 |
| Actions Windows 回归 | 两版引擎编译及 21 项真实 C ABI 集成测试通过 |
| Actions macOS 回归 | 两版原生引擎编译及 21 项真实 C ABI 集成测试通过；ZIP Unicode 扩展 CRC 按原始名字节校验 |
| Apple 静态库 | arm64 iOS 与 arm64 Simulator 的两版 XCFramework 编译成功，依赖显式链接到锁定的静态库 |
| Swift 核心 XCTest | 26 项通过：11 项归档操作、9 项提取安全策略、6 项布局几何 |
| iOS Release App | App Store / Sideload 各自的 arm64 真机与模拟器 App，四个构建均成功 |
| 最终设备产物检查 | 真实可执行文件的 UnRAR 符号隔离、按版许可、隐私清单、iPhone / iPad 设备族、iOS 18 最低系统通过 |
| 原生 C ABI 集成测试 | 21 项通过，调用实际锁定的依赖实现 |
| 创建后读回 | ZIP、7z、TAR、TAR.GZ、GZ；侧载 ISO |
| 标准库互操作 | Python zipfile / tarfile / gzip 能读取普通输出；ZIP 中文/emoji 名称带有效 UTF-8 标志 |
| 加密与选择提取 | ZIP AES、7z AES/加密文件名/Unicode 密码；侧载 RAR4/RAR5 加密头、固实包和跨条目跳过 |
| 分卷 | 7z 字节分卷；侧载 RAR4 与 RAR5 固实分卷；拒绝使用未选择但同目录存在的下一卷 |
| 编码 | GB18030、Big5、CP932、CP437；中文与 emoji；ZIP Unicode Path 扩展的有效/失效 CRC |
| 格式边界与错误 | 上游 RAR4/RAR5/7z/ZIP64 样本、错误/缺失密码、未知数据、CRC 损坏、取消 |
| 限额 | SDK 临时输出限制；拒绝要求 1 GiB 字典的 LZMA ZIP |
| 流式处理 | 12 MiB 7z 数据的流式写入与解码后 SHA-256 一致 |
| 两版本差异 | 原生能力 JSON 与实际 UnRAR 导出符号一致，商店 DLL 无专用 UnRAR 入口，ISO 创建在商店桥接层拒绝 |
| 工程结构 | Swift 语法树、OpenStep 项目解析、所有 Swift 引用、两个 Scheme、许可资源归属、双语键、plist、隐私清单、1024 不透明 RGB 图标、Vendor 哈希 |

原生 Windows Release DLL 基线：商店约 1.31 MiB、侧载约 1.88 MiB。**这不是 iOS 下载体积或安装体积**；实际值须在 Apple 构建与 App Thinning 后测量。

Swift 核心代码与两版 App 现已通过 Apple 编译器和链接检查。原生操作在同步工作线程范围使用 UTF-8 locale，避免 Swift 线程初始 C/ASCII locale 导致名称损坏；文件指纹重新查询文件系统，避免复用 URL 缓存属性。模拟器运行结果以对应 Actions 阶段的真实结果为准，构建成功不代表界面验收通过。

## 发布前仍需完成

1. 完成 Actions 的模拟器运行验收，保存六组 XCUITest、启动截图及完整日志；不能用编译成功代替运行结果。
2. 验证 iOS 18 / 26 / 27，iPad 分屏、Duo 展开/闭合/桌面姿态、摄像头区域、旋转与 Dynamic Type。
3. 实测 BGContinuedProcessingTask 的注册、授予、进度、用户取消、锁屏、系统到期及拒绝时的有限后台回退。
4. 实测 iCloud / 第三方 File Provider 的下载、目录导入、协调、重名替换、磁盘满、授权撤回、断连、取消及清理。
5. 进行超过 4 GiB、10 万级条目、固实 7z 大文件与低内存设备测试；记录峰值内存、临时空间和耗时。
6. 与 Windows 常见工具、macOS Finder/Archive Utility 互相打开；验证 PNG/大图/WAV/M4A/损坏媒体及音频不可用时的提示。
7. 检查真实设备产物、Privacy Report、第三方许可清单、签名、实际体积、真机截图、TestFlight 和 App Store 配置。

## 已知边界及仍需继续的产品工作

- RAR 创建、UDF-only 镜像、光盘挂载/运行内容、受保护镜像解密均不支持。
- 商店版 RAR 是 libarchive 的基础能力，不包含加密 RAR 或所有固实方法；专用增强引擎仅在侧载编译。
- 手动编码主要作用于旧 ZIP/TAR；商店 RAR4 也可传递字符集。7z/RAR5 的 Unicode 名称优先，侧载 UnRAR 使用其自身的 Unicode 转换。
- ZIP64 和异常中央目录不做自动编码推测，交给底层与手动选择；无法保证自动猜测所有混合编码。非法 UTF-8 标志、头记录不一致等损坏不能一概“修复”。
- 支持读取 7z 字节分卷与已测试的 RAR 原生分卷；没有分卷创建，未承诺所有 ZIP 分卷结构。
- 7z 逐条预览/选择提取可能重复解码固实块；RAR 选择提取也可能先处理先前块。没有通用断点续压。
- 临时落盘受目录保护、输出限额及空间检查约束；256 MiB 是所配置的增强/LZMA 解码预算，不是进程全部内存的硬上限。大量元数据仍须压力和模糊测试。
- 现有重打包会生成并校验新副本；尚无原地修改压缩包、追加文件到原包、压缩包内批量改名功能。
- 当前为“系统选择器导入到应用副本”的模式，不是完整 File Provider 文件管理器；没有独立 Share Extension 或跨应用拖放导入实现。
- 任务队列与历史保存在内存，进程被终止后不自动恢复任务；临时 UUID 目录过期后清理。
- 两列的数学几何已通过 XCTest，真实设备交互与可访问性仍待验收。CI 界面自动化范围与诊断入口见 `Docs/CI.md`。

上述项目在 [PLAN.md](PLAN.md) 中仍作为发布目标保留，不能因当前源代码已创建就标为验收完成。
