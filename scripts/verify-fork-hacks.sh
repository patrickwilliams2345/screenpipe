#!/bin/bash
# verify-fork-hacks.sh — confirm no-paywall branch still has all fork hacks applied.
# Run after every upstream/main sync. Any FAIL = upstream drift, re-derive from current code.
# See FORK_HACKS.md for the full pattern.
#
# Note: pubkey checks require ~/.tauri/screenpipe-fork.key.pub (patrick's mac).
# On other machines, those 3 checks SKIP (not FAIL) — set SKIP_PUBKEY=1 to silence.

set -u
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || cd "$(dirname "$0")/.."

P=0; F=0; S=0
chk() { if eval "$2"; then echo "PASS: $1"; P=$((P+1)); else echo "FAIL: $1"; F=$((F+1)); fi; }
skip() { echo "SKIP: $1"; S=$((S+1)); }

# --- 1. Paywall bypass (6 choke points) — multiline-aware ---
chk "hasAppEntitlement returns true" \
  "grep -A4 'export function hasAppEntitlement' apps/screenpipe-app-tauri/lib/app-entitlement.ts | grep -q 'return true'"
chk "app_entitled_or_dev returns true" \
  "grep -A4 'fn app_entitled_or_dev' apps/screenpipe-app-tauri/src-tauri/src/store.rs | grep -q 'true'"
chk "require_app_entitlement returns Ok" \
  "grep -A4 'fn require_app_entitlement' apps/screenpipe-app-tauri/src-tauri/src/recording.rs | grep -q 'Ok(())'"
chk "useUsageStatus returns null" \
  "grep -A4 'export function useUsageStatus' apps/screenpipe-app-tauri/lib/hooks/use-usage-status.tsx | grep -q 'return null'"
chk "shouldWarnLowQuota returns false" \
  "grep -A6 'export function shouldWarnLowQuota' apps/screenpipe-app-tauri/lib/hooks/use-usage-status.tsx | grep -q 'return false'"
chk "UpgradeQuotaBanner returns null" \
  "grep -A4 'export function UpgradeQuotaBanner' apps/screenpipe-app-tauri/components/chat/standalone/upgrade-quota-banner.tsx | grep -q 'return null'"
chk "showSignedOutToast is no-op" \
  "grep -A3 'function showSignedOutToast' apps/screenpipe-app-tauri/lib/auth-guard.tsx | grep -qE 'no-paywall'"

# --- 2. Tauri signing key (pubkey swap in 3 configs) ---
PUBKEY_FILE="$HOME/.tauri/screenpipe-fork.key.pub"
if [ -f "$PUBKEY_FILE" ]; then
  PUBKEY=$(cat "$PUBKEY_FILE")
  for f in tauri.prod.conf.json tauri.beta.conf.json tauri.enterprise.conf.json; do
    chk "$f carries fork pubkey" \
      "grep -qF \"\$PUBKEY\" apps/screenpipe-app-tauri/src-tauri/$f"
  done
else
  for f in tauri.prod.conf.json tauri.beta.conf.json tauri.enterprise.conf.json; do
    skip "$f pubkey (no ~/.tauri/screenpipe-fork.key.pub)"
  done
fi

# --- 3. Workflow: R2 replaced with upload-artifact ---
chk "R2 macOS step removed" \
  "! grep -q 'Upload to Cloudflare R2 (macOS)' .github/workflows/release-app.yml"
chk "upload-artifact step present" \
  "grep -q 'actions/upload-artifact@v4' .github/workflows/release-app.yml"
chk "TAURI_SIGNING_PRIVATE_KEY in build env" \
  "grep -q 'TAURI_SIGNING_PRIVATE_KEY: \${{ secrets.TAURI_PRIVATE_KEY }}' .github/workflows/release-app.yml"

# --- 4. Workflow: arm64-only + skip notarization ---
# Matrix entries use `target: <triple>` — count non-arm64 target lines (should be 0).
chk "no non-arm64 matrix target entries" \
  "! grep -E 'target: (x86_64-apple-darwin|x86_64-pc-windows-msvc|aarch64-pc-windows-msvc|x86_64-unknown-linux-gnu)' .github/workflows/release-app.yml"
chk "notarize DMG step disabled" \
  "grep -A1 'Notarize and staple DMGs' .github/workflows/release-app.yml | grep -q '&& false'"
chk "staple .app step disabled" \
  "grep -A1 'Staple .app and rebuild updater tarball' .github/workflows/release-app.yml | grep -q '&& false'"

# --- 5. Fork secrets (requires gh CLI) ---
if command -v gh >/dev/null 2>&1; then
  SECRETS=$(gh secret list --repo patrickwilliams2345/screenpipe 2>/dev/null || echo "")
  for s in TAURI_PRIVATE_KEY TAURI_KEY_PASSWORD APPLE_CERTIFICATE APPLE_SIGNING_IDENTITY; do
    chk "secret $s present" "echo \"\$SECRETS\" | grep -q \"^$s\\b\""
  done
else
  for s in TAURI_PRIVATE_KEY TAURI_KEY_PASSWORD APPLE_CERTIFICATE APPLE_SIGNING_IDENTITY; do
    skip "secret $s (no gh CLI)"
  done
fi

echo "---"
echo "PASS=$P FAIL=$F SKIP=$S"
exit $F