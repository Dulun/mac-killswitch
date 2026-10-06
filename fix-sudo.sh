#!/bin/sh
# 一次性安装/修复 sudoers 白名单：只放行 pfctl 与 route，之后 ks 永久免密。
# 用法：  ./fix-sudo.sh      （会要一次密码）
set -eu

U="$(id -un)"
[ "$U" = "root" ] && U="${SUDO_USER:-}"
if [ -z "$U" ] || [ "$U" = "root" ]; then
  echo "请不要用 root 运行（用你自己的账号跑这个脚本）" >&2; exit 1
fi
id -u "$U" >/dev/null 2>&1 || { echo "用户 $U 不存在" >&2; exit 1; }

T="$(mktemp /tmp/mks-sudoers.XXXXXX)"
trap 'rm -f "$T"' EXIT
printf '# mac-killswitch: passwordless pf/routes for %s\n%s ALL=(root) NOPASSWD: /sbin/pfctl, /sbin/route\n' "$U" "$U" > "$T"

echo "→ 校验规则…"
sudo /usr/sbin/visudo -cf "$T" || { echo "规则校验失败，未做任何改动" >&2; exit 1; }

echo "→ 安装到 /etc/sudoers.d/mac-killswitch（覆盖旧的坏文件）…"
sudo /bin/sh -c "rm -f /etc/sudoers.d/mac-killswitch; /usr/bin/install -m 440 -o root -g wheel '$T' /etc/sudoers.d/mac-killswitch"

echo "→ 验证免密…"
if sudo -n /sbin/pfctl -s info >/dev/null 2>&1; then
  echo "✅ 完成：以后 ks 不会再问密码（也不会再有语法错误噪音）"
else
  echo "✘ 写入后仍未生效，请检查 /etc/sudoers.d/mac-killswitch" >&2; exit 1
fi
