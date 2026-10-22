// Dependency-free, deterministic Xcode project generation. Run from any cwd.
import { readFileSync, readdirSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const objects = {};
const id = name => createHash('sha256').update(name).digest('hex').slice(0, 24).toUpperCase();
const add = (name, value) => { const key = id(name); objects[key] = value; return key; };
const ref = (path, type) => add(path, { isa: 'PBXFileReference', lastKnownFileType: type, path, sourceTree: '<group>' });
const build = (path, type) => add('build:' + path, { isa: 'PBXBuildFile', fileRef: ref(path, type) });
const swift = readdirSync(resolve(root, 'Spotifast')).filter(n => n.endsWith('.swift')).sort().map(n => 'Spotifast/' + n);
const testFiles = ['Tests', 'PortableTests'].flatMap(folder => readdirSync(resolve(root, folder)).filter(n => n.endsWith('.swift')).sort().map(n => folder + '/' + n));
const uiFiles = readdirSync(resolve(root, 'UITests')).filter(n => n.endsWith('.swift')).sort().map(n => 'UITests/' + n);
const sources = add('sources', { isa: 'PBXSourcesBuildPhase', buildActionMask: 2147483647, files: swift.map(n => build(n, 'sourcecode.swift')), runOnlyForDeploymentPostprocessing: 0 });
const tests = add('test-sources', { isa: 'PBXSourcesBuildPhase', buildActionMask: 2147483647, files: testFiles.map(n => build(n, 'sourcecode.swift')), runOnlyForDeploymentPostprocessing: 0 });
const uiSources = add('ui-test-sources', { isa: 'PBXSourcesBuildPhase', buildActionMask: 2147483647, files: uiFiles.map(n => build(n, 'sourcecode.swift')), runOnlyForDeploymentPostprocessing: 0 });
const resources = add('resources', { isa: 'PBXResourcesBuildPhase', buildActionMask: 2147483647, files: [build('Spotifast/Assets.xcassets', 'folder.assetcatalog'), build('Spotifast/PrivacyInfo.xcprivacy', 'text.xml')], runOnlyForDeploymentPostprocessing: 0 });
const frameworks = add('frameworks', { isa: 'PBXFrameworksBuildPhase', buildActionMask: 2147483647, files: [], runOnlyForDeploymentPostprocessing: 0 });
const rust = add('rust-build', { isa: 'PBXShellScriptBuildPhase', alwaysOutOfDate: 1, buildActionMask: 2147483647, files: [], inputPaths: [], outputPaths: ['$(BUILT_PRODUCTS_DIR)/libspotifast_ios_core.a'], name: 'Build Rust playback core', runOnlyForDeploymentPostprocessing: 0, shellPath: '/bin/bash', shellScript: 'bash "$SRCROOT/scripts/build-rust.sh"\n' });
const appProduct = add('app-product', { isa: 'PBXFileReference', explicitFileType: 'wrapper.application', includeInIndex: 0, path: 'Spotifast.app', sourceTree: 'BUILT_PRODUCTS_DIR' });
const testProduct = add('test-product', { isa: 'PBXFileReference', explicitFileType: 'wrapper.cfbundle', includeInIndex: 0, path: 'SpotifastTests.xctest', sourceTree: 'BUILT_PRODUCTS_DIR' });
const uiProduct = add('ui-test-product', { isa: 'PBXFileReference', explicitFileType: 'wrapper.cfbundle', includeInIndex: 0, path: 'SpotifastUITests.xctest', sourceTree: 'BUILT_PRODUCTS_DIR' });
const baseConfig = ref('Config/Base.xcconfig', 'text.xcconfig');
const configurations = (name, settings, extra = {}) => add(name + '-configs', { isa: 'XCConfigurationList', buildConfigurations: ['Debug', 'Release'].map(mode => add(name + '-' + mode, { isa: 'XCBuildConfiguration', buildSettings: { ...settings, ...(mode === 'Debug' ? { SWIFT_OPTIMIZATION_LEVEL: '-Onone', DEBUG_INFORMATION_FORMAT: 'dwarf', ONLY_ACTIVE_ARCH: 'YES', ENABLE_TESTABILITY: 'YES', SWIFT_ACTIVE_COMPILATION_CONDITIONS: 'DEBUG' } : { SWIFT_OPTIMIZATION_LEVEL: '-O', DEBUG_INFORMATION_FORMAT: 'dwarf-with-dsym', VALIDATE_PRODUCT: 'YES' }) }, name: mode, ...extra })), defaultConfigurationIsVisible: 0, defaultConfigurationName: 'Release' });
const appConfigs = configurations('app', {}, { baseConfigurationReference: baseConfig });
const testConfigs = configurations('tests', { PRODUCT_BUNDLE_IDENTIFIER: 'local.spotifast.ios.tests', PRODUCT_NAME: '$(TARGET_NAME)', GENERATE_INFOPLIST_FILE: 'YES', SWIFT_VERSION: '5.0', IPHONEOS_DEPLOYMENT_TARGET: '17.0', TARGETED_DEVICE_FAMILY: '1', TEST_HOST: '$(BUILT_PRODUCTS_DIR)/Spotifast.app/Spotifast', BUNDLE_LOADER: '$(TEST_HOST)', CODE_SIGN_STYLE: 'Automatic' });
const uiConfigs = configurations('ui-tests', { PRODUCT_BUNDLE_IDENTIFIER: 'local.spotifast.ios.uitests', PRODUCT_NAME: '$(TARGET_NAME)', GENERATE_INFOPLIST_FILE: 'YES', SWIFT_VERSION: '5.0', IPHONEOS_DEPLOYMENT_TARGET: '17.0', TARGETED_DEVICE_FAMILY: '1', TEST_TARGET_NAME: 'Spotifast', CODE_SIGN_STYLE: 'Automatic' });
const projectConfigs = configurations('project', { CLANG_ENABLE_MODULES: 'YES', CLANG_ENABLE_OBJC_ARC: 'YES', SDKROOT: 'iphoneos', GCC_C_LANGUAGE_STANDARD: 'gnu17', GCC_WARN_ABOUT_RETURN_TYPE: 'YES_ERROR', CLANG_WARN_DOCUMENTATION_COMMENTS: 'YES' });
const app = add('app', { isa: 'PBXNativeTarget', buildConfigurationList: appConfigs, buildPhases: [rust, sources, frameworks, resources], buildRules: [], dependencies: [], name: 'Spotifast', productName: 'Spotifast', productReference: appProduct, productType: 'com.apple.product-type.application' });
const proxy = add('test-proxy', { isa: 'PBXContainerItemProxy', containerPortal: id('project'), proxyType: 1, remoteGlobalIDString: app, remoteInfo: 'Spotifast' });
const dependency = add('test-dependency', { isa: 'PBXTargetDependency', target: app, targetProxy: proxy });
const test = add('test-target', { isa: 'PBXNativeTarget', buildConfigurationList: testConfigs, buildPhases: [tests], buildRules: [], dependencies: [dependency], name: 'SpotifastTests', productName: 'SpotifastTests', productReference: testProduct, productType: 'com.apple.product-type.bundle.unit-test' });
const uiTest = add('ui-test-target', { isa: 'PBXNativeTarget', buildConfigurationList: uiConfigs, buildPhases: [uiSources], buildRules: [], dependencies: [dependency], name: 'SpotifastUITests', productName: 'SpotifastUITests', productReference: uiProduct, productType: 'com.apple.product-type.bundle.ui-testing' });
const sourceGroup = add('source-group', { isa: 'PBXGroup', name: 'App', children: swift.map(id), sourceTree: '<group>' });
const testGroup = add('test-group', { isa: 'PBXGroup', name: 'Tests', children: testFiles.map(id), sourceTree: '<group>' });
const uiGroup = add('ui-test-group', { isa: 'PBXGroup', name: 'UI Tests', children: uiFiles.map(id), sourceTree: '<group>' });
const productGroup = add('products', { isa: 'PBXGroup', name: 'Products', children: [appProduct, testProduct, uiProduct], sourceTree: '<group>' });
const group = add('root-group', { isa: 'PBXGroup', children: [sourceGroup, testGroup, uiGroup, baseConfig, ref('Config/Info.plist', 'text.plist.xml'), ref('Bridge/SpotifastCore.h', 'sourcecode.c.h'), id('Spotifast/Assets.xcassets'), id('Spotifast/PrivacyInfo.xcprivacy'), productGroup], sourceTree: '<group>' });
add('project', { isa: 'PBXProject', attributes: { BuildIndependentTargetsInParallel: 1, LastUpgradeCheck: '1600', TargetAttributes: { [app]: { CreatedOnToolsVersion: '16.0' }, [test]: { CreatedOnToolsVersion: '16.0', TestTargetID: app }, [uiTest]: { CreatedOnToolsVersion: '16.0', TestTargetID: app } } }, buildConfigurationList: projectConfigs, compatibilityVersion: 'Xcode 14.0', developmentRegion: 'en', hasScannedForEncodings: 0, knownRegions: ['en', 'Base'], mainGroup: group, productRefGroup: productGroup, projectDirPath: '', projectRoot: '', targets: [app, test, uiTest] });
const atom = v => /^[A-Za-z0-9_.\/]+$/.test(v) ? v : JSON.stringify(v);
const encode = (v, depth = 0) => {
    const pad = '\t'.repeat(depth);
    if (Array.isArray(v)) return '(\n' + v.map(x => pad + '\t' + encode(x, depth + 1) + ',\n').join('') + pad + ')';
    if (v && typeof v === 'object') return '{\n' + Object.entries(v).map(([k, x]) => pad + '\t' + atom(k) + ' = ' + encode(x, depth + 1) + ';\n').join('') + pad + '}';
    return typeof v === 'string' ? atom(v) : JSON.stringify(v);
};
const projectPath = resolve(root, 'Spotifast.xcodeproj');
mkdirSync(resolve(projectPath, 'xcshareddata/xcschemes'), { recursive: true });
const sections = [...new Set(Object.values(objects).map(v => v.isa))].sort();
const objectText = sections.map(type => `/* Begin ${type} section */\n` + Object.entries(objects).filter(([, value]) => value.isa === type).map(([key, value]) => '\t\t' + key + ' = ' + encode(value, 2) + ';\n').join('') + `/* End ${type} section */\n`).join('\n');
const contents = `// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n${objectText}\t};\n\trootObject = ${id('project')};\n}\n`;
if (process.argv.includes('--check')) {
    if (readFileSync(resolve(projectPath, 'project.pbxproj'), 'utf8') !== contents) throw new Error('Xcode project is stale. Run node ios/scripts/generate-project.mjs');
    console.log(`Xcode project matches ${swift.length} app, ${testFiles.length} unit-test and ${uiFiles.length} UI-test sources.`);
} else {
    writeFileSync(resolve(projectPath, 'project.pbxproj'), contents);
    writeFileSync(resolve(projectPath, 'xcshareddata/xcschemes/Spotifast.xcscheme'), `<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${app}" BuildableName="Spotifast.app" BlueprintName="Spotifast" ReferencedContainer="container:Spotifast.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${test}" BuildableName="SpotifastTests.xctest" BlueprintName="SpotifastTests" ReferencedContainer="container:Spotifast.xcodeproj"/></TestableReference><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${uiTest}" BuildableName="SpotifastUITests.xctest" BlueprintName="SpotifastUITests" ReferencedContainer="container:Spotifast.xcodeproj"/></TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${app}" BuildableName="Spotifast.app" BlueprintName="Spotifast" ReferencedContainer="container:Spotifast.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${app}" BuildableName="Spotifast.app" BlueprintName="Spotifast" ReferencedContainer="container:Spotifast.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>\n`);
    console.log(`Wrote Xcode project with ${swift.length} app sources.`);
}
