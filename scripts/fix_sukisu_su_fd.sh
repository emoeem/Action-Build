#!/bin/bash
# Workaround for an upstream API gap between susfs4ksu and SukiSU-Ultra:
#
# - Official KernelSU commit c72f294e (2026-09-06) introduced
#   ksu_install_su_fd() / the [ksu_driver_su] fd.
# - susfs4ksu's 50_add_susfs_in_gki-*.patch started calling it the same day.
# - SukiSU-Ultra main/builtin last synced official KernelSU on 2026-09-01,
#   so its driver does not provide ksu_install_su_fd() yet.
#
# Without this the final vmlinux link fails with:
#   ld.lld: error: undefined symbol: ksu_install_su_fd
#   >>> referenced by exec.c (do_execveat_common)
#
# This script adds a compatibility alias in the cloned KernelSU driver that
# maps ksu_install_su_fd() to the existing ksu_install_fd() (SukiSU has no
# su-session permission model yet). Once SukiSU syncs the upstream API the
# script detects the real function and does nothing.
set -e

KERNEL_DIR="${GITHUB_WORKSPACE:-.}/kernel_workspace/kernel_platform/KernelSU/kernel"
FILE="$KERNEL_DIR/supercall/supercall.c"

if [ ! -f "$FILE" ]; then
  echo "[fix-su-fd] 未找到 $FILE，跳过（可能 SukiSU 目录结构已变化）"
  exit 0
fi

if grep -rq "ksu_install_su_fd" "$KERNEL_DIR"; then
  echo "[fix-su-fd] ksu_install_su_fd 已存在，跳过（上游可能已同步）"
  exit 0
fi

cat >> "$FILE" <<'CEOF'

#ifdef CONFIG_KSU_SUSFS
/*
 * Compatibility shim managed by scripts/fix_sukisu_su_fd.sh.
 * Official KernelSU added ksu_install_su_fd()/[ksu_driver_su] in c72f294e,
 * which susfs4ksu's GKI patch now calls, but SukiSU-Ultra has not synced that
 * API yet. Map it to the only driver fd SukiSU currently provides.
 * Safe to remove once SukiSU syncs the upstream su-session fd model.
 */
int ksu_install_su_fd(void)
{
    return ksu_install_fd();
}
#endif
CEOF
echo "[fix-su-fd] 已补回 ksu_install_su_fd 兼容函数"
