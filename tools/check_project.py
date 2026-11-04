#!/usr/bin/env python3
"""Parse the actual generated OpenStep project and check references, resources and shared scheme.
This is a structural check, NOT an Objective-C/iOS SDK compile.
"""
from collections import Counter
import json
from pathlib import Path
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


class OpenStep:
    def __init__(self, text):
        token = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[A-Za-z0-9_./$<>+*:\-]+|[{}()=;,]')
        self.tokens = []
        position = 0
        while position < len(text):
            match = token.match(text, position)
            if not match:
                raise ValueError(f'Invalid project syntax at byte {position}')
            value = match.group(); position = match.end()
            if not value.isspace() and not value.startswith(('//', '/*')):
                self.tokens.append(value)
        self.index = 0

    def take(self, expected=None):
        value = self.tokens[self.index]; self.index += 1
        if expected is not None and value != expected:
            raise ValueError(f'Expected {expected}, found {value}')
        return value

    def parse(self):
        token = self.take()
        if token == '{':
            value = {}
            while self.tokens[self.index] != '}':
                key = self.parse(); self.take('='); item = self.parse(); self.take(';')
                assert key not in value, f'Duplicate key {key}'
                value[key] = item
            self.take('}'); return value
        if token == '(':
            value = []
            while self.tokens[self.index] != ')':
                value.append(self.parse()); self.take(',')
            self.take(')'); return value
        if token.startswith('"'):
            return json.loads(token)
        return int(token) if token.isdigit() else token


def main():
    parser = OpenStep((ROOT / 'GXCameraViewer.xcodeproj/project.pbxproj').read_text())
    document = parser.parse(); assert parser.index == len(parser.tokens)
    objects = document['objects']; project = objects[document['rootObject']]
    assert project['isa'] == 'PBXProject'
    for obj in objects.values():
        if obj['isa'] == 'XCBuildConfiguration' and 'SDKROOT' in obj['buildSettings']:
            assert obj['buildSettings']['IPHONEOS_DEPLOYMENT_TARGET'] == '17.0'
    refs = re.compile(r'^[0-9A-F]{24}$')

    def check_references(value):
        if isinstance(value, dict):
            for item in value.values(): check_references(item)
        elif isinstance(value, list):
            for item in value: check_references(item)
        elif isinstance(value, str) and refs.fullmatch(value):
            assert value in objects, f'Unresolved object ID {value}'
    check_references(objects)
    file_paths = {}

    def walk(key, directory):
        obj = objects[key]
        if obj['isa'] == 'PBXGroup':
            directory = directory / obj.get('path', '')
            for child in obj['children']: walk(child, directory)
        elif obj['isa'] == 'PBXFileReference' and obj.get('sourceTree') == '<group>':
            path = directory / obj['path']; assert path.exists(), f'Missing file {path}'
            file_paths[key] = path.resolve()
    walk(project['mainGroup'], ROOT)
    target = objects[project['targets'][0]]
    compiled = []
    for key in target['buildPhases']:
        phase = objects[key]
        if phase['isa'] == 'PBXSourcesBuildPhase':
            compiled += [file_paths[objects[item]['fileRef']] for item in phase['files']]
    expected = {p.resolve() for p in (ROOT / 'GXCameraViewer').rglob('*') if p.suffix in {'.m', '.c'}}
    assert set(compiled) == expected, f'Source inventory mismatch: {set(compiled) ^ expected}'
    assert all(n == 1 for n in Counter(compiled).values()), 'Duplicate compiled source'
    packages = [objects[key] for key in project['packageReferences']]
    assert packages[0]['repositoryURL'] == 'https://github.com/robbiehanson/CocoaAsyncSocket.git'
    assert packages[0]['requirement'] == {'kind': 'exactVersion', 'version': '7.6.5'}
    plist = plistlib.loads((ROOT / 'GXCameraViewer/Resources/Info.plist').read_bytes())
    assert plist['NSLocalNetworkUsageDescription']
    scene = plist['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]
    assert scene['UISceneDelegateClassName'] == 'GXSceneDelegate'
    for path in (ROOT / 'GXCameraViewer/Resources').rglob('*.json'):
        data = json.loads(path.read_text())
        for item in data.get('images', []): assert (path.parent / item['filename']).exists()
    png = (ROOT / 'GXCameraViewer/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png').read_bytes()
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    assert struct.unpack('>II', png[16:24]) == (1024, 1024) and png[25] == 2
    scheme = ET.parse(ROOT / 'GXCameraViewer.xcodeproj/xcshareddata/xcschemes/GXCameraViewer.xcscheme')
    for ref in scheme.findall('.//BuildableReference'):
        assert objects[ref.attrib['BlueprintIdentifier']]['isa'] == 'PBXNativeTarget'
    ET.parse(ROOT / 'GXCameraViewer.xcodeproj/project.xcworkspace/contents.xcworkspacedata')
    print(f'PASS: project syntax, {len(objects)} references, {len(compiled)} source files, SPM pin, Info.plist, icon and shared scheme.')


if __name__ == '__main__':
    main()
