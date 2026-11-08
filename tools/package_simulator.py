#!/usr/bin/env python3
"""Build a tagged, clean checkout into an ARM64 iOS Simulator release package."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import re
import subprocess


ROOT = Path(__file__).resolve().parent.parent


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    project = (ROOT / 'Hermes.xcodeproj/project.pbxproj').read_text()
    versions = set(re.findall(r'MARKETING_VERSION = ([0-9.]+);', project))
    builds = set(re.findall(r'CURRENT_PROJECT_VERSION = ([0-9]+);', project))
    if len(versions) != 1 or len(builds) != 1:
        raise SystemExit('App build configurations must agree on version and build number.')
    version, build = versions.pop(), builds.pop()
    tag = 'v' + version
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build' / ('release-' + tag))
    parser.add_argument('--derived-data', type=Path,
                        default=Path.home() / 'Library/Caches/HermesIOSRelease' / tag)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('This package targets Apple Silicon iOS simulators; build on an ARM64 Mac.')
    if run('git', 'status', '--porcelain'):
        raise SystemExit('Commit or isolate local changes before packaging a release.')
    commit = run('git', 'rev-parse', 'HEAD')
    if run('git', 'rev-parse', tag + '^{commit}') != commit:
        raise SystemExit(tag + ' must point to the current source commit.')
    subprocess.run([
        'xcodebuild', '-project', 'Hermes.xcodeproj', '-scheme', 'Hermes',
        '-configuration', 'Release', '-sdk', 'iphonesimulator',
        '-destination', 'generic/platform=iOS Simulator',
        '-derivedDataPath', str(args.derived_data.resolve()), '-jobs', '2',
        '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile',
        'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO', 'build',
    ], cwd=ROOT, check=True)
    app = args.derived_data / 'Build/Products/Release-iphonesimulator/Hermes.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    expected = {'CFBundleIdentifier': 'com.a7w.hermes', 'CFBundleShortVersionString': version,
                'CFBundleVersion': build}
    for key, value in expected.items():
        if info.get(key) != value:
            raise SystemExit('Unexpected built ' + key + ': ' + str(info.get(key)))
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneSimulator']:
        raise SystemExit('Refusing to package a non-simulator app.')
    binary = app / info['CFBundleExecutable']
    if run('xcrun', 'lipo', '-archs', str(binary)) != 'arm64':
        raise SystemExit('Expected exactly the ARM64 simulator architecture.')
    if 'IOSSIMULATOR' not in run('xcrun', 'vtool', '-show-build', str(binary)):
        raise SystemExit('Executable is not built for the iOS Simulator platform.')
    if (app / 'embedded.mobileprovision').exists():
        raise SystemExit('A simulator package must not include a device provisioning profile.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / ('Hermes-' + version + '-iOS-Simulator-arm64.zip')
    if archive.exists():
        raise SystemExit('Use an empty release output directory; archive already exists: ' + str(archive))
    subprocess.run(['ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr',
                    str(app), str(archive)], check=True)
    resolved = ROOT / 'Hermes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
    metadata = {
        'version': version, 'buildNumber': build, 'bundleIdentifier': info['CFBundleIdentifier'],
        'sourceCommit': commit, 'tag': tag, 'configuration': 'Release',
        'platform': 'iPhoneSimulator', 'architecture': 'arm64',
        'minimumOSVersion': info.get('MinimumOSVersion'),
        'builtAtUTC': dt.datetime.now(dt.timezone.utc).isoformat(),
        'xcode': run('xcodebuild', '-version'),
        'sdkVersion': run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'),
        'packageResolvedSHA256': sha256(resolved), 'executableSHA256': sha256(binary),
        'archiveSHA256': sha256(archive), 'deviceSigning': 'Not applicable: simulator build',
    }
    (output / 'BUILDINFO.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
    (output / 'INSTALL.txt').write_text(
        'Hermes ' + version + ' (build ' + build + ') — ARM64 iOS Simulator\n\n'
        '适用：Apple Silicon Mac 上的 iOS 模拟器。不是 iPhone 真机 IPA。\n'
        '1. 解压 ZIP，保留 Hermes.app 的完整目录结构。\n'
        '2. 在移动端验收台中选择 iOS 模拟器，启动 / 连接，再安装 Hermes.app。\n'
        '也可用命令行：\n'
        '  xcrun simctl install <SIMULATOR_UDID> /path/to/Hermes.app\n'
        '  xcrun simctl launch <SIMULATOR_UDID> com.a7w.hermes\n\n'
        '聊天与远端功能需要在 App 中配置自己的 Hermes Agent 服务地址和密钥。\n'
        '本包不包含个人凭据，也不代表真机或真实服务业务验收通过。\n'
    )
    names = [archive.name, 'BUILDINFO.json', 'INSTALL.txt']
    (output / 'SHA256SUMS').write_text(''.join(sha256(output / name) + '  ' + name + '\n' for name in names))
    print('Release files: ' + str(output))


if __name__ == '__main__':
    main()
