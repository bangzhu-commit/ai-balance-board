#!/usr/bin/env python3
"""Offline BrowserBridgeClient integration checks; synthetic temporary files only.

Requires the existing .build/direct BalanceCore module. Does not launch the app,
Chrome, Native Messaging, or any network request.
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build' / 'browser-client-checks'
MARKER = 'SYNTHETIC_PRIVATE_MARKER'
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
    module = ROOT / '.build' / 'direct'
    if not (module / 'BalanceCore.swiftmodule').is_file() or not (module / 'libBalanceCore.a').is_file():
        raise SystemExit('缺少 .build/direct BalanceCore，请先运行项目构建。')
    BUILD.mkdir(parents=True, exist_ok=True)
    harness = BUILD / 'ClientMain.swift'
    harness.write_text('''import Foundation
import BalanceCore

@main enum ClientCheckMain {
    static func main() async {
        let client = BrowserBridgeClient(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        var output: [String: Any]
        if CommandLine.arguments[1] == "connected" {
            output = ["generation": client.connectedGeneration() as Any? ?? NSNull()]
        } else {
            do {
                let reading = try await client.fetch()
                output = ["kind": "ok", "fetchedAt": reading.fetchedAt.timeIntervalSince1970 * 1000,
                          "source": reading.source, "service": reading.service.rawValue,
                          "metrics": reading.metrics.map { metric in
                    ["id": metric.id, "label": metric.label, "value": metric.value,
                     "remainingFraction": metric.remainingFraction as Any? ?? NSNull()] as [String: Any]
                }]
            } catch {
                let kind: String
                switch error {
                case BrowserBridgeFailure.unavailable: kind = "unavailable"
                case BrowserBridgeFailure.loginRequired: kind = "loginRequired"
                case BrowserBridgeFailure.busy: kind = "busy"
                case BrowserBridgeFailure.network: kind = "network"
                case BrowserBridgeFailure.limited: kind = "limited"
                case BrowserBridgeFailure.changed: kind = "changed"
                case BrowserBridgeFailure.invalid: kind = "invalid"
                case BrowserBridgeFailure.timeout: kind = "timeout"
                default: kind = "parserError"
                }
                output = ["kind": kind, "description": error.localizedDescription]
            }
        }
        let bytes = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data("\\n".utf8))
    }
}
''')
    subprocess.run([
        'swiftc', '-swift-version', '5', '-target', 'arm64-apple-macosx14.0',
        '-module-cache-path', str(ROOT / '.build' / 'clang-cache'), '-parse-as-library',
        '-I', str(module), '-L', str(module), '-lBalanceCore',
        str(ROOT / 'Sources/AIBalanceBoard/BrowserBridgeClient.swift'), str(harness),
        '-o', str(BUILD / 'BrowserClientChecks'),
    ], check=True)


def write_json(path, value):
    temporary = path.parent / ('.fixture-' + str(uuid.uuid4()))
    fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(value, stream)
    temporary.replace(path)


class Fixture:
    def __init__(self, base):
        self.directory = Path(base) / 'bridge'
        self.directory.mkdir(mode=0o700)
        self.generation = str(uuid.uuid4())
        self.processes = []

    def presence(self, **changes):
        value = {'version': 1, 'connected': True, 'generation': self.generation,
                 'lastSeenAt': time.time() * 1000}
        value.update(changes)
        write_json(self.directory / 'presence.json', value)
        return value

    def start(self, action='fetch', directory=None):
        process = subprocess.Popen([
            str(BUILD / 'BrowserClientChecks'), action, str(directory or self.directory),
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        return process

    def finish(self, process, timeout=4):
        stdout, stderr = process.communicate(timeout=timeout)
        check(process.returncode == 0, 'harness应正常退出')
        check(MARKER.encode() not in stdout + stderr, '输出不得含模拟私密字段')
        check(not stderr, '客户端不得意外写stderr')
        return json.loads(stdout)

    def request(self, excluding=None):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            path = self.directory / 'request.json'
            try:
                value = json.loads(path.read_text())
                if value.get('id') != excluding:
                    check(set(value) == {'version', 'id', 'generation', 'createdAt'}, '请求只含协议字段')
                    check(value['version'] == 1 and value['generation'] == self.generation, '请求版本与代次必须匹配')
                    check(str(uuid.UUID(value['id'])).lower() == value['id'].lower(), '请求必须带UUID')
                    check(abs(value['createdAt'] - time.time() * 1000) < 3000, '请求时间必须新鲜')
                    check(stat.S_IMODE(path.stat().st_mode) == 0o600, '请求文件必须600')
                    return value
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.025)
        raise AssertionError('未生成有效request.json')

    def response(self, request, **changes):
        value = {'version': 1, 'id': request['id'], 'generation': request['generation'],
                 'receivedAt': time.time() * 1000, 'kind': 'ok',
                 'data': {'usagePercent': 20.109194, 'hasNonZeroIncludedLimit': True,
                          'nextResetTimestampUtc': '2030-01-01T00:00:00Z',
                          'token': MARKER, 'email': MARKER}}
        value.update(changes)
        write_json(self.directory / 'result.json', value)
        return value

    def pending(self, process):
        time.sleep(0.55)
        check(process.poll() is None, '不匹配/不安全结果不能完成请求')

    def cleanup(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=3)
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()


def fixture(callback):
    with tempfile.TemporaryDirectory(prefix='balance-client-test-', dir='/private/tmp') as base:
        value = Fixture(base)
        try:
            callback(value)
        finally:
            value.cleanup()


def unavailable(f):
    check(f.finish(f.start())['kind'] == 'unavailable', '未安装presence应为unavailable')
    check(not (f.directory / 'request.json').exists(), '未连接时不能提交请求')
    for changes in [
        {'lastSeenAt': time.time() * 1000 - 30000},
        {'lastSeenAt': time.time() * 1000 + 10000},
        {'connected': False}, {'version': 2}, {'generation': 'not-a-uuid'},
    ]:
        f.presence(**changes)
        check(f.finish(f.start('connected'))['generation'] is None, '陈旧/异常presence不能声明已连接')
        check(f.finish(f.start())['kind'] == 'unavailable', '陈旧/异常presence必须拒绝查询')
    f.presence()
    check(f.finish(f.start('connected'))['generation'] == f.generation, '新鲜presence应返回正确代次')
    f.directory.chmod(0o755)
    check(f.finish(f.start())['kind'] == 'unavailable', '非私有目录必须拒绝')
    f.directory.chmod(0o700)


def success(f):
    f.presence()
    process = f.start()
    request = f.request()
    # Deliberately distinguish host receipt time from the client's later file-read time.
    received = time.time() * 1000 + 1500
    f.response(request, receivedAt=received)
    value = f.finish(process)
    check(value['kind'] == 'ok' and value['service'] == 'grok', '应返回Grok服务器读数')
    check(value['metrics'][0]['value'] == '79.9%', '服务器20.109194%已用应转换79.9%剩余')
    check(abs(value['metrics'][0]['remainingFraction'] - 0.79890806) < 1e-10, '应保留真实剩余比例')
    check(abs(value['fetchedAt'] - received) < 0.01, 'fetchedAt必须使用这次host receivedAt')
    check(value['source'].startswith('Grok Bot 服务器接口'), '数据来源应标明服务器')
    check(value['metrics'][0]['label'] == '每周剩余', '应准确显示周剩余含义')
    check(stat.S_IMODE((f.directory / 'app-request.lock').stat().st_mode) == 0o600, '本机锁文件必须600')


def mismatched_and_reconnected(f):
    f.presence()
    process = f.start()
    request = f.request()
    f.response(request, id=str(uuid.uuid4()))
    f.pending(process)
    f.response(request, generation=str(uuid.uuid4()))
    f.pending(process)
    f.response(request)
    check(f.finish(process)['metrics'][0]['value'] == '79.9%', '错id/旧代次后只接受匹配结果')
    next_process = f.start()
    next_request = f.request(excluding=request['id'])
    check(next_request['id'] != request['id'], '新查询必须使用新id')
    f.generation = str(uuid.uuid4())
    f.presence()
    f.response(next_request)
    check(f.finish(next_process)['kind'] == 'changed', '重连必须报changed且不能返回旧连接结果')


def error_states(f):
    previous = None
    for kind, expected in [
        ('loginRequired', 'loginRequired'), ('rateLimited', 'limited'),
        ('browserUnavailable', 'unavailable'), ('pageUnavailable', 'unavailable'),
        ('networkError', 'network'), ('httpError', 'network'), ('timeout', 'timeout'),
        ('unknown-' + MARKER, 'invalid'),
    ]:
        f.presence()
        process = f.start()
        request = f.request(excluding=previous)
        previous = request['id']
        f.response(request, kind=kind, detail=MARKER)
        value = f.finish(process)
        check(value['kind'] == expected, '错误状态映射不正确：' + expected)
        check('metrics' not in value and 'fetchedAt' not in value, '错误不能伪造读数或新鲜时间')
    for changes in [
        {'version': 2}, {'receivedAt': 0}, {'receivedAt': time.time() * 1000 + 30000},
        {'data': MARKER}, {'data': {'usagePercent': MARKER}},
        {'data': {'usagePercent': 'NaN', 'hasNonZeroIncludedLimit': True}},
    ]:
        f.presence()
        process = f.start()
        request = f.request(excluding=previous)
        previous = request['id']
        f.response(request, **changes)
        check(f.finish(process)['kind'] in ('invalid', 'parserError'), '畸形结果必须失败且不能泄露内容')


def exclusive_lock(f):
    f.presence()
    first = f.start()
    first_request = f.request()
    second = f.start()
    check(f.finish(second)['kind'] == 'busy', '同时第二个client必须被文件锁拒绝')
    check(json.loads((f.directory / 'request.json').read_text())['id'] == first_request['id'], '第二个client不能覆盖首请求')
    f.response(first_request)
    check(f.finish(first)['kind'] == 'ok', '首请求仍可成功')
    third = f.start()
    third_request = f.request(excluding=first_request['id'])
    f.response(third_request)
    check(f.finish(third)['kind'] == 'ok', '完成后必须释放锁')


def symlinks_and_unsafe_files(f):
    base = f.directory.parent
    presence = f.presence()
    outside = base / 'outside.json'
    write_json(outside, presence)
    path = f.directory / 'presence.json'
    path.unlink()
    path.symlink_to(outside)
    check(f.finish(f.start())['kind'] == 'unavailable', '不能穿透presence符号链接')
    check(json.loads(outside.read_text()) == presence, '链接目标不能改变')
    path.unlink()
    f.presence()
    alias = base / 'bridge-link'
    alias.symlink_to(f.directory, target_is_directory=True)
    check(f.finish(f.start(directory=alias))['kind'] == 'unavailable', '不能穿透桥接目录符号链接')
    lock = f.directory / 'app-request.lock'
    lock.unlink(missing_ok=True)
    lock.symlink_to(outside)
    check(f.finish(f.start())['kind'] == 'unavailable', '不能穿透lock符号链接')
    lock.unlink()
    path.chmod(0o644)
    check(f.finish(f.start())['kind'] == 'unavailable', '不能读取非私有presence')
    path.chmod(0o600)
    # A matching but symlinked result must never be accepted.
    process = f.start()
    request = f.request()
    response = f.response(request)
    write_json(outside, response)
    result_path = f.directory / 'result.json'
    result_path.unlink()
    result_path.symlink_to(outside)
    f.pending(process)
    result_path.unlink()
    result_path.write_text(' ' * 65537)
    result_path.chmod(0o600)
    f.pending(process)
    f.response(request)
    check(f.finish(process)['kind'] == 'ok', '只接受随后出现的合法常规结果文件')
    check(json.loads(outside.read_text()) == response, 'result链接目标不能改变')
    # Atomic rename safely replaces a request symlink without writing its target.
    request_path = f.directory / 'request.json'
    request_path.unlink()
    request_path.symlink_to(outside)
    following = f.start()
    next_request = f.request(excluding=request['id'])
    check(not request_path.is_symlink(), 'request原子写入不得保留/穿透符号链接')
    check(json.loads(outside.read_text()) == response, 'request原子写入不得修改链接目标')
    f.response(next_request)
    check(f.finish(following)['kind'] == 'ok', '安全替换request链接后可完成查询')


if __name__ == '__main__':
    build()
    group('未安装、过期/未来presence、连接与目录权限', lambda: fixture(unavailable))
    group('请求协议、79.9%剩余、服务器接收时间与隐私', lambda: fixture(success))
    group('错id、旧代次忽略及重连changed', lambda: fixture(mismatched_and_reconnected))
    group('登录/限流/网络错误和畸形结果不伪造读数', lambda: fixture(error_states))
    group('双client文件锁、请求不覆盖与锁释放', lambda: fixture(exclusive_lock))
    group('目录/文件符号链接、不安全文件和原子请求写入', lambda: fixture(symlinks_and_unsafe_files))
    print(f'共 {GROUPS} 组，{CHECKS} 项断言，0 项失败。', flush=True)
