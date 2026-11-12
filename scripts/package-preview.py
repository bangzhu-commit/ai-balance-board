#!/usr/bin/env python3
"""Export a reviewed project allowlist and signed local app. Never upload or inspect user data."""
import hashlib
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'release'
APP = ROOT / 'dist' / 'AI 额度看板.app'
VERSION = '0.7.0'
FILES = ('README.md', 'LICENSE', 'Package.swift', '.gitignore')
TREES = {
    'Sources': {'.swift'},
    'Tests': {'.swift'},
    'docs': {'.md'},
    '.github': {'.yml', '.yaml', '.md'},
    'browser-extension': {'.js', '.mjs', '.json', '.html', '.css'},
    'scripts': {'.sh', '.py', '.swift', '.mjs'},
    'examples': {'.json'},
}
APP_FILES = {
    'Contents/Info.plist', 'Contents/MacOS/AIBalanceBoard',
    'Contents/_CodeSignature/CodeResources',
    *('Contents/Resources/scripts/' + name for name in
      ('install-login-item.sh', 'install-browser-bridge.sh', 'uninstall.sh')),
    *('Contents/Resources/browser-extension/' + name for name in
      ('manifest.json', 'background.js', 'content.js', 'protocol.js', 'popup.html', 'popup.js', 'popup.css')),
}


def safe_file(path):
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(ROOT):
        raise SystemExit('Refusing unsafe export path: ' + str(path.relative_to(ROOT)))
    for parent in path.relative_to(ROOT).parents:
        if (ROOT / parent).is_symlink():
            raise SystemExit('Refusing symlink ancestor')
    data = path.read_bytes()
    # Catch this workstation's home, credentials, and obvious private keys. No content is printed.
    forbidden = (str(Path.home()).encode(), b'BEGIN ' + b'PRIVATE KEY', b'BEGIN ' + b'RSA PRIVATE KEY')
    if any(marker in data for marker in forbidden):
        raise SystemExit('Private path/key marker in: ' + str(path.relative_to(ROOT)))
    return data


def source_paths():
    paths = [ROOT / name for name in FILES]
    for name, suffixes in TREES.items():
        for path in (ROOT / name).rglob('*'):
            if path.is_symlink():
                raise SystemExit('Refusing source symlink')
            if path.is_file() and path.suffix in suffixes and '__pycache__' not in path.parts:
                paths.append(path)
    return sorted(set(paths))


def write_zip(destination, entries):
    temporary = destination.with_suffix('.zip.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED) as archive:
            for name, path in entries:
                data = safe_file(path)
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | (0o755 if path.stat().st_mode & 0o111 else 0o644)) << 16
                archive.writestr(info, data)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise SystemExit('Archive integrity failure')
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != ('local.outlier.ai-balance-board', VERSION, '9'):
        raise SystemExit('Build v0.7.0/build9 before packaging')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(APP)], check=True)
    for name in ('manifest.json', 'background.js', 'content.js', 'protocol.js', 'popup.html', 'popup.js', 'popup.css'):
        if not (APP / 'Contents/Resources/browser-extension' / name).is_file():
            raise SystemExit('Missing bundled extension resource')
    OUT.mkdir(exist_ok=True)
    if OUT.is_symlink():
        raise SystemExit('Refusing symlink output directory')
    source = OUT / f'AI-Balance-Board-{VERSION}-source.zip'
    binary = OUT / f'AI-Balance-Board-{VERSION}-macos-arm64.zip'
    selected = source_paths()
    write_zip(source, [('ai-balance-board/' + str(path.relative_to(ROOT)), path) for path in selected])
    app_entries = []
    seen_app_files = set()
    for path in sorted(APP.rglob('*')):
        if path.is_symlink():
            raise SystemExit('Unexpected app symlink')
        if path.is_file():
            relative = str(path.relative_to(APP))
            if relative not in APP_FILES:
                raise SystemExit('Unexpected app file outside allowlist: ' + relative)
            seen_app_files.add(relative)
            app_entries.append((APP.name + '/' + str(path.relative_to(APP)), path))
    if seen_app_files != APP_FILES:
        raise SystemExit('Incomplete app bundle allowlist')
    app_entries.append(('README.md', ROOT / 'README.md'))
    app_entries.append(('LICENSE', ROOT / 'LICENSE'))
    app_entries.extend(('docs/' + str(path.relative_to(ROOT / 'docs')), path) for path in sorted((ROOT / 'docs').rglob('*.md')))
    write_zip(binary, app_entries)
    checksums = ''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n' for path in (source, binary))
    (OUT / 'SHA256SUMS.txt').write_text(checksums)
    (OUT / 'source-manifest.json').write_text(json.dumps([str(path.relative_to(ROOT)) for path in selected], indent=2) + '\n')
    print(f'Created {source.name} ({len(selected)} allowlisted source files)')
    print(f'Created {binary.name} and SHA256SUMS.txt; nothing uploaded.')


if __name__ == '__main__':
    main()
