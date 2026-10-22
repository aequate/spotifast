import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(import.meta.url);
const qaRequire = createRequire(resolve(root, 'build/qa/package.json'));
execFileSync(process.execPath, [resolve(root, 'scripts/generate-project.mjs'), '--check'], { stdio: 'inherit' });
for (const file of ['Bridge/SpotifastCore.h', 'Bridge/Spotifast-Bridging-Header.h', 'Rust/Cargo.lock', 'Config/Info.plist', 'Spotifast/PrivacyInfo.xcprivacy', 'Spotifast.xcodeproj/xcshareddata/xcschemes/Spotifast.xcscheme']) assert(existsSync(resolve(root, file)), file);
const assets = resolve(root, 'Spotifast/Assets.xcassets/AppIcon.appiconset');
for (const image of JSON.parse(readFileSync(resolve(assets, 'Contents.json'), 'utf8')).images) assert(existsSync(resolve(assets, image.filename)), image.filename);
if (existsSync(resolve(root, 'build/qa/node_modules/xcode'))) {
    const xcode = require(resolve(root, 'build/qa/node_modules/xcode'));
    const project = xcode.project(resolve(root, 'Spotifast.xcodeproj/project.pbxproj'));
    project.parseSync();
    const objects = project.hash.project.objects;
    assert.equal(Object.keys(objects.PBXNativeTarget).filter(k => !k.endsWith('_comment')).length, 3);
    const sources = objects.PBXSourcesBuildPhase;
    const phaseIDs = Object.keys(sources).filter(k => !k.endsWith('_comment'));
    assert.equal(phaseIDs.length, 3);
    for (const phase of phaseIDs) for (const entry of sources[phase].files) {
        const build = objects.PBXBuildFile[entry.value ?? entry];
        assert(build, 'Every source build reference resolves');
        const file = objects.PBXFileReference[build.fileRef];
        assert(file && existsSync(resolve(root, file.path.replaceAll('"', ''))), 'Every referenced source exists');
    }
    console.log('OpenStep project parsed: app/test targets and all source references resolve.');
}
if (process.argv.includes('--syntax')) {
    const TreeSitter = qaRequire('web-tree-sitter');
    const Parser = TreeSitter.Parser ?? TreeSitter;
    await Parser.init();
    const Language = TreeSitter.Language ?? Parser.Language;
    const language = await Language.load(resolve(root, 'build/qa/node_modules/tree-sitter-wasms/out/tree-sitter-swift.wasm'));
    const parser = new Parser(); parser.setLanguage(language);
    let count = 0;
    for (const folder of ['Spotifast', 'Tests', 'UITests']) for (const name of readdirSync(resolve(root, folder)).filter(n => n.endsWith('.swift'))) {
        const text = readFileSync(resolve(root, folder, name), 'utf8');
        const tree = parser.parse(text);
        const errors = [];
        const visit = node => { if (node.type === 'ERROR' || (typeof node.isMissing === 'function' ? node.isMissing() : node.isMissing)) errors.push({ line: node.startPosition.row + 1, column: node.startPosition.column + 1, text: node.text.slice(0, 180) }); for (const child of node.children) visit(child); };
        visit(tree.rootNode);
        if (errors.length) { console.error(folder + '/' + name, errors); process.exitCode = 1; }
        count++; tree.delete();
    }
    parser.delete();
    console.log(`Parsed ${count} Swift files. This checks syntax only, not Apple SDK types or an iOS build.`);
}
