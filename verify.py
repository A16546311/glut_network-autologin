#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify.py —— 校验 install.sh 会生成出正确的 login.sh

用法：
    python3 verify.py                # 在项目目录内运行

它做两件事：
  1. 按 install.sh 的拼接规则（5 段 heredoc，其中两个 << EOF 段做变量展开）
     还原出它将要写盘的 login.sh
  2. 与 login.sh.reference 逐字节比较
"""
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
INSTALL = HERE / 'install.sh'
REFERENCE = HERE / 'login.sh.reference'

# 与 install.sh 中 VERSION 系列变量保持一致；若你改了 install.sh 顶部版本号，这里也要改
VERSION = 'v1.3.2'
VERSION_DATE = '2026-01-02'
VERSION_DESC = 'BusyBox兼容性修复与离线认证保护'


def main():
    if not INSTALL.exists():
        print(f'[FAIL] 找不到 {INSTALL}')
        return 2

    lines = INSTALL.read_text(encoding='utf-8').split('\n')
    hd = re.compile(r'<<\s*(\'?)([A-Z_]+)\1')
    out = []
    n_seg = 0
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = hd.search(ln)
        # 只认「往 $SCRIPT_FILE 追加内容的 heredoc」，且 heredoc 体以 #!/bin/sh 或 # 开头
        if m and '$SCRIPT_FILE' in ln and not ln.strip().startswith('#'):
            delim, quoted = m.group(2), m.group(1) == "'"
            j = i + 1
            body = []
            while j < len(lines) and lines[j] != delim:
                body.append(lines[j])
                j += 1
            if j >= len(lines):
                print(f'[FAIL] 第 {i+1} 行的 heredoc {delim} 缺少结束标记')
                return 2
            # 排除误匹配：heredoc 体不应包含 shell 代码块标记
            if any(b.startswith('```') for b in body):
                print(f'[FAIL] 第 {i+1} 行的 heredoc 体疑似误匹配（含 Markdown 代码块）')
                return 2
            if not quoted:      # << EOF 由 shell 展开变量
                body = [b.replace('$VERSION_DATE', VERSION_DATE)
                         .replace('$VERSION_DESC', VERSION_DESC)
                         .replace('$VERSION', VERSION) for b in body]
            out.extend(body)
            n_seg += 1
            i = j + 1
            continue
        i += 1

    if n_seg != 5:
        print(f'[FAIL] 期望解析到 5 段 heredoc，实际 {n_seg} 段 —— '
              f'install.sh 结构可能已变动，请检查 verify.py 的解析逻辑')
        return 2
    if not out or out[0].strip() != '#!/bin/sh':
        print(f'[FAIL] 生成内容首行不是 shebang，实际为: {out[0][:60]!r}')
        return 2

    generated = ('\n'.join(out) + '\n').encode('utf-8')

    # 同时校验生成的脚本语法（若本机有 sh）
    import subprocess
    import tempfile
    try:
        with tempfile.NamedTemporaryFile('wb', suffix='.sh', delete=False) as fh:
            fh.write(generated)
            tmp = fh.name
        r = subprocess.run(['sh', '-n', tmp], capture_output=True)
        syntax = 'OK' if r.returncode == 0 else f'FAIL ({r.stderr.decode(errors="replace").strip()})'
    except FileNotFoundError:
        syntax = '跳过（本机无 sh）'

    print(f'[解析] {n_seg} 段 heredoc -> 生成 {len(out)} 行')
    print(f'[语法] sh -n: {syntax}')

    if not REFERENCE.exists():
        print('[跳过] 没有 login.sh.reference，无法做逐字节比较')
        return 0

    ref = REFERENCE.read_bytes()
    if generated == ref:
        import hashlib
        print(f'[通过] 与 login.sh.reference 逐字节一致  '
              f'md5={hashlib.md5(generated).hexdigest()}  {len(generated)} 字节')
        return 0

    print(f'[不通过] 不一致：生成 {len(generated)} 字节 / 参考 {len(ref)} 字节')
    a, b = generated.split(b'\n'), ref.split(b'\n')
    shown = 0
    for idx, (x, y) in enumerate(zip(a, b), 1):
        if x != y:
            print(f'  行{idx}:')
            print(f'    生成: {x[:110]!r}')
            print(f'    参考: {y[:110]!r}')
            shown += 1
            if shown >= 10:
                break
    return 1


if __name__ == '__main__':
    sys.exit(main())
