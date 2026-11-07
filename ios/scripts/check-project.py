#!/usr/bin/env python3
"""Structural evidence only. This does NOT compile against an iOS SDK or exercise iOS behavior."""
from pathlib import Path
import json
import plistlib
import subprocess
import xml.etree.ElementTree as ET
import hashlib

root = Path(__file__).resolve().parents[1]
project = root/'Chirp.xcodeproj/project.pbxproj'
data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))
objects = data['objects']
targets = {v['name']: v for v in objects.values() if v['isa'] == 'PBXNativeTarget'}
assert set(targets) == {'ChirpIOS','ChirpKeyboard','ChirpWidgets','ChirpIOSTests','ChirpIOSUITests'}

def settings(target):
    cfg = objects[targets[target]['buildConfigurationList']]['buildConfigurations']
    return [objects[x]['buildSettings'] for x in cfg]

def members(target):
    phases = [objects[x] for x in targets[target]['buildPhases']]
    files = [f for p in phases if p['isa'] == 'PBXSourcesBuildPhase' for f in p['files']]
    return {objects[objects[f]['fileRef']]['path'] for f in files}

for name in targets:
    for path in members(name): assert (root/path).is_file(), f'Missing {name} source {path}'
    assert not any('/Tests/' in p or p.endswith('Package.swift') for p in members(name))
    for cfg in settings(name):
        assert cfg['TARGETED_DEVICE_FAMILY'] == '1,2'
        assert cfg['PRODUCT_BUNDLE_IDENTIFIER'].startswith('$(CHIRP_BUNDLE_ID)')
    for config_ref in objects[targets[name]['buildConfigurationList']]['buildConfigurations']:
        config = objects[config_ref]
        assert config['buildSettings']['ENABLE_TESTABILITY'] == ('YES' if config['name'] == 'Debug' else 'NO')
        if config['name'] == 'Debug':
            assert config['buildSettings']['ONLY_ACTIVE_ARCH'] == 'YES'
