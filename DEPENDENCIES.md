# 依赖与双版本分发记录

版本及原始来源以 `Dependencies.lock.json` 为准。`bootstrap.py` 先验证 SHA-256 再解包，不执行下载包内的脚本；构建只使用所列库源码。以下是工程集成记录，不构成法律意见或 App Store 许可批准。

| 组件 | 锁定版本 | 集成范围 | 原始许可与处理 |
| --- | --- | --- | --- |
| libarchive | 3.8.11 | 两版；ZIP、RAR 基础、TAR、GZ、ISO 读取及部分写入 | BSD 类许可，部分文件为其他宽松/公有领域或多重许可；保留 COPYING 及逐文件声明，BLAKE2 多重许可选择 CC0 路径 |
| liblzma / XZ Utils | 5.8.4 | 两版，仅 liblzma | 0BSD；不链接或分发 xz/xzgrep 等命令行工具 |
| zlib | 1.4 | 两版，仅静态库 | zlib 许可，保留原文 |
| LZMA SDK | 26.06 | 两版；Format7zR 源码子集加 7z AES 注册 | SDK 自身的公有领域说明；不以此替代完整 7-Zip 项目的许可，也不引入完整 7-Zip 二进制 |
| UnRAR | 7.3.2 | **仅 Sideload**，DLL API 解码子集 | 免费源码许可含禁止重建 RAR 压缩算法的限制；保留完整 license.txt 和适配源注释，不包含编码器 |

应用没有引入广告、分析、跨平台 UI、第三方音视频或网络服务 SDK。Python 测试工具只用于开发，不随 iOS 应用分发。

## 原生构建边界

- `IA_SIDELOAD=OFF` 不编译 `RARBridge.cpp` 和任何 UnRAR 源文件；`IA_SIDELOAD=ON` 才引入 `UnRAR.cmake`。App Store 仍保留独立的 libarchive RAR 基础读取器。
- ISO 创建由桥接层编译条件限制。ISO9660 本身没有被认定为侵权格式；商店版暂不开放制作是产品范围的保守选择。
- 不能只看可见按钮判断许可归属。主机测试验证真实能力与 UnRAR 符号差异；Apple 构建后还需检查最终设备产物及链接内容。
- 不在 iOS 启动桌面压缩 CLI、不下载可执行组件、不调用解压出的程序、不链接未选择的外部格式插件。
- 禁用 libarchive 的外部过滤器替代路径；桥接层只注册有限格式与内置过滤器。旧 7z 适配未注册，普通 7z 走 SDK。
- 对 libarchive 应用少量内存预算修改，记录在 `Scripts/patch_dependencies.py`。修改带标记、检查唯一上游文本并可重复执行；补丁指纹进入构建缓存键。
- 保留 SDK 的必要静态注册对象，因此使用 force-load；App 的 dead stripping 同时启用。实际 iOS 体积仍需测量。

## LZMA SDK Vendor 包

`Vendor/lzma-sdk-26.06.tar.gz` 是官方 SDK 压缩包中 `C`、`CPP`、`DOC` 目录的源码副本，保留原始内容与说明。上游 `.7z` 的 SHA-256 和 Vendor 包的 SHA-256 分别记录；Vendor 不含工具可执行文件。保留这个源包是为了让干净的 Mac 构建不依赖额外的 7z 命令行解压器。

升级时必须重新核验官方发布、源包哈希、SDK 公有领域范围和 `LZMASDK.cmake` 的唯一源文件匹配。不能直接把完整 7-Zip 项目源码或二进制替换进此位置。

## 随应用提供的声明

- `Resources/ThirdPartyNotices.txt`：两版共同资源，包含 libarchive、liblzma、zlib、SDK 及唯一逐文件版权前言。
- `Resources/UnRARLicense.txt`：只作为侧载 Target 的资源打包。源码目录可包含该声明，商店 .app 不应包含或链接相应专用实现。
- 升级任何依赖后重新生成声明，检查实际编译的文件和声明是否一致，再执行两版测试。

## 一手核验入口

- Apple App Review Guidelines: <https://developer.apple.com/app-store/review/guidelines/>
- libarchive 源码与许可: <https://github.com/libarchive/libarchive>
- XZ Utils 许可: <https://tukaani.org/xz/>
- zlib: <https://zlib.net/>
- LZMA SDK: <https://www.7-zip.org/sdk.html>
- UnRAR 源码: <https://www.rarlab.com/rar_add.htm>

侧载自签不改变任何第三方许可。正式发布前由发行方确认销售地区、第三方分发条款、商标及加密出口要求；本项目不会自动把未获得授权的能力放到任一产物。
