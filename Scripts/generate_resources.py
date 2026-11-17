#!/usr/bin/env python3
"""Generate original icon artwork, bilingual strings and public plist resources."""
from __future__ import annotations
import json
import pathlib
import plistlib
import struct
import zlib
from bootstrap import ROOT

# One source of truth prevents missing keys between the two shipping languages.
STRINGS = {
    "conflict.title": ("When Exported Names Exist", "导出文件重名时"),
    "conflict.rename": ("Keep Both (Rename)", "保留两者（重命名）"),
    "conflict.skip": ("Skip Existing", "跳过已存在项目"),
    "conflict.replace": ("Replace Existing", "替换已存在项目"),
    "conflict.skipped": ("Existing Item Skipped", "已跳过现有项目"),
    "conflict.help": ("Applies to the whole exported file or folder, including a folder's contents. Replacing removes the existing item after the new copy is prepared. Imports and extracted results keep both by default.", "此设置针对整个导出文件或文件夹，包括其中的内容。替换会在新副本准备完成后移除原项目。导入与解压结果默认保留两者。"),
    "action.importFolder": ("Import Folder…", "导入文件夹…"),
    "action.repack": ("Repack", "重新打包"),
    "task.repack": ("Repacking and Verifying…", "正在重打包并校验…"),
    "create.repackHelp": ("Creates a new archive from all or selected entries using the current filename encoding. ZIP uses standard UTF-8 names. Choose a new password here if the output should be encrypted; the original password is only used to read the source.", "按当前文件名编码，将全部或所选条目写入新压缩包。ZIP 使用标准 UTF-8 名称。需要加密输出时，请在此设置新密码；原密码仅用于读取源文件。"),
    "queue.title": ("Tasks", "任务"), "queue.empty": ("No Tasks Yet", "暂无任务"),
    "queue.queued": ("Queued", "排队中"), "queue.running": ("Running", "执行中"),
    "queue.completed": ("Completed", "已完成"), "queue.failed": ("Failed", "失败"),
    "queue.cancelled": ("Cancelled", "已取消"), "queue.clear": ("Clear History", "清除历史"),
    "background.subtitle": ("Working on your files", "正在处理文件"),
    "app.files": ("My Files", "我的文件"), "app.extracted": ("Extracted", "已解压"),
    "action.import": ("Import", "导入"), "action.volumes": ("Open Archive Volumes…", "打开压缩分卷…"),
    "action.search": ("Search files", "搜索文件"), "action.back": ("Back", "返回"),
    "action.done": ("Done", "完成"), "action.ok": ("OK", "好"), "action.cancel": ("Cancel", "取消"),
    "action.save": ("Save", "保存"), "action.create": ("Create", "创建"), "action.open": ("Open", "打开"),
    "action.preview": ("Preview", "预览"), "action.openArchive": ("Open as Archive", "作为压缩包打开"),
    "action.rename": ("Rename", "重命名"), "action.delete": ("Delete", "删除"),
    "action.share": ("Share", "分享"), "action.export": ("Save to Folder", "保存到文件夹"),
    "action.dismiss": ("Dismiss", "收起"), "action.select": ("Select", "选择"),
    "action.selectAll": ("Select All", "全选"), "action.sort": ("Sort", "排序"),
    "action.hidden": ("Show Hidden Files", "显示隐藏文件"), "action.settings": ("Settings", "设置"),
    "action.more": ("More", "更多"), "action.compress": ("Compress", "压缩"),
    "action.extract": ("Extract Selected", "解压所选"), "action.extractAll": ("Extract All", "全部解压"),
    "action.togglePreview": ("Show or Hide Preview", "显示或收起预览"), "action.apply": ("Apply", "应用"),
    "sort.name": ("Name", "名称"), "sort.size": ("Size", "大小"), "sort.date": ("Date Modified", "修改日期"),
    "field.name": ("Name", "名称"), "field.format": ("Format", "格式"),
    "field.compression": ("Compression Level", "压缩等级"), "field.encrypt": ("Encrypt with Password", "使用密码加密"),
    "field.password": ("Password", "密码"), "field.confirmPassword": ("Confirm Password", "确认密码"),
    "file.folder": ("Folder", "文件夹"), "file.blocked": ("Unsafe path or link — extraction blocked", "不安全路径或链接，已禁止解压"),
    "empty.title": ("Your files, in order", "让文件井井有条"),
    "empty.description": ("Import an archive or select files to compress. Everything stays on your device.", "导入压缩包，或选择文件进行压缩。所有操作均在设备上完成。"),
    "empty.search": ("No Matching Files", "没有匹配的文件"),
    "empty.search.description": ("Try another name or clear your search.", "请尝试其他名称，或清除搜索条件。"),
    "encoding.auto": ("Automatic", "自动"), "encoding.title": ("Filename Encoding", "文件名编码"),
    "encoding.help": ("Choose another encoding if filenames appear garbled. Applying reloads the archive without changing its contents.", "文件名乱码时，可尝试其他编码。应用后会重新读取列表，不会修改原压缩包。"),
    "encoding.inferred": ("This encoding was estimated. Check filenames before extracting.", "当前编码由自动推测得到，请在解压前核对文件名。"),
    "encoding.samples": ("Filename Preview", "文件名预览"),
    "password.help": ("The password stays in memory for this archive and is cleared when you close it.", "密码仅为当前压缩包保存在内存中，关闭后清除。"),
    "preview.title": ("A closer look", "先看一眼"),
    "preview.description": ("Choose a file to preview it here.", "选择文件后，可在此查看预览。"),
    "preview.preparing": ("Preparing Preview…", "正在准备预览…"),
    "preview.solidHint": ("Solid archives may need to decode earlier files first.", "固实压缩包可能需要先解码前面的文件。"),
    "preview.folder": ("Open this folder to see its contents.", "打开文件夹以查看其中的内容。"),
    "preview.unavailable": ("Preview Unavailable", "暂时无法预览"),
    "preview.zoom": ("Zoom", "缩放"), "preview.zoomIn": ("Zoom In", "放大"), "preview.zoomOut": ("Zoom Out", "缩小"),
    "preview.play": ("Play", "播放"), "preview.pause": ("Pause", "暂停"), "preview.position": ("Playback Position", "播放进度"),
    "preview.audioUnsupported": ("This audio format could not be played.", "暂时无法播放此音频格式。"),
    "task.import": ("Importing Files…", "正在导入文件…"), "task.open": ("Reading Archive…", "正在读取压缩包…"),
    "task.extract": ("Extracting…", "正在解压…"), "task.create": ("Creating Archive…", "正在创建压缩包…"),
    "task.export": ("Saving Files…", "正在保存文件…"), "task.delete": ("Deleting…", "正在删除…"), "task.done": ("Completed", "已完成"),
    "delete.confirm": ("Delete these files? This cannot be undone.", "删除所选文件？此操作无法撤销。"),
    "create.archive": ("Archive", "压缩包"), "create.security": ("Security", "安全"),
    "create.aesHint": ("Uses AES-256. Some system file managers cannot open encrypted ZIP files. Keep your password safe.", "使用 AES-256。部分系统文件管理器无法打开此类加密 ZIP，请妥善保存密码。"),
    "create.sevenZipAesHint": ("Uses AES-256 and encrypts filenames. Keep your password safe.", "使用 AES-256，同时加密文件名。请妥善保存密码。"),
    "create.gzipHint": ("GZ accepts one file. Choose TAR.GZ to compress a folder or multiple files.", "GZ 仅支持单个文件。压缩文件夹或多个文件时，请选择 TAR.GZ。"),
    "create.originalsKept": ("Original files are kept. Existing output names receive a numbered suffix.", "保留原始文件。输出重名时，自动添加编号。"),
    "error.title": ("Unable to Complete", "未能完成操作"), "error.archive": ("The archive could not be processed.", "无法处理此压缩包。"),
    "error.encoding": ("The filename encoding could not be read. Try selecting it manually.", "无法识别文件名编码，请尝试手动选择。"),
    "error.password": ("A password is required, or the password is incorrect.", "需要密码，或输入的密码不正确。"),
    "error.unsupported": ("This archive feature is not supported in this build.", "当前版本暂不支持此压缩包使用的功能。"),
    "error.unsafe": ("An unsafe path, link, or conflicting filename was blocked.", "已阻止不安全路径、链接或存在冲突的文件名。"),
    "error.limit": ("The operation exceeded a safety or preview limit.", "操作超过安全限制或预览大小限制。"),
    "error.changed": ("The source file changed. Open the archive again.", "源文件发生变化，请重新打开压缩包。"),
    "error.io": ("The file could not be read or saved.", "无法读取或保存文件。"),
    "error.space": ("There is not enough free space for this operation.", "可用空间不足，无法完成此操作。"),
    "error.exists": ("A file with that name already exists.", "已存在同名文件。"),
    "settings.application": ("Application", "应用"), "settings.version": ("Version", "版本"),
    "settings.edition": ("Edition", "版本类型"), "settings.engine": ("Archive Engine", "压缩引擎"),
    "settings.formats": ("Formats", "格式"), "settings.read": ("Open", "读取"), "settings.write": ("Create", "创建"),
    "settings.compatibility": ("RAR and ISO are read-only in the App Store edition. AES ZIP and encrypted 7z are supported. Encrypted RAR and unsupported filesystem variants are reported explicitly.", "App Store 版中的 RAR 和 ISO 仅支持读取。支持 AES ZIP 与加密 7z；加密 RAR 和不支持的镜像变体会明确提示。"),
    "settings.compatibilitySide": ("Includes encrypted RAR/RAR5 extraction and ISO9660 creation. RAR creation and UDF-only images are unavailable.", "支持加密 RAR/RAR5 解压及 ISO9660 制作。不提供 RAR 创建，不支持仅含 UDF 的镜像。"),
    "settings.privacy": ("Privacy", "隐私"), "settings.offline": ("Works Entirely Offline", "完全离线处理"),
    "settings.noAccount": ("No Account or Ads", "无需账号，无广告"),
    "settings.privacyDescription": ("Your files and passwords are not uploaded. Decrypted previews use temporary local storage and are cleared after use or when expired.", "文件和密码不会上传。解密后的预览保存在本地临时目录中，在使用结束或过期后清理。"),
    "settings.limits": ("Default Safety Limits", "默认安全限制"), "settings.expandedLimit": ("Expanded Data", "展开大小"),
    "settings.previewLimit": ("Single Preview", "单次预览"), "settings.entryLimit": ("Archive Entries", "条目数"),
    "settings.limitHelp": ("Lower limits can help on devices with less storage. Enhanced 7z/RAR and LZMA decoders use a 256 MiB budget; expansion ratio is capped at 5,000:1.", "存储较少的设备可选择更低限额。7z/RAR 增强引擎与 LZMA 解码预算为 256 MiB，展开比例上限为 5,000:1。"),
    "settings.licenses": ("Third-Party Licenses", "第三方许可"),
}


