#!/usr/bin/env bash
set -euo pipefail

KSU_DIR="${1:-KernelSU}"
SELINUX_HIDE="$KSU_DIR/kernel/feature/selinux_hide.c"
KBUILD="$KSU_DIR/kernel/Kbuild"

if [ ! -f "$SELINUX_HIDE" ]; then
  echo "ReSukiSU SUSFS patch: $SELINUX_HIDE not found, skip"
  exit 0
fi

if [ -f "$KBUILD" ] && ! grep -q 'REPO_NAME := ReSukiSU' "$KBUILD"; then
  echo "ReSukiSU SUSFS patch: not a ReSukiSU tree, skip"
  exit 0
fi

python3 - "$SELINUX_HIDE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
original = text

def add_include(after: str, include: str) -> None:
    global text
    if include not in text:
        text = text.replace(after, after + include, 1)

add_include("#include <linux/memory.h>\n", "#include <linux/mm.h>\n")
add_include("#include <linux/version.h>\n", "#include <linux/jump_label.h>\n")

text = text.replace(
    "static bool ksu_selinux_hide_enabled __read_mostly = false;",
    "bool ksu_selinux_hide_enabled __read_mostly = false;",
)

fake_status_block = r'''
#ifdef CONFIG_KSU_SUSFS
DEFINE_STATIC_KEY_FALSE(fake_status_initialize_key);
struct page *fake_status = NULL;

void initialize_fake_status(void)
{
    struct page *status_page;
    struct selinux_kernel_status *status;
    struct selinux_kernel_status *new_status;
    struct page *new_page;

    status_page = selinux_kernel_status_page();
    if (!status_page) {
        pr_warn("selinux_hide: fake status skipped, no status page\n");
        return;
    }

    mutex_lock(&selinux_state.status_lock);
    if (fake_status)
        goto out;

    status = page_address(status_page);
    if (!status || !status->enforcing) {
        pr_warn("selinux_hide: fake status skipped, not enforcing\n");
        goto out;
    }

    new_page = alloc_page(GFP_KERNEL | __GFP_ZERO);
    if (!new_page) {
        pr_err("selinux_hide: fake status alloc failed\n");
        goto out;
    }

    new_status = page_address(new_page);
    memcpy(new_status, status, sizeof(*new_status));
    WRITE_ONCE(new_status->enforcing, 1);
    if (!new_status->policyload) {
        WRITE_ONCE(new_status->policyload, 1);
        WRITE_ONCE(new_status->sequence, 4);
    }

    fake_status = new_page;
    pr_info("selinux_hide: normalized status sequence=%u policyload=%u\n",
            new_status->sequence, new_status->policyload);

out:
    mutex_unlock(&selinux_state.status_lock);
}

static void ksu_selinux_hide_prepare_fake_status(void)
{
    initialize_fake_status();
    if (fake_status) {
        if (static_key_enabled(&fake_status_initialize_key))
            static_branch_disable(&fake_status_initialize_key);
    } else {
        pr_warn("selinux_hide: fake status need late initialization\n");
        if (!static_key_enabled(&fake_status_initialize_key))
            static_branch_enable(&fake_status_initialize_key);
    }
}
#else
#define ksu_selinux_hide_prepare_fake_status() do { } while (0)
#endif

'''

if "fake_status_initialize_key" not in text:
    anchor = "static int ksu_selinux_hide_enable()\n"
    if anchor not in text:
        raise SystemExit("ReSukiSU SUSFS patch: ksu_selinux_hide_enable anchor not found")
    text = text.replace(anchor, fake_status_block + anchor, 1)

prepare_fake_status_block = r'''
#ifdef CONFIG_KSU_SUSFS
static void ksu_selinux_hide_prepare_fake_status(void)
{
    initialize_fake_status();
    if (fake_status) {
        if (static_key_enabled(&fake_status_initialize_key))
            static_branch_disable(&fake_status_initialize_key);
    } else {
        pr_warn("selinux_hide: fake status need late initialization\n");
        if (!static_key_enabled(&fake_status_initialize_key))
            static_branch_enable(&fake_status_initialize_key);
    }
}
#else
#define ksu_selinux_hide_prepare_fake_status() do { } while (0)
#endif

'''

if "ksu_selinux_hide_prepare_fake_status" not in text:
    anchor = "static int ksu_selinux_hide_enable()\n"
    if anchor not in text:
        raise SystemExit("ReSukiSU SUSFS patch: ksu_selinux_hide_enable anchor not found")
    text = text.replace(anchor, prepare_fake_status_block + anchor, 1)

call = "    ksu_selinux_hide_prepare_fake_status();\n\n    return 0;\n"
if "ksu_selinux_hide_prepare_fake_status();\n\n    return 0;" not in text:
    anchor = "    return 0;\n\n#ifndef KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE\nunhook:\n"
    if anchor not in text:
        raise SystemExit("ReSukiSU SUSFS patch: selinux_hide enable return anchor not found")
    text = text.replace(anchor, call + "\n#ifndef KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE\nunhook:\n", 1)

disable = '''    if (static_key_enabled(&fake_status_initialize_key))
        static_branch_disable(&fake_status_initialize_key);

'''
if "selinux_hide: exit selinux hide" in text and "static_branch_disable(&fake_status_initialize_key)" not in text:
    anchor = '    pr_info("selinux_hide: exit selinux hide\\n");\n\n'
    text = text.replace(anchor, anchor + "#ifdef CONFIG_KSU_SUSFS\n" + disable + "#endif\n", 1)

if text != original:
    path.write_text(text)
    print("ReSukiSU SUSFS patch: selinux_hide fake status compatibility applied")
else:
    print("ReSukiSU SUSFS patch: already applied")
PY
