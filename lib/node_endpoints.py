#!/usr/bin/env python3
"""从 Clash(mihomo) profile 里取出指定节点的 server/port。

用法: node_endpoints.py <profile.yaml> <节点名>
输出: 每行一个 IP或域名:端口
支持块式与 flow({...}) 式两种 proxy 写法。
"""
import re
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("用法: node_endpoints.py <profile.yaml> <节点名>", file=sys.stderr)
        return 2
    path, node = sys.argv[1], sys.argv[2]
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as exc:
        print(f"读不到 profile: {exc}", file=sys.stderr)
        return 1

    lines = text.splitlines()
    pat = re.compile(r'name:\s*["\']?' + re.escape(node) + r'["\']?\s*[,}]')
    for i, line in enumerate(lines):
        if not pat.search(line):
            continue
        segment = line if "{" in line else "\n".join(lines[i : i + 12])
        server = re.search(r'server:\s*["\']?([^,\s"\'}]+)', segment)
        if not server:
            continue
        ports = re.search(r'\bports?:\s*["\']?([0-9][0-9,\-]*)', segment)
        if not ports:
            continue
        for port in ports.group(1).replace(" ", "").split(","):
            print(f"{server.group(1)}:{port}")
        return 0

    print(f"profile 里找不到节点: {node}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
