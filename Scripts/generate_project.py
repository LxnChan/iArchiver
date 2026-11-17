#!/usr/bin/env python3
"""Deterministically generate an Xcode project without XcodeGen or Ruby gems."""
from __future__ import annotations
import hashlib
import json
import pathlib
import xml.etree.ElementTree as ET
from bootstrap import ROOT


def identifier(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def serialize(value, depth=0):
    indent = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (depth + 1) + json.dumps(str(key)) + " = " + serialize(item, depth + 1) + ";\n" for key, item in value.items()) + indent + "}"
    if isinstance(value, list):
        return "(\n" + "".join("\t" * (depth + 1) + serialize(item, depth + 1) + ",\n" for item in value) + indent + ")"
    if isinstance(value, int):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def generate():
    objects = {}
    def add(key, isa, **fields):
        result = identifier(key)
        objects[result] = dict(isa=isa, **fields)
        return result
    def reference(path, filetype):
        return add("file:" + path, "PBXFileReference", lastKnownFileType=filetype, path=path, sourceTree="<group>")
    swift_files = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "Sources").rglob("*.swift"))
    swift_refs = [reference(path, "sourcecode.swift") for path in swift_files]
    ui_ref = reference("Tests/UITests/BrowserUITests.swift", "sourcecode.swift")
    asset_ref = reference("Resources/Assets.xcassets", "folder.assetcatalog")
    privacy_ref = reference("Resources/PrivacyInfo.xcprivacy", "text.xml")
    notice_ref = reference("Resources/ThirdPartyNotices.txt", "text")
    unrar_ref = reference("Resources/UnRARLicense.txt", "text")
    strings = []
    for language in ["en", "zh-Hans"]:
        strings.append(add("strings:" + language, "PBXFileReference", lastKnownFileType="text.plist.strings", name=language, path=f"Resources/{language}.lproj/Localizable.strings", sourceTree="<group>"))
    string_group = add("strings-group", "PBXVariantGroup", children=strings, name="Localizable.strings", sourceTree="<group>")
    resources = [asset_ref, privacy_ref, notice_ref, string_group]
    info_ref = reference("Config/Info.plist", "text.plist.xml")
    base_config = reference("Config/Base.xcconfig", "text.xcconfig")
    configs = {name: reference(f"Config/{name}.xcconfig", "text.xcconfig") for name in ["AppStore", "Sideload"]}
    target_ids, ui_targets, products, frameworks = [], [], [], []
    for target_name, edition, product in [("iArchiver-AppStore", "AppStore", "iArchiver"), ("iArchiver-Sideload", "Sideload", "iArchiver Sideload")]:
        variant = edition.lower()
        product_ref = add("product:" + edition, "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path=product + ".app", sourceTree="BUILT_PRODUCTS_DIR")
        products.append(product_ref)
        framework_ref = reference(f"Build/Apple/ArchiveCore-{variant}.xcframework", "wrapper.xcframework")
        frameworks.append(framework_ref)
        source_builds = [add(f"source-build:{edition}:{ref}", "PBXBuildFile", fileRef=ref) for ref in swift_refs]
        target_resources = resources + ([unrar_ref] if edition == "Sideload" else [])
        resource_builds = [add(f"resource-build:{edition}:{ref}", "PBXBuildFile", fileRef=ref) for ref in target_resources]
        sources = add("sources-phase:" + edition, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=source_builds, runOnlyForDeploymentPostprocessing=0)
        # Libraries are force-loaded via the per-SDK xcconfig, retaining codec registration objects.
        links = add("frameworks-phase:" + edition, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
        resource_phase = add("resources-phase:" + edition, "PBXResourcesBuildPhase", buildActionMask=2147483647, files=resource_builds, runOnlyForDeploymentPostprocessing=0)
        configurations = []
        for name in ["Debug", "Release"]:
            settings = {"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if name == "Debug" else "-O", "DEBUG_INFORMATION_FORMAT": "dwarf" if name == "Debug" else "dwarf-with-dsym"}
            if name == "Debug":
                settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) DEBUG"
            configurations.append(add(f"config:{edition}:{name}", "XCBuildConfiguration", baseConfigurationReference=configs[edition], buildSettings=settings, name=name))
        configuration_list = add("config-list:" + edition, "XCConfigurationList", buildConfigurations=configurations, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
        target = add("target:" + edition, "PBXNativeTarget", buildConfigurationList=configuration_list, buildPhases=[sources, links, resource_phase], buildRules=[], dependencies=[], name=target_name, productName=product, productReference=product_ref, productType="com.apple.product-type.application")
        target_ids.append(target)
        ui_name = target_name + "UITests"
        ui_product = add("ui-product:" + edition, "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path=ui_name + ".xctest", sourceTree="BUILT_PRODUCTS_DIR")
        products.append(ui_product)
        ui_source = add("ui-source:" + edition, "PBXBuildFile", fileRef=ui_ref)
        ui_sources = add("ui-sources:" + edition, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=[ui_source], runOnlyForDeploymentPostprocessing=0)
        ui_links = add("ui-links:" + edition, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
        ui_configs = []
        for name in ["Debug", "Release"]:
            ui_settings = {"PRODUCT_NAME": ui_name, "PRODUCT_BUNDLE_IDENTIFIER": f"com.example.iarchiver.{variant}.uitests",
                "GENERATE_INFOPLIST_FILE": "YES", "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
                "SWIFT_VERSION": "5.0", "TARGETED_DEVICE_FAMILY": "1,2", "ARCHS": "arm64",
                "TEST_TARGET_NAME": target_name, "CODE_SIGN_STYLE": "Automatic",
                "SWIFT_OPTIMIZATION_LEVEL": "-Onone", "ENABLE_TESTABILITY": "YES", "ALWAYS_SEARCH_USER_PATHS": "NO"}
            ui_configs.append(add(f"ui-config:{edition}:{name}", "XCBuildConfiguration", buildSettings=ui_settings, name=name))
        ui_list = add("ui-config-list:" + edition, "XCConfigurationList", buildConfigurations=ui_configs, defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")
        proxy = add("ui-proxy:" + edition, "PBXContainerItemProxy", containerPortal=identifier("project"), proxyType=1, remoteGlobalIDString=target, remoteInfo=target_name)
        dependency = add("ui-dependency:" + edition, "PBXTargetDependency", target=target, targetProxy=proxy)
        ui_targets.append(add("ui-target:" + edition, "PBXNativeTarget", buildConfigurationList=ui_list,
            buildPhases=[ui_sources, ui_links], buildRules=[], dependencies=[dependency], name=ui_name,
            productName=ui_name, productReference=ui_product, productType="com.apple.product-type.bundle.ui-testing"))
    sources_group = add("group:sources", "PBXGroup", children=swift_refs, name="Sources", sourceTree="<group>")
    resource_group = add("group:resources", "PBXGroup", children=resources + [unrar_ref], name="Resources", sourceTree="<group>")
    config_group = add("group:config", "PBXGroup", children=[info_ref, base_config] + list(configs.values()), name="Configuration", sourceTree="<group>")
    framework_group = add("group:frameworks", "PBXGroup", children=frameworks, name="Native Libraries", sourceTree="<group>")
    product_group = add("group:products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
    test_group = add("group:tests", "PBXGroup", children=[ui_ref], name="UI Tests", sourceTree="<group>")
    main = add("group:main", "PBXGroup", children=[sources_group, resource_group, config_group, framework_group, product_group, test_group], sourceTree="<group>")
    project_configurations = []
    for name in ["Debug", "Release"]:
        project_configurations.append(add("project-config:" + name, "XCBuildConfiguration", buildSettings={"CLANG_ANALYZER_LOCALIZABILITY_NONLOCALIZED": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES", "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES", "SWIFT_COMPILATION_MODE": "singlefile" if name == "Debug" else "wholemodule", "ENABLE_TESTABILITY": "YES" if name == "Debug" else "NO"}, name=name))
    project_list = add("project-config-list", "XCConfigurationList", buildConfigurations=project_configurations, defaultConfigurationIsVisible=0, defaultConfigurationName="Release")
    attributes = {target: {"CreatedOnToolsVersion": "27.0", "ProvisioningStyle": "Automatic"} for target in target_ids}
    attributes.update({test: {"CreatedOnToolsVersion": "27.0", "TestTargetID": target} for test, target in zip(ui_targets, target_ids)})
    project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2700", "TargetAttributes": attributes}, buildConfigurationList=project_list, compatibilityVersion="Xcode 14.0", developmentRegion="en", hasScannedForEncodings=0, knownRegions=["en", "zh-Hans", "Base"], mainGroup=main, productRefGroup=product_group, projectDirPath="", projectRoot="", targets=target_ids + ui_targets)
    tree = {"archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project}
    project_dir = ROOT / "iArchiver.xcodeproj"
    project_dir.mkdir(exist_ok=True)
    (project_dir / "project.pbxproj").write_text("// !$*UTF8*$!\n" + serialize(tree) + "\n", encoding="utf-8", newline="\n")
    workspace = project_dir / "project.xcworkspace"
    workspace.mkdir(exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n', encoding="utf-8", newline="\n")
    schemes = project_dir / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    for index, (name, product) in enumerate([("iArchiver-AppStore", "iArchiver"), ("iArchiver-Sideload", "iArchiver Sideload")]):
        scheme = ET.Element("Scheme", LastUpgradeVersion="2700", version="1.3")
        def buildable(parent):
            return ET.SubElement(parent, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=target_ids[index], BuildableName=product + ".app", BlueprintName=name, ReferencedContainer="container:iArchiver.xcodeproj")
        action = ET.SubElement(scheme, "BuildAction", parallelizeBuildables="YES", buildImplicitDependencies="YES")
        entries = ET.SubElement(action, "BuildActionEntries")
        buildable(ET.SubElement(entries, "BuildActionEntry", buildForTesting="YES", buildForRunning="YES", buildForProfiling="YES", buildForArchiving="YES", buildForAnalyzing="YES"))
        tests = ET.SubElement(scheme, "TestAction", buildConfiguration="Debug", selectedDebuggerIdentifier="", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn", shouldUseLaunchSchemeArgsEnv="YES")
        testable = ET.SubElement(ET.SubElement(tests, "Testables"), "TestableReference", skipped="NO", parallelizable="NO")
        ET.SubElement(testable, "BuildableReference", BuildableIdentifier="primary", BlueprintIdentifier=ui_targets[index], BuildableName=name + "UITests.xctest", BlueprintName=name + "UITests", ReferencedContainer="container:iArchiver.xcodeproj")
        launch = ET.SubElement(scheme, "LaunchAction", buildConfiguration="Debug", selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB", selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB", launchStyle="0", useCustomWorkingDirectory="NO", ignoresPersistentStateOnLaunch="NO", debugDocumentVersioning="YES", debugServiceExtension="internal", allowLocationSimulation="YES")
        buildable(ET.SubElement(launch, "BuildableProductRunnable", runnableDebuggingMode="0"))
        profile = ET.SubElement(scheme, "ProfileAction", buildConfiguration="Release", shouldUseLaunchSchemeArgsEnv="YES", savedToolIdentifier="", useCustomWorkingDirectory="NO", debugDocumentVersioning="YES")
        buildable(ET.SubElement(profile, "BuildableProductRunnable", runnableDebuggingMode="0"))
        ET.SubElement(scheme, "AnalyzeAction", buildConfiguration="Debug")
        ET.SubElement(scheme, "ArchiveAction", buildConfiguration="Release", revealArchiveInOrganizer="YES")
        ET.indent(scheme)
        (schemes / (name + ".xcscheme")).write_bytes(ET.tostring(scheme, encoding="utf-8", xml_declaration=True))
    print(f"Generated two shared schemes with {len(swift_files)} Swift source files.")


if __name__ == "__main__":
    generate()