def write_plist(path: pathlib.Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


def generate_strings():
    for index, language in enumerate(["en", "zh-Hans"]):
        path = ROOT / "Resources" / (language + ".lproj") / "Localizable.strings"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("/* Generated by Scripts/generate_resources.py */\n" + "\n".join(
            json.dumps(key, ensure_ascii=False) + " = " + json.dumps(value[index], ensure_ascii=False) + ";"
            for key, value in sorted(STRINGS.items())) + "\n", encoding="utf-8")


def generate_icon():
    size = 1024
    # Original geometric archive box, rendered directly to RGB PNG without third-party assets.
    rows = []
    def rounded(x, y, left, top, right, bottom, radius):
        if x < left or x > right or y < top or y > bottom:
            return False
        cx = max(left + radius, min(right - radius, x))
        cy = max(top + radius, min(bottom - radius, y))
        return (x - cx) ** 2 + (y - cy) ** 2 <= radius ** 2
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            t = (x + y) / (size * 2)
            color = (int(12 + 8 * t), int(51 + 44 * t), int(88 + 55 * t))
            if rounded(x, y, 215, 300, 835, 805, 62): color = (9, 31, 57)
            if rounded(x, y, 200, 278, 824, 782, 62): color = (218, 240, 249)
            if rounded(x, y, 174, 242, 850, 390, 34): color = (246, 252, 255)
            if rounded(x, y, 424, 465, 600, 526, 20): color = (35, 113, 155)
            if 292 <= y <= 339 and 295 <= x <= 729: color = (111, 202, 218)
            row.extend(color)
        rows.append(row)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
    assets = ROOT / "Resources" / "Assets.xcassets"
    icon = assets / "AppIcon.appiconset"
    icon.mkdir(parents=True, exist_ok=True)
    (icon / "AppIcon.png").write_bytes(png)
    (icon / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2))
    (assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))
    accent = assets / "AccentColor.colorset"
    accent.mkdir(exist_ok=True)
    (accent / "Contents.json").write_text(json.dumps({"colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {"red": "0.075", "green": "0.443", "blue": "0.635", "alpha": "1.000"}}}], "info": {"author": "xcode", "version": 1}}, indent=2))


def generate_metadata():
    write_plist(ROOT / "Config" / "Info.plist", {
        "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "$(PRODUCT_NAME)", "CFBundleDisplayName": "$(PRODUCT_NAME)", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)", "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "LSRequiresIPhoneOS": True, "LSSupportsOpeningDocumentsInPlace": True, "UIFileSharingEnabled": True,
        "UILaunchScreen": {}, "UIApplicationSupportsIndirectInputEvents": True,
        "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
        "UIBackgroundModes": ["processing"],
        "BGTaskSchedulerPermittedIdentifiers": ["$(PRODUCT_BUNDLE_IDENTIFIER).archive.*"],
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "CFBundleDocumentTypes": [{"CFBundleTypeName": "Archives", "CFBundleTypeRole": "Editor", "LSHandlerRank": "Alternate", "LSItemContentTypes": ["public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive", "public.tar-archive", "org.gnu.gnu-zip-archive", "app.iarchiver.iso"]}],
        "UTImportedTypeDeclarations": [
            {"UTTypeIdentifier": "org.7-zip.7-zip-archive", "UTTypeDescription": "7z Archive", "UTTypeConformsTo": ["public.archive", "public.data"], "UTTypeTagSpecification": {"public.filename-extension": ["7z"], "public.mime-type": "application/x-7z-compressed"}},
            {"UTTypeIdentifier": "com.rarlab.rar-archive", "UTTypeDescription": "RAR Archive", "UTTypeConformsTo": ["public.archive", "public.data"], "UTTypeTagSpecification": {"public.filename-extension": ["rar"], "public.mime-type": "application/vnd.rar"}},
            {"UTTypeIdentifier": "app.iarchiver.iso", "UTTypeDescription": "ISO Disc Image", "UTTypeConformsTo": ["public.disk-image", "public.data"], "UTTypeTagSpecification": {"public.filename-extension": ["iso"], "public.mime-type": "application/x-iso9660-image"}},
        ],
    })
    write_plist(ROOT / "Resources" / "PrivacyInfo.xcprivacy", {
        "NSPrivacyTracking": False, "NSPrivacyTrackingDomains": [], "NSPrivacyCollectedDataTypes": [],
        "NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp", "NSPrivacyAccessedAPITypeReasons": ["C617.1", "3B52.1"]},
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace", "NSPrivacyAccessedAPITypeReasons": ["E174.1"]},
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults", "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]},
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategorySystemBootTime", "NSPrivacyAccessedAPITypeReasons": ["35F9.1"]},
        ],
    })
    for name, method in [("AppStore", "app-store-connect"), ("Sideload", "debugging")]:
        write_plist(ROOT / "Config" / ("ExportOptions-" + name + ".plist"), {
            "method": method, "signingStyle": "automatic", "manageAppVersionAndBuildNumber": False,
            "stripSwiftSymbols": True,
        })


