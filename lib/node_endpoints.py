#!/usr/bin/env python3
"""从 Clash(mihomo) profile 里提取指定节点的 server:port。

用法: node_endpoints.py <profile.yaml> <节点名>
输出: 每行一个 IP或域名:端口
"""
import re
import sys


def extract_ports(segment: str) -> list[str]:
    m = re.search(r'\bports?:\s*["\']?([0-9][0-9,\-\s]*)', segment)
    if not m:
        return []
    raw = m.group(1).rstrip(",").strip()
    return [p.strip() for p in raw.split(",") if p.strip()]


def all_endpoints(path: str) -> list[str]:
    """profile 里所有节点的 server:port（不解析域名）。"""
    out: list[str] = []
    lines = open(path, encoding="utf-8").read().splitlines()
    for i, line in enumerate(lines):
        if not re.match(r"\s*-\s*name\s*:", line):
            continue
        segment = line if "{" in line else "\n".join(lines[i : i + 15])
        m = re.search(r'server:\s*["\']?([^,\s"\'}]+)', segment)
        if not m:
            continue
        server = m.group(1).strip()
        for p in extract_ports(segment):
            out.append(f"{server}:{p}")
    return out


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--all":
        for ep in all_endpoints(sys.argv[2]):
            print(ep)
        return 0
    if len(sys.argv) < 3:
        print("用法: node_endpoints.py <profile.yaml> <节点名> | --all <profile.yaml>", file=sys.stderr)
        return 2

    path, target_node = sys.argv[1], sys.argv[2]
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as exc:
        print(f"读不到 profile: {exc}", file=sys.stderr)
        return 1

    lines = text.splitlines()
    pat = re.compile(
        r'name:\s*["\']?' + re.escape(target_node) + r'["\']?\s*(?:[,}\s]|$)'
    )

    for i, line in enumerate(lines):
        if not pat.search(line):
            continue

        # 如果是 flow 风格 {...} 直接解析本行，否则截取后续 15 行
        segment = line if "{" in line else "\n".join(lines[i : i + 15])
        server_match = re.search(r'server:\s*["\']?([^,\s"\'}]+)', segment)
        if not server_match:
            continue
        server = server_match.group(1).strip()

        ports = extract_ports(segment)
        if not ports:
            continue

        for p in ports:
            print(f"{server}:{p}")
        return 0

    print(f"profile 里找不到节点: {target_node}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
