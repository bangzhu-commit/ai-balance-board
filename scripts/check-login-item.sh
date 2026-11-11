#!/bin/bash
# 只读静态验证：不 source 安装器，不写 plist，不调用 launchctl，不启动应用。
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
installer="${script_dir}/install-login-item.sh"
/bin/bash -n "$installer"
/usr/bin/python3 - "$installer" <<'PY'
import ast, pathlib, plistlib, re, sys

source = pathlib.Path(sys.argv[1]).read_text()
blocks = re.findall(r"<<'PY'[^\n]*\n(.*?)\nPY\n", source, flags=re.S)
assert len(blocks) == 2, '预期两个 plist Python 片段'
for block in blocks:
    compile(block, '<embedded plist code>', 'exec')

class Arguments(ast.NodeTransformer):
    def visit_Subscript(self, node):
        if isinstance(node.value, ast.Attribute) and isinstance(node.value.value, ast.Name):
            if node.value.value.id == 'sys' and node.value.attr == 'argv':
                index = ast.literal_eval(node.slice)
                return ast.Constant({
                    2: 'local.outlier.ai-balance-board.login',
                    3: '/Users/test user/Applications/AI 额度看板.app',
                }[index])
        return self.generic_visit(node)

documents = []
for block, name in zip(blocks, ('expected', 'document')):
    assignment = next(n for n in ast.walk(ast.parse(block)) if isinstance(n, ast.Assign)
                      and any(isinstance(t, ast.Name) and t.id == name for t in n.targets))
    documents.append(ast.literal_eval(Arguments().visit(assignment.value)))

expected = {
    'Label': 'local.outlier.ai-balance-board.login',
    'ProgramArguments': ['/usr/bin/open', '-g', '/Users/test user/Applications/AI 额度看板.app'],
    'RunAtLoad': True,
    'LimitLoadToSessionType': 'Aqua',
}
assert documents == [expected, expected]
assert plistlib.loads(plistlib.dumps(documents[1])) == expected
assert not ({'KeepAlive', 'StartInterval', 'StartCalendarInterval', 'WatchPaths'} & expected.keys())
assert '-n' not in expected['ProgramArguments']
assert 'system/' not in source
print('通过：Shell/Python 语法、启动项完整契约、含空格中文路径、无保活/周期/多实例启动参数。')
print('范围：只读静态验证；未验证真实安装、回滚或系统登录。')
PY
