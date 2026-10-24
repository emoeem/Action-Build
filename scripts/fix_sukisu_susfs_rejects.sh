#!/bin/bash
# Workaround for susfs patch include-hunk rejects on OnePlus sm8550 android13-5.15
# (SUBLEVEL >= ~180, kernel_manifest oneplus/sm8550):
#
#   fs/proc/task_mmu.c: Hunk #1 (adds #include <linux/susfs_def.h>) fails to apply
#     while all usage hunks succeed -> SUSFS_IS_INODE_* turn into implicit
#     function declarations and -Werror kills the build.
#   fs/namespace.c: Hunk #1 (adds the same include plus the SUS_MOUNT externs and
#     CL_COPY_MNT_NS define) fails the same way.
#
# The workflow applies the susfs patch with `patch -p1 ... || true` and
# check_rejects only warns, so the build reaches the compiler in this broken
# state. This script re-adds the missing declarations whenever the usage is
# present but the declaration is not (idempotent).
set -e

COMMON="${GITHUB_WORKSPACE:-.}/kernel_workspace/kernel_platform/common"

if [ ! -d "$COMMON" ]; then
  echo "[fix-susfs-rejects] 未找到 $COMMON，跳过（目录结构可能已变化）"
  exit 0
fi

python3 - "$COMMON" <<'PYEOF'
import os
import re
import sys

common = sys.argv[1]

GUARDED_INCLUDE = (
    "#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n"
    "#include <linux/susfs_def.h>\n"
    "#endif // susfs_def.h include\n"
)

KSU_INCLUDE = (
    "#ifdef CONFIG_KSU_SUSFS\n"
    "#include <linux/susfs_def.h>\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS\n"
)

SUS_MOUNT_BLOCK = (
    "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
    "extern bool susfs_is_current_ksu_domain(void);\n"
    "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n"
    "\n"
    "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n"
    "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
)


def last_include_end(src):
    pos = -1
    for m in re.finditer(r"^#include .*$", src, re.M):
        pos = m.end()
    return pos


def fix_file(rel, need_include, extra_block=None):
    full = os.path.join(common, rel)
    if not os.path.exists(full):
        print(f"[fix-susfs-rejects] {rel} 不存在，跳过")
        return
    with open(full, encoding="utf-8") as f:
        src = f.read()

    changed = False
    has_include = "#include <linux/susfs_def.h>" in src
    need = need_include(src)

    if need and not has_include:
        block = (KSU_INCLUDE + "\n" + extra_block) if extra_block else GUARDED_INCLUDE
        pos = last_include_end(src)
        if pos == -1:
            print(f"[fix-susfs-rejects] {rel} 中找不到 #include，跳过")
        else:
            src = src[:pos] + "\n" + block + src[pos:]
            changed = True
            print(f"[fix-susfs-rejects] 已为 {rel} 补回 susfs_def.h 声明块")
    elif extra_block and "CL_COPY_MNT_NS" in src and "#define CL_COPY_MNT_NS" not in src:
        pos = last_include_end(src)
        if pos != -1:
            src = src[:pos] + "\n" + extra_block + src[pos:]
            changed = True
            print(f"[fix-susfs-rejects] 已为 {rel} 补回 CL_COPY_MNT_NS 定义")

    if changed:
        with open(full, "w", encoding="utf-8") as f:
            f.write(src)
        rej = full + ".rej"
        if os.path.exists(rej):
            os.remove(rej)
            print(f"[fix-susfs-rejects] 已移除遗留的 {rel}.rej")


# task_mmu.c：宏使用已打进、include 没打上的典型受害者
fix_file("fs/proc/task_mmu.c", lambda s: "SUSFS_IS_INODE_" in s)

# namespace.c：include + SUS_MOUNT externs + CL_COPY_MNT_NS 一并补回
def ns_need(s):
    return "CL_COPY_MNT_NS" in s or "susfs_is_current_ksu_domain" in s or "SUSFS_IS_INODE_" in s


fix_file("fs/namespace.c", ns_need, extra_block=SUS_MOUNT_BLOCK)

# 兜底：fs/ 下其它"用了宏却没 include"的 .c 文件
for root, _, files in os.walk(os.path.join(common, "fs")):
    for name in files:
        if not name.endswith(".c"):
            continue
        p = os.path.join(root, name)
        rel = os.path.relpath(p, common)
        if rel in ("fs/proc/task_mmu.c", "fs/namespace.c"):
            continue
        try:
            with open(p, encoding="utf-8", errors="ignore") as f:
                s = f.read()
        except OSError:
            continue
        if "SUSFS_IS_INODE_" in s and "#include <linux/susfs_def.h>" not in s:
            fix_file(rel, lambda s: "SUSFS_IS_INODE_" in s)
PYEOF

echo "[fix-susfs-rejects] 完成"
