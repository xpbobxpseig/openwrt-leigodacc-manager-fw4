#!/usr/bin/env python3
"""Heredoc-aware minifier for leigod-fw4.sh.

Removes standalone comment lines and blank lines OUTSIDE heredocs.
Keeps: shebang, all code lines, all heredoc content byte-identical.
"""
import re
import sys

HEREDOC_START = re.compile(r'<<-?\s*[\'"]?([A-Za-z_][A-Za-z0-9_]*)')

def minify(src_lines):
    out = []
    heredoc_stack = []  # active heredoc tokens
    for i, raw in enumerate(src_lines):
        line = raw.rstrip('\n')
        # strip trailing CR (defensive; source is LF)
        line = line.rstrip('\r')
        if heredoc_stack:
            out.append(line)
            if line == heredoc_stack[-1]:
                heredoc_stack.pop()
            continue
        m = HEREDOC_START.search(line)
        if m:
            heredoc_stack.append(m.group(1))
        stripped = line.strip()
        # keep shebang, drop blank lines and standalone comment lines
        if stripped == '' or (stripped.startswith('#') and not stripped.startswith('#!')):
            continue
        out.append(line)
    return out

def main():
    src = sys.stdin.buffer.read().decode('utf-8').splitlines()
    out = minify(src)
    # binary write: 避免 Windows 文本模式 \n -> \r\n
    sys.stdout.buffer.write(('\n'.join(out) + '\n').encode('utf-8'))

if __name__ == '__main__':
    main()
