#!/usr/bin/env python3
"""Deterministic Xcode project generator. The generated .xcodeproj is committed and opens directly."""
import hashlib
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OBJECTS = {}


def identifier(label):
    return hashlib.sha1(label.encode()).hexdigest()[:24].upper()


def add(label, isa, **values):
    key = identifier(label)
    assert key not in OBJECTS
    OBJECTS[key] = dict(isa=isa, **values)
    return key


def serialize(value, depth=0):
    space = '\t' * depth
    if isinstance(value, dict):
        return '{\n' + ''.join(f'{space}\t{serialize(k)} = {serialize(v, depth+1)};\n' for k, v in value.items()) + space + '}'
    if isinstance(value, list):
        return '(\n' + ''.join(f'{space}\t{serialize(item, depth+1)},\n' for item in value) + space + ')'
    if isinstance(value, int):
        return str(value)
    return json.dumps(value, ensure_ascii=False)


def main():
    sources, folders = [], []
    for folder in ['App', 'Core', 'Network', 'Video', 'UI', 'Resources']:
        files = []
        for path in sorted((ROOT / 'GXCameraViewer' / folder).iterdir()):
            if path.suffix not in {'.m', '.c', '.h', '.plist', '.xcassets'}:
                continue
            kind = {'.m': 'sourcecode.c.objc', '.c': 'sourcecode.c.c', '.h': 'sourcecode.c.h',
                    '.plist': 'text.plist.xml', '.xcassets': 'folder.assetcatalog'}[path.suffix]
            ref = add('file/' + folder + '/' + path.name, 'PBXFileReference', lastKnownFileType=kind,
                      path=path.name, sourceTree='<group>')
            files.append(ref)
            if path.suffix in {'.m', '.c'}:
                sources.append(add('compile/' + path.name, 'PBXBuildFile', fileRef=ref))
        folders.append(add('group/' + folder, 'PBXGroup', children=files, path=folder, sourceTree='<group>'))
    source_group = add('sources', 'PBXGroup', children=folders, path='GXCameraViewer', sourceTree='<group>')
    products = add('products', 'PBXGroup', children=[identifier('product')], name='Products', sourceTree='<group>')
    add('product', 'PBXFileReference', explicitFileType='wrapper.application', includeInIndex=0,
        path='GXCameraViewer.app', sourceTree='BUILT_PRODUCTS_DIR')
    framework_refs, framework_builds = [], []
    for name in ['UIKit', 'Foundation', 'AVFoundation', 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'QuartzCore', 'Security', 'CFNetwork']:
        ref = add('framework/' + name, 'PBXFileReference', lastKnownFileType='wrapper.framework', name=name + '.framework',
                  path='System/Library/Frameworks/' + name + '.framework', sourceTree='SDKROOT')
        framework_refs.append(ref)
        framework_builds.append(add('link/' + name, 'PBXBuildFile', fileRef=ref))
    frameworks = add('frameworks', 'PBXGroup', children=framework_refs, name='Frameworks', sourceTree='<group>')
    readme = add('readme', 'PBXFileReference', lastKnownFileType='net.daringfireball.markdown', path='README_CN.md', sourceTree='<group>')
    group = add('rootgroup', 'PBXGroup', children=[source_group, frameworks, products, readme], sourceTree='<group>')
    package = add('package', 'XCRemoteSwiftPackageReference', repositoryURL='https://github.com/robbiehanson/CocoaAsyncSocket.git',
                  requirement={'kind': 'exactVersion', 'version': '7.6.5'})
    package_product = add('packageproduct', 'XCSwiftPackageProductDependency', package=package, productName='CocoaAsyncSocket')
    framework_builds.append(add('packagebuild', 'PBXBuildFile', productRef=package_product))
    source_phase = add('sourcephase', 'PBXSourcesBuildPhase', buildActionMask=2147483647, files=sources, runOnlyForDeploymentPostprocessing=0)
    framework_phase = add('frameworkphase', 'PBXFrameworksBuildPhase', buildActionMask=2147483647, files=framework_builds, runOnlyForDeploymentPostprocessing=0)
    asset_ref = identifier('file/Resources/Assets.xcassets')
    resource_build = add('assetbuild', 'PBXBuildFile', fileRef=asset_ref)
    resource_phase = add('resourcephase', 'PBXResourcesBuildPhase', buildActionMask=2147483647, files=[resource_build], runOnlyForDeploymentPostprocessing=0)
    project_configs, target_configs = [], []
    for name in ['Debug', 'Release']:
        debug = name == 'Debug'
        settings = {
            'ALWAYS_SEARCH_USER_PATHS': 'NO', 'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
            'CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF': 'YES', 'CLANG_WARN_EMPTY_BODY': 'YES',
            'CLANG_WARN_UNREACHABLE_CODE': 'YES', 'CLANG_WARN_CONSTANT_CONVERSION': 'YES',
            'GCC_WARN_64_TO_32_BIT_CONVERSION': 'YES', 'GCC_WARN_ABOUT_RETURN_TYPE': 'YES_ERROR',
            'GCC_WARN_UNINITIALIZED_AUTOS': 'YES_AGGRESSIVE', 'GCC_WARN_UNUSED_VARIABLE': 'YES',
            'GCC_C_LANGUAGE_STANDARD': 'gnu11', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SDKROOT': 'iphoneos',
            'GCC_OPTIMIZATION_LEVEL': '0' if debug else 's', 'DEBUG_INFORMATION_FORMAT': 'dwarf' if debug else 'dwarf-with-dsym',
            'ENABLE_NS_ASSERTIONS': 'YES' if debug else 'NO', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES',
            'ONLY_ACTIVE_ARCH': 'YES' if debug else 'NO',
            'GCC_PREPROCESSOR_DEFINITIONS': ['$(inherited)', 'DEBUG=1'] if debug else ['$(inherited)']
        }
        project_configs.append(add('projectconfig/' + name, 'XCBuildConfiguration', buildSettings=settings, name=name))
        settings = {
            'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'CODE_SIGN_STYLE': 'Automatic',
            'CURRENT_PROJECT_VERSION': '1', 'DEVELOPMENT_TEAM': '', 'GENERATE_INFOPLIST_FILE': 'NO',
            'INFOPLIST_FILE': 'GXCameraViewer/Resources/Info.plist', 'MARKETING_VERSION': '0.1.0',
            'PRODUCT_BUNDLE_IDENTIFIER': 'com.guanxukeji.GXCameraViewer', 'PRODUCT_NAME': '$(TARGET_NAME)',
            'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST': 'NO',
            'SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD': 'NO', 'TARGETED_DEVICE_FAMILY': '1,2',
            'HEADER_SEARCH_PATHS': ['$(inherited)'] + ['$(SRCROOT)/GXCameraViewer/' + folder for folder in ['App', 'Core', 'Network', 'Video', 'UI']],
            'OTHER_LDFLAGS': ['$(inherited)', '-ObjC'], 'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/Frameworks']
        }
        target_configs.append(add('targetconfig/' + name, 'XCBuildConfiguration', buildSettings=settings, name=name))
    project_config_list = add('projectconfiglist', 'XCConfigurationList', buildConfigurations=project_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
    target_config_list = add('targetconfiglist', 'XCConfigurationList', buildConfigurations=target_configs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')
    target = add('target', 'PBXNativeTarget', buildConfigurationList=target_config_list,
                 buildPhases=[source_phase, framework_phase, resource_phase], buildRules=[], dependencies=[],
                 name='GXCameraViewer', packageProductDependencies=[package_product], productName='GXCameraViewer',
                 productReference=identifier('product'), productType='com.apple.product-type.application')
    project = add('project', 'PBXProject', attributes={
        'BuildIndependentTargetsInParallel': 'YES', 'LastUpgradeCheck': '1500',
        'TargetAttributes': {target: {'CreatedOnToolsVersion': '15.0', 'ProvisioningStyle': 'Automatic'}}},
        buildConfigurationList=project_config_list, compatibilityVersion='Xcode 14.0', developmentRegion='zh_CN',
        hasScannedForEncodings=0, knownRegions=['zh_CN', 'en', 'Base'], mainGroup=group,
        packageReferences=[package], productRefGroup=products, projectDirPath='', projectRoot='', targets=[target])
    project_dir = ROOT / 'GXCameraViewer.xcodeproj'
    project_dir.mkdir(exist_ok=True)
    document = {'archiveVersion': 1, 'classes': {}, 'objectVersion': 56, 'objects': OBJECTS, 'rootObject': project}
    (project_dir / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + serialize(document) + '\n', encoding='utf-8')
    scheme = ET.Element('Scheme', LastUpgradeVersion='1500', version='1.3')
    build = ET.SubElement(scheme, 'BuildAction', parallelizeBuildables='YES', buildImplicitDependencies='YES')
    entries = ET.SubElement(build, 'BuildActionEntries')
    entry = ET.SubElement(entries, 'BuildActionEntry', buildForTesting='YES', buildForRunning='YES', buildForProfiling='YES', buildForArchiving='YES', buildForAnalyzing='YES')
    reference = dict(BuildableIdentifier='primary', BlueprintIdentifier=target, BuildableName='GXCameraViewer.app', BlueprintName='GXCameraViewer', ReferencedContainer='container:GXCameraViewer.xcodeproj')
    ET.SubElement(entry, 'BuildableReference', **reference)
    test = ET.SubElement(scheme, 'TestAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', shouldUseLaunchSchemeArgsEnv='YES')
    ET.SubElement(test, 'Testables')
    launch = ET.SubElement(scheme, 'LaunchAction', buildConfiguration='Debug', selectedDebuggerIdentifier='Xcode.DebuggerFoundation.Debugger.LLDB', selectedLauncherIdentifier='Xcode.IDEFoundation.Launcher.LLDB', launchStyle='0', useCustomWorkingDirectory='NO', ignoresPersistentStateOnLaunch='NO', debugDocumentVersioning='YES', debugServiceExtension='internal', allowLocationSimulation='YES')
    run = ET.SubElement(launch, 'BuildableProductRunnable', runnableDebuggingMode='0'); ET.SubElement(run, 'BuildableReference', **reference)
    profile = ET.SubElement(scheme, 'ProfileAction', buildConfiguration='Release', shouldUseLaunchSchemeArgsEnv='YES', savedToolIdentifier='', useCustomWorkingDirectory='NO', debugDocumentVersioning='YES')
    run = ET.SubElement(profile, 'BuildableProductRunnable', runnableDebuggingMode='0'); ET.SubElement(run, 'BuildableReference', **reference)
    ET.SubElement(scheme, 'AnalyzeAction', buildConfiguration='Debug')
    ET.SubElement(scheme, 'ArchiveAction', buildConfiguration='Release', revealArchiveInOrganizer='YES')
    ET.indent(scheme, space='  ')
    path = project_dir / 'xcshareddata/xcschemes'; path.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(scheme).write(path / 'GXCameraViewer.xcscheme', encoding='UTF-8', xml_declaration=True)
    workspace = project_dir / 'project.xcworkspace'; workspace.mkdir(exist_ok=True)
    (workspace / 'contents.xcworkspacedata').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n')
    print(f'Generated {project_dir} ({len(OBJECTS)} objects, {len(sources)} source files)')


if __name__ == '__main__':
    main()
