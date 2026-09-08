#!/bin/bash
# Workaround for upstream SukiSU-Ultra builtin branch bug:
# commit d13e8a75 removed kernel_umount_feature_set() but left the
# .set_handler reference, which breaks every builtin kernel build.
# This script re-adds the setter (same behavior as pre-sync code).
set -e

FILE="${GITHUB_WORKSPACE:-.}/kernel_workspace/kernel_platform/KernelSU/kernel/feature/kernel_umount.c"

if [ ! -f "$FILE" ]; then
  echo "[fix-sukisu] 未找到 $FILE，跳过（可能 SukiSU 目录结构已变化）"
  exit 0
fi

python3 - "$FILE" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    src = f.read()

if "kernel_umount_feature_set(u64 value)" in src:
    print("[fix-sukisu] kernel_umount_feature_set 已存在，无需修复")
    sys.exit(0)

old = """static int kernel_umount_feature_get(u64 *value)
{
    *value = ksu_kernel_umount_enabled ? 1 : 0;
    return 0;
}
"""

new = old + """
static int kernel_umount_feature_set(u64 value)
{
    bool enable = value != 0;
    ksu_kernel_umount_enabled = enable;
    pr_info("kernel_umount: set to %d\\n", enable);
    return 0;
}
"""

if old in src:
    src = src.replace(old, new, 1)
    print("[fix-sukisu] 已补回 kernel_umount_feature_set")
else:
    # 兜底：若源码结构已变化，至少移除悬空的 set_handler 引用
    fixed = re.sub(r"\n\s*\.set_handler = kernel_umount_feature_set,", "", src)
    if fixed == src:
        print("[fix-sukisu] 未发现悬空引用，跳过（可能上游已修复）")
        sys.exit(0)
    src = fixed
    print("[fix-sukisu] 已删除悬空 .set_handler 引用")

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
PYEOF
