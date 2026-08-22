#!/bin/sh

set -eu

tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
nvim_bin=${NVIM_BIN:-nvim}
passed=0

if [ -n "${NO_COLOR:-}" ]; then
  cyan=''
  green=''
  red=''
  reset=''
else
  cyan=$(printf '\033[36m')
  green=$(printf '\033[32m')
  red=$(printf '\033[31m')
  reset=$(printf '\033[0m')
fi

for test_file in "$tests_dir"/test_*.lua; do
  test_name=$(basename -- "$test_file")
  printf '%s执行%s: %s\n' "$cyan" "$reset" "$test_name"
  if "$nvim_bin" --headless -u NONE -l "$test_file"; then
    passed=$((passed + 1))
    printf '%s通过%s: %s\n' "$green" "$reset" "$test_name"
  else
    status=$?
    printf '%s失败%s: %s\n' "$red" "$reset" "$test_name" >&2
    exit "$status"
  fi
done

printf '%s通过%s: %d 个测试文件\n' "$green" "$reset" "$passed"
