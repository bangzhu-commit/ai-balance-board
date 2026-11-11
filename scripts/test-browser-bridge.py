#!/usr/bin/env python3
"""Offline native-message protocol checks. Uses fake Chrome stdio and temporary state only."""
import json
import os
from pathlib import Path
import select
import stat
import struct
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build' / 'bridge-checks'
ORIGIN = 'chrome-extension://eghfefbgledejemklpphhpcfknmpbllf/'
CHECKS = 0
GROUPS = 0


def check(condition, message):
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(message)


def group(name, callback):
    global GROUPS
    callback()
    GROUPS += 1
    print('通过：' + name, flush=True)


def build():
    BUILD.mkdir(parents=True, exist_ok=True)
    harness = BUILD / 'HostMain.swift'
    harness.write_text('''import Foundation
@main enum BridgeCheckMain {
    static func main() {
        BrowserBridgeHost.run(expectedOrigin: "''' + ORIGIN + '''", directory: URL(fileURLWithPath: CommandLine.arguments[3]))
    }
}
''')
    subprocess.run([
        'swiftc', '-swift-version', '5', '-target', 'arm64-apple-macosx14.0',
        '-module-cache-path', str(ROOT / '.build' / 'clang-cache'), '-parse-as-library',
        str(ROOT / 'Sources/AIBalanceBoard/BrowserBridgeHost.swift'), str(harness),
        '-o', str(BUILD / 'BridgeHostChecks'),
    ], check=True)


