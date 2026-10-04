#!/bin/sh
# 薄入口：共享 pinned mini.test runner 负责收集、字面过滤和退出码
set -eu
tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=$(CDPATH= cd -- "$tests_dir/.." && pwd)
export VV_UTILS="${VV_UTILS:-$(dirname -- "$repo")/vv-utils.nvim}"
export NVIM_BIN="${NVIM_BIN:-nvim}"
if [ ! -f "$VV_UTILS/dev/test/run.sh" ]; then
  printf '找不到共享测试入口：%s；请检出包含 dev/test 的 vv-utils.nvim，或设置 VV_UTILS\n' "$VV_UTILS/dev/test/run.sh" >&2
  exit 1
fi
exec sh "$VV_UTILS/dev/test/run.sh" "$repo" "$@"
