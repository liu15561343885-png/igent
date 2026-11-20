#!/usr/bin/env bash
# 一次逻辑改动 → 提交 → 变基拉取 → 推送。失败即停，不吞错误。
set -euo pipefail

if [ $# -lt 1 ] || [ -z "${1:-}" ]; then
  echo "用法: ./scripts/sync.sh \"提交信息\"" >&2
  echo "示例: ./scripts/sync.sh \"添加 SSE 解码器与两个 fixture\"" >&2
  exit 1
fi

cd "$(git rev-parse --show-toplevel)"

git add -A
if git diff --cached --quiet; then
  echo "没有可提交的改动，退出。"
  exit 0
fi

echo "==> 提交: $1"
git commit -m "$1"

# 首次推送时远程还没有 main 分支，此时跳过拉取
if git ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
  echo "==> 拉取并变基"
  git pull --rebase --autostash origin main
else
  echo "==> 远程尚无 main 分支，跳过拉取"
fi

echo "==> 推送"
git push -u origin main

echo "==> 完成: $(git log --oneline -1)"