class Host:
    def __init__(self, directory, origin=ORIGIN):
        self.directory = Path(directory)
        self.process = subprocess.Popen([
            str(BUILD / 'BridgeHostChecks'), '--browser-bridge-host', origin, str(directory),
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.generation = None

    def send(self, value, fragmented=False):
        body = json.dumps(value, separators=(',', ':')).encode()
        frame = struct.pack('<I', len(body)) + body
        if fragmented:
            for part in [frame[:2], frame[2:7], frame[7:]]:
                self.process.stdin.write(part)
                self.process.stdin.flush()
                time.sleep(0.03)
        else:
            self.process.stdin.write(frame)
            self.process.stdin.flush()

    def read_exact(self, count, timeout=3):
        output = b''
        deadline = time.monotonic() + timeout
        while len(output) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise AssertionError('等待协议消息超时')
            chunk = os.read(self.process.stdout.fileno(), count - len(output))
            if not chunk:
                raise AssertionError('协议通道意外结束：' + self.process.stderr.read().decode())
            output += chunk
        return output

    def read(self, timeout=3):
        length = struct.unpack('<I', self.read_exact(4, timeout))[0]
        check(0 < length <= 65536, '输出必须为有效小端长度帧')
        return json.loads(self.read_exact(length, timeout))

    def silent(self, seconds=0.6):
        check(not select.select([self.process.stdout], [], [], seconds)[0], '不应发送额外协议消息')

    def hello(self, client=None, fragmented=False):
        client = client or str(uuid.uuid4())
        self.send({'type': 'hello', 'version': 1, 'clientID': client}, fragmented)
        ready = self.read()
        check(ready.get('type') == 'ready' and ready.get('version') == 1, '握手应返回ready')
        self.generation = ready['generation']
        uuid.UUID(self.generation)
        return client

    def request(self, identity=None, created=None, generation=None):
        identity = identity or str(uuid.uuid4())
        value = {'version': 1, 'id': identity, 'generation': generation or self.generation,
                 'createdAt': time.time() * 1000 if created is None else created}
        temporary = self.directory / '.request-test.tmp'
        temporary.write_text(json.dumps(value))
        temporary.chmod(0o600)
        temporary.replace(self.directory / 'request.json')
        return identity

    def result(self, identity, kind='ok', data=None, generation=None):
        value = {'type': 'result', 'version': 1, 'id': identity, 'kind': kind,
                 'generation': generation or self.generation}
        if data is not None:
            value['data'] = data
        self.send(value)

    def file(self, name):
        return json.loads((self.directory / name).read_text())

    def await_file(self, name, predicate=lambda _: True, timeout=3):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                data = self.file(name)
                if predicate(data):
                    return data
            except FileNotFoundError:
                pass
            time.sleep(0.05)
        raise AssertionError('等待本地结果超时：' + name)

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        code = self.process.wait(timeout=4)
        error = self.process.stderr.read().decode()
        check('SYNTHETIC_PRIVATE_MARKER' not in error, 'stderr不得包含原始私密字段')
        return code

    def cleanup(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()


def with_host(callback):
    with tempfile.TemporaryDirectory(prefix='balance-bridge-test-', dir='/private/tmp') as temporary:
        host = Host(Path(temporary) / 'bridge')
        try:
            callback(host)
        finally:
            host.cleanup()


def framing_handshake_filter(host):
    host.silent()
    check(not (host.directory / 'presence.json').exists(), 'hello之前不能声明连接')
    client = host.hello(fragmented=True)
    check(uuid.UUID(host.file('pairing.json')['clientID']) == uuid.UUID(client), '必须绑定clientID')
    presence = host.file('presence.json')
    check(presence['connected'] is True and presence['generation'] == host.generation, 'presence需绑定generation')
    check(stat.S_IMODE(host.directory.stat().st_mode) == 0o700, '目录必须700')
    identity = host.request()
    query = host.read()
    check(query['type'] == 'query' and uuid.UUID(query['id']) == uuid.UUID(identity), 'query应匹配请求')
    check(query['generation'] == host.generation, 'query需绑定generation')
    host.result(str(uuid.uuid4()), data={'usagePercent': 0})
    host.result(identity, generation=str(uuid.uuid4()), data={'usagePercent': 0})
    host.result(identity, kind='unknown')
    host.result(identity, data={'usagePercent': True})
    time.sleep(0.2)
    check(not (host.directory / 'result.json').exists(), '错id/代次/kind/类型不能写结果')
    host.result(identity, data={'usagePercent': '20.1', 'hasNonZeroIncludedLimit': True,
                               'isUnified': None, 'nextResetTimestampUtc': '2030-01-01T00:00:00Z',
                               'token': 'SYNTHETIC_PRIVATE_MARKER', 'email': 'SYNTHETIC_PRIVATE_MARKER'})
    result = host.await_file('result.json')
    check(set(result['data']) == {'usagePercent', 'hasNonZeroIncludedLimit', 'isUnified', 'nextResetTimestampUtc'}, '只能保留白名单字段')
    check(result['kind'] == 'ok' and result['generation'] == host.generation, '结果应绑定代次')
    check(abs(result['receivedAt'] - time.time() * 1000) < 3000, '收到时间应为当前毫秒')
    check('SYNTHETIC_PRIVATE_MARKER' not in (host.directory / 'result.json').read_text(), '不能保存未知私密字段')
    host.silent()
    check(host.close() == 0, 'EOF应正常结束')
    check(host.file('presence.json')['connected'] is False, 'EOF必须写断连')
    for name in ['pairing.json', 'presence.json', 'request.json', 'result.json', 'bridge-host.lock']:
        check(stat.S_IMODE((host.directory / name).stat().st_mode) == 0o600, name + '必须600')


def stale_generation_queue(host):
    host.hello()
    host.request(created=time.time() * 1000 - 61000)
    host.silent()
    host.request(created=time.time() * 1000 + 10000)
    host.silent()
    host.request(generation=str(uuid.uuid4()))
    host.silent()
    identity = host.request()
    host.read()
    queued = host.request()
    host.silent()
    host.result(identity, kind='rateLimited')
    result = host.await_file('result.json')
    check(result['kind'] == 'rateLimited' and 'data' not in result, '限流必须明确且不带data')
    query = host.read()
    check(uuid.UUID(query['id']) == uuid.UUID(queued), '前一请求结束才发新请求')
    host.result(queued, kind='loginRequired')
    host.await_file('result.json', lambda value: value['kind'] == 'loginRequired')
    host.result(identity, data={'usagePercent': 99})
    time.sleep(0.2)
    check(host.file('result.json')['kind'] == 'loginRequired', '迟到结果不能覆盖新请求')
    check(host.close() == 0, '正常EOF')


def pairing_and_lock(host):
    client = host.hello()
    second = Host(host.directory)
    try:
        check(second.process.wait(timeout=3) == 1, '第二个host必须被flock拒绝')
        check(host.file('presence.json')['connected'] is True, '拒绝第二实例不能污染首实例presence')
    finally:
        second.cleanup()
    host.close()
    wrong = Host(host.directory)
    try:
        wrong.send({'type': 'hello', 'version': 1, 'clientID': str(uuid.uuid4())})
        check(wrong.process.wait(timeout=3) == 1, '不同profile必须拒绝配对')
        check(uuid.UUID(wrong.file('pairing.json')['clientID']) == uuid.UUID(client), '不能覆盖原配对')
    finally:
        wrong.cleanup()
    same = Host(host.directory)
    try:
        same.hello(client)
        check(same.generation != host.generation, '重连必须更换generation')
        same.close()
    finally:
        same.cleanup()


def bad_origin_framing_symlinks():
    with tempfile.TemporaryDirectory(prefix='balance-bridge-test-', dir='/private/tmp') as temporary:
        base = Path(temporary)
        wrong = Host(base / 'wrong-origin', origin='chrome-extension://' + 'a' * 32 + '/')
        check(wrong.process.wait(timeout=3) == 1, '错误扩展origin必须拒绝')
        check(not (base / 'wrong-origin').exists(), 'origin失败不能创建状态')
        for index, frame in enumerate([struct.pack('<I', 65537), struct.pack('<I', 0), b'\x01\x00']):
            host = Host(base / ('framing-' + str(index)))
            host.process.stdin.write(frame)
            host.process.stdin.close()
            check(host.process.wait(timeout=3) == 1, '异常帧必须拒绝')
        target = base / 'target'
        target.mkdir()
        link = base / 'link'
        link.symlink_to(target, target_is_directory=True)
        host = Host(link)
        check(host.process.wait(timeout=3) == 1, '拒绝符号链接目录')
        check(not list(target.iterdir()), '不应穿透符号链接目录')
        directory = base / 'file-link'
        directory.mkdir()
        private = base / 'private.json'
        private.write_text('SYNTHETIC_PRIVATE_MARKER')
        (directory / 'pairing.json').symlink_to(private)
        host = Host(directory)
        host.send({'type': 'hello', 'version': 1, 'clientID': str(uuid.uuid4())})
        check(host.process.wait(timeout=3) == 1, '拒绝符号链接配对文件')
        check(private.read_text() == 'SYNTHETIC_PRIVATE_MARKER', '不得读取后覆盖链接目标')
        check('SYNTHETIC_PRIVATE_MARKER' not in host.process.stderr.read().decode(), '不得日志泄露链接目标')


def timeout_and_heartbeat(host):
    host.hello()
    first_seen = host.file('presence.json')['lastSeenAt']
    identity = host.request()
    host.read()
    result = host.await_file('result.json', timeout=33)
    check(result['kind'] == 'timeout' and uuid.UUID(result['id']) == uuid.UUID(identity), '30秒必须由host超时')
    check(host.file('presence.json')['lastSeenAt'] > first_seen + 20000, '等待期间应每10秒刷新presence')
    host.result(identity, data={'usagePercent': 0, 'hasNonZeroIncludedLimit': True})
    time.sleep(0.2)
    check(host.file('result.json')['kind'] == 'timeout', '超时后的迟到结果必须忽略')
    check(host.close() == 0, '超时后仍可正常EOF')


if __name__ == '__main__':
    build()
    group('分帧握手、匹配、白名单、权限与EOF', lambda: with_host(framing_handshake_filter))
    group('过期/未来/旧代次拒绝、单请求与迟到响应', lambda: with_host(stale_generation_queue))
    group('配对绑定、重连代次与独占', lambda: with_host(pairing_and_lock))
    group('origin、异常帧与符号链接拒绝', bad_origin_framing_symlinks)
    group('30秒超时与10秒presence心跳', lambda: with_host(timeout_and_heartbeat))
    print(f'共 {GROUPS} 组，{CHECKS} 项断言，0 项失败。', flush=True)