def generate_notices():
    source = ROOT / ".deps" / "src"
    parts = ["iArchiver — third-party notices\n\nNo RAR encoder is included.\niArchiver modifies libarchive's XZ/LZMA decoding budgets; see Scripts/patch_dependencies.py. Upstream notices follow.\n"]
    for title, path in [("libarchive 3.8.11", source / "libarchive-3.8.11" / "COPYING"),
                        ("liblzma 5.8.4", source / "xz-5.8.4" / "COPYING"),
                        ("liblzma 0BSD license", source / "xz-5.8.4" / "COPYING.0BSD"),
                        ("zlib 1.4", source / "zlib-1.4" / "LICENSE")]:
        if not path.exists():
            if title == "liblzma 0BSD license":
                path = source / "xz-5.8.4" / "COPYING.0BSD"
            if not path.exists():
                raise RuntimeError(f"Missing dependency license: {path}. Run bootstrap.py first.")
        parts.append("\n" + "=" * 72 + "\n" + title + "\n\n" + path.read_text(encoding="utf-8"))
    sdk_notice = (source / "lzma-sdk-26.06" / "DOC" / "lzma-sdk.txt").read_text(encoding="utf-8")
    parts.append("\nLZMA SDK 26.06\n" + sdk_notice[:sdk_notice.index("LZMA SDK Contents")])
    # Include each unique per-file copyright preamble for the libarchive library.
    seen = set()
    for path in sorted((source / "libarchive-3.8.11" / "libarchive").glob("*.[ch]")):
        text = path.read_text(encoding="utf-8", errors="replace")
        start = text.find("/*")
        end = text.find("*/", start)
        if start < 0 or end < 0:
            continue
        notice = text[start:end + 2]
        if ("copyright" in notice.lower() or "public domain" in notice.lower()) and notice not in seen:
            seen.add(notice)
            parts.append("\n" + path.name + "\n" + notice + "\n")
    (ROOT / "Resources" / "ThirdPartyNotices.txt").write_text("\n".join(parts), encoding="utf-8")
    (ROOT / "Resources" / "UnRARLicense.txt").write_text((source / "unrar" / "license.txt").read_text(encoding="utf-8"), encoding="utf-8")


if __name__ == "__main__":
    generate_strings()
    generate_icon()
    generate_metadata()
    generate_notices()
    print("Generated bilingual strings, original RGB app icon, metadata, and notices.")
