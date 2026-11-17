# 发布前检查

当前没有执行 App Store 提交、账户注册、付费购买或签名。下列事项在成功 Apple 构建及真机验收后落实。

## 构建与设备

- [ ] 使用允许提交的稳定 Xcode / iOS SDK；工程目前需要 iOS 27.1+ SDK、最低部署 18.0。
- [ ] `validate_apple.sh` 全部通过，保存 Swift XCTest、两个模拟器/设备构建、原生测试和链接检查日志。
- [ ] 完成 `DEVICE-ACCEPTANCE.md`，补齐 4 GiB 以上文件、10 万条目、低内存与云盘测试。
- [ ] 在真机确认 Duo 保留区域、iPad Split View、VoiceOver 和大字号；主界面布局不依赖固定机型分辨率。
- [ ] 测试 continued processing 的授权/拒绝/进度/取消/锁屏，不宣称无限后台或通用续压。
- [ ] 对实际 Release .app 记录大小、App Thinning 下载/安装估计、峰值内存、临时空间和耗时。
- [ ] 检查崩溃、线程、文件协调及主线程耗时；运行必要的 Apple 静态分析和 Instruments。
- [ ] 提供真实应用截图，不使用设计图冒充运行界面。

## 许可与隐私

- [ ] 按实际链接文件复核 `DEPENDENCIES.md`，确认商店 .app 无专用 UnRAR，两个构建能力与界面一致。
- [ ] 检查第三方声明完整，所有图标与视觉资源为自有或已获授权。
- [ ] 检查 Xcode Privacy Report、隐私清单和实际 Required Reason API 调用，确认原因与用途相符。
- [ ] 应用内无分析/广告/崩溃上传 SDK；若后续添加，应同时修改政策、清单及商店标签。
- [ ] 发行方填写并发布 `PRIVACY.md` 与 `SUPPORT.md` 中的信息，验证公开 HTTPS 页面可访问。
- [ ] ZIP/7z AES 属于应用实现的一部分；按 App Store Connect 实际问卷判断出口合规、销售地区及需提交的材料。
- [ ] 不因使用系统框架或开源库就预设 `ITSAppUsesNonExemptEncryption=false`；当前工程未写入该声明。

## 账户与商店条目

- [ ] 确认正式名称可用性、发行主体、Bundle IDs、Apple Developer Team、商标、版权年份及支持邮箱。
- [ ] 初版选择 **付费下载、无 IAP**；确定价格与销售地区，签署适用协议并完成税务/银行设置。
- [ ] 若改为免费试用 + 一次性 IAP，先实现 StoreKit、恢复购买及相应审核路径，再修改文案。
- [ ] 填写年龄分级、隐私标签和 App Store 描述；不把侧载专有功能写入商店版能力。
- [ ] 仅描述经过验证的 ISO9660 能力，明确 UDF-only 不支持；不暗示 RAR 创建、挂载或运行光盘内容。
- [ ] 填写审核联系信息，使用 `REVIEW-NOTES.md`，随附非敏感演示样本。
- [ ] 真实签名归档、验证、TestFlight、真机试用，再提交审核。自动化脚本不会替代审核批准。

## 构建后的材料

```bash
python3 Scripts/make_review_samples.py
```

需要先有可运行的主机原生库；该命令生成自有内容的样本 ZIP、旧编码 ZIP、加密 ZIP/7z、ISO 及使用说明，放在 `Build/ReviewSamples`。演示密码是公开样本密码，与任何用户数据无关。

正式提交时只附商店版已验证的样本；侧载版 ISO 制作是研发测试手段，商店版仍只读。不要将私钥、个人描述文件或带用户资料的归档上传到源码仓库或审核附件。

## 官方复核入口

- 审核规范：<https://developer.apple.com/app-store/review/guidelines/>
- Duo 适配：<https://developer.apple.com/iphone-duo/prepare/>
- ReservedRegion：<https://developer.apple.com/documentation/swiftui/reservedregion>
- 后台任务：<https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask>
- 隐私清单：<https://developer.apple.com/documentation/bundleresources/privacy_manifest_files>
- Required Reason API：<https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>
- 加密出口：<https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/>
- 隐私政策与标签：<https://developer.apple.com/app-store/app-privacy-details/>