assert all(s['TEST_HOST'] == '$(BUILT_PRODUCTS_DIR)/ChirpIOS.app/ChirpIOS' for s in settings('ChirpIOSTests'))
assert all(s['ASSETCATALOG_COMPILER_APPICON_NAME'] == 'AppIcon' for s in settings('ChirpIOS'))
assert hashlib.sha256((root/'App/Assets.xcassets/AppIcon.appiconset/AppIcon.png').read_bytes()).digest() == hashlib.sha256((root.parent/'mac/Assets/AppIcon.png').read_bytes()).digest()
assert all(s['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] == 'AccentColor' for s in settings('ChirpIOS'))
# The brand artwork ships verbatim (#151): the approved glyph and the icon's pond art, never redrawn.
assets = root/'App/Assets.xcassets'
assert (assets/'ChirpGlyph.imageset/ChirpGlyph.png').read_bytes() == (root.parent/'mac/Assets/ChirpGlyph.png').read_bytes()
assert (assets/'PondArt.imageset/PondArt.png').read_bytes() == (root.parent/'mac/Assets/AppIcon.png').read_bytes()
assert json.loads((assets/'ChirpGlyph.imageset/Contents.json').read_text())['properties']['template-rendering-intent'] == 'template'
for target in ('ChirpIOS', 'ChirpKeyboard'):
    resources = [objects[x] for x in targets[target]['buildPhases'] if objects[x]['isa'] == 'PBXResourcesBuildPhase']
    assert any(objects[objects[f]['fileRef']]['path'] == 'App/Assets.xcassets' for f in resources[0]['files']), target

app = targets['ChirpIOS']
embed = [objects[x] for x in app['buildPhases'] if objects[x]['isa'] == 'PBXCopyFilesBuildPhase']
assert len(embed) == 1 and int(embed[0]['dstSubfolderSpec']) == 13
embedded = {objects[objects[f]['fileRef']]['path'] for f in embed[0]['files']}
assert embedded == {'ChirpKeyboard.appex','ChirpWidgets.appex'}
for f in embed[0]['files']:
    assert set(objects[f]['settings']['ATTRIBUTES']) == {'CodeSignOnCopy','RemoveHeadersOnCopy'}
dependency_names = {objects[objects[x]['target']]['name'] for x in app['dependencies']}
assert dependency_names == {'ChirpKeyboard','ChirpWidgets'}
assert all('CHIRP_APP' in s['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] for s in settings('ChirpIOS'))
for extension in ('ChirpKeyboard','ChirpWidgets'):
    assert all(s.get('APPLICATION_EXTENSION_API_ONLY') == 'YES' for s in settings(extension))
    assert not any('CHIRP_APP' in s.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS','') for s in settings(extension))
assert 'Intents/ChirpLiveActivity.swift' in members('ChirpIOS')
assert 'Intents/ChirpLiveActivity.swift' not in members('ChirpWidgets')
# Toggle and the App Shortcuts list are app-only: an extension copy made Shortcuts run the extension's "Open Chirp…"
# Toggle instead of the app's (iPad, iPadOS 27.2). The extension's buttons never use them.
assert 'Intents/AppShortcuts.swift' in members('ChirpIOS') and 'Intents/AppShortcuts.swift' not in members('ChirpWidgets')
# The widgets compile Pond.swift (colour tokens only; it imports SwiftUI/UIKit, never ChirpCore) straight in.
assert members('ChirpWidgets') == {'Widgets/ChirpWidgets.swift','Widgets/NotesActivityWidget.swift','Widgets/ActivityViews.swift',
                                  'Intents/SessionIntents.swift','Intents/ChirpActivityAttributes.swift','Intents/NotesIntents.swift',
                                  'Intents/NotesActivityAttributes.swift','Shared/Sources/ChirpIOSCore/Pond.swift'}
assert members('ChirpKeyboard') == {'Keyboard/ChirpKeyboardViewController.swift','Keyboard/KeyboardBridgeClient.swift',
                                   'Keyboard/UI/KeyboardPalette.swift',
                                   'Keyboard/UI/KeyboardPreview.swift','Keyboard/UI/KeyboardRippleView.swift',
                                   'Keyboard/UI/KeyboardTopRow.swift'}
for target in ('ChirpKeyboard','ChirpWidgets'):
    assert not any(p.startswith('App/') for p in members(target))

for prefix in ('App','Keyboard','Widgets'):
    info = plistlib.loads((root/f'Config/{prefix}-Info.plist').read_bytes())
    ent = plistlib.loads((root/f'Config/{prefix}.entitlements').read_bytes())
    assert info['ChirpAppGroup'] == '$(CHIRP_APP_GROUP)'
    assert info['ChirpKeychainAccessGroup'] == '$(CHIRP_KEYCHAIN_ACCESS_GROUP)'
    assert ent == {'com.apple.security.application-groups':['$(CHIRP_APP_GROUP)'], 'keychain-access-groups':['$(CHIRP_KEYCHAIN_ACCESS_GROUP)']}
    assert 'NSAppTransportSecurity' not in info
    if prefix == 'App':
        assert info['UIBackgroundModes'] == ['audio'] and info['NSSupportsLiveActivities'] is True
        assert info['NSCameraUsageDescription'] and info['NSMicrophoneUsageDescription']
        assert info['CFBundleURLTypes'][0]['CFBundleURLSchemes'] == ['chirp']
    if prefix == 'Keyboard':
        ext = info['NSExtension']
        assert ext['NSExtensionPointIdentifier'] == 'com.apple.keyboard-service'
        assert ext['NSExtensionPrincipalClass'] == '$(PRODUCT_MODULE_NAME).ChirpKeyboardViewController'
        assert ext['NSExtensionAttributes']['RequestsOpenAccess'] is True
        assert 'NSMicrophoneUsageDescription' not in info and 'UIBackgroundModes' not in info
    if prefix == 'Widgets':
        assert info['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'

for name, test in [('ChirpIOS','ChirpIOSTests'), ('ChirpIOS-UI','ChirpIOSUITests')]:
    scheme = ET.parse(root/f'Chirp.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme')
    refs = scheme.findall('.//TestableReference/BuildableReference')
    assert len(refs) == 1 and refs[0].attrib['BlueprintName'] == test
    assert refs[0].attrib['BuildableName'] == test+'.xctest'
    assert any(r.attrib['BlueprintName'] == test for r in scheme.findall('.//BuildActionEntry/BuildableReference'))
    assert members(test)

packages = {v['relativePath'] for v in objects.values() if v['isa'] == 'XCLocalSwiftPackageReference'}
assert packages == {'Shared','Keyboard/Policy','Keyboard/Typing','../mac'}
for path in packages: assert (root/path/'Package.swift').is_file()
# KeyboardKit (via KeyboardTyping) is linked into the keyboard extension and its unit tests only, at the exact MIT
# release recorded in THIRD-PARTY-NOTICES.md; the app and widgets never load it.
typing_users = {name for name, t in targets.items()
                if any(objects[d]['productName'] == 'KeyboardTyping' for d in t.get('packageProductDependencies', []))}
assert typing_users == {'ChirpKeyboard', 'ChirpIOSTests'}, typing_users
assert 'exact: "9.9.1"' in (root/'Keyboard/Typing/Package.swift').read_text()
assert 'KeyboardKit 9.9.1' in (root/'Keyboard/Typing/THIRD-PARTY-NOTICES.md').read_text()
config = (root/'Config/Project.xcconfig').read_text()
assert 'IPHONEOS_DEPLOYMENT_TARGET = 18.0' in config
assert '$(AppIdentifierPrefix)' in config and '#include? "Local.xcconfig"' in config
print(f'PASS: 5 targets, 2 embedded extensions, 2 test schemes, {sum(len(members(t)) for t in targets)} Swift memberships, plists/entitlements/package/config structure')
print('iOS SDK compilation, signing, simulator tests and hardware acceptance remain separate checks.')
