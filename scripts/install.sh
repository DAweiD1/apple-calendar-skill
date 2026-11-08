#!/bin/bash
# 把本仓库安装 / 更新到 ~/.agents/skills/apple-calendar。
# 用法：bash scripts/install.sh [目标目录]
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-$HOME/.agents/skills/apple-calendar}"

if [ -z "$TARGET" ]; then
  echo "目标目录为空" >&2
  exit 1
fi

bash "$DIR/scripts/build.sh"

mkdir -p "$TARGET/bin" "$TARGET/src" "$TARGET/scripts"
cp "$DIR/SKILL.md" "$DIR/Info.plist" "$TARGET/"
cp "$DIR/src/main.swift" "$TARGET/src/"
cp "$DIR/scripts/build.sh" "$TARGET/scripts/"
cp "$DIR/bin/cal" "$DIR/bin/calendar" "$TARGET/bin/"
rm -rf "$TARGET/CalendarHelper.app"
cp -R "$DIR/CalendarHelper.app" "$TARGET/"
chmod +x "$TARGET/bin/cal" "$TARGET/scripts/build.sh"

# 不动用户已有配置
if [ ! -f "$TARGET/config.json" ]; then
  cp "$DIR/config.example.json" "$TARGET/config.json"
  echo "已生成 $TARGET/config.json，日历留空 = 用系统主日历"
fi

echo "installed: $TARGET"
echo "下一步：$TARGET/bin/cal calendars  # 首次会弹系统授权"
