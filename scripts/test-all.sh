#!/usr/bin/env bash
# 跑全部包的测试。
#
#   ./scripts/test-all.sh          # 增量
#   ./scripts/test-all.sh --clean  # 先清缓存（改过公共枚举/结构体后必用）
#
# 为什么要清缓存：给 CoreKit 的 ContentBlock 加一个枚举 case 会改变 ABI，
# 但 SPM 的增量构建偶尔不会重编下游测试目标，链接阶段才报
# "symbol(s) not found"，看起来像代码错误。清一次最省事。
set -euo pipefail

cd "$(dirname "$0")/.."
clean=false
if [ "${1:-}" = "--clean" ]; then clean=true; fi

for pkg in CoreKit LLMKit StorageKit AgentKit WebSeamKit; do
  if $clean; then
    (cd "Packages/$pkg" && swift package clean >/dev/null 2>&1 || true)
  fi
  printf '==> %s\n' "$pkg"
  (cd "Packages/$pkg" && swift test 2>&1 | grep -E 'Executed [0-9]+ tests|error:' | tail -2)
done
