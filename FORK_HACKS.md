# Fork Hacks — no-paywall branch

Re-apply these after every `upstream/main` sync. Upstream evolves the same files, so expect conflicts — re-derive from current code, don't blind-apply old patches.

## Sync pattern

```bash
git fetch upstream main
git checkout no-paywall
git reset --hard upstream/main
# re-apply the 4 hacks below
git push --force-with-lease=no-paywall:<old-sha> origin no-paywall
```

Backup before reset: `git branch backup/pre-sync-$(date +%Y%m%d)`.

---

## 1. Remove paywall + AI usage limits

Surgical `return true` / `return null` / `Ok(())` at 6 choke points. Mirror the `no-paywall:` comments so greps find them.

| File | Function | Change |
|---|---|---|
| `apps/screenpipe-app-tauri/lib/app-entitlement.ts` | `hasAppEntitlement()` | `return true` |
| `apps/screenpipe-app-tauri/lib/auth-guard.tsx` | `showSignedOutToast()` | no-op; strip dead imports (`toast`, `ToastAction`, `openLogin`, `screenpipeWebUrl`, `TOAST_COOLDOWN_MS`, `lastToastTime`) |
| `apps/screenpipe-app-tauri/lib/hooks/use-usage-status.tsx` | `useUsageStatus()` | `return null` |
| `apps/screenpipe-app-tauri/lib/hooks/use-usage-status.tsx` | `shouldWarnLowQuota()` | `return false` |
| `apps/screenpipe-app-tauri/lib/hooks/use-usage-status.tsx` | `messagesLeftForModel()` | `return null` |
| `apps/screenpipe-app-tauri/lib/hooks/use-usage-status.tsx` | `formatResetTime()` | `return ""` |
| `apps/screenpipe-app-tauri/components/chat/standalone/upgrade-quota-banner.tsx` | `UpgradeQuotaBanner` | `return null`; strip all dead imports |
| `apps/screenpipe-app-tauri/src-tauri/src/recording.rs` | `require_app_entitlement()` | `Ok(())` |
| `apps/screenpipe-app-tauri/src-tauri/src/store.rs` | `app_entitled_or_dev()` | `true` |

Keep `UsageStatus` interface + all exports so downstream imports (`ai-presets.tsx`, `chat-composer.tsx`) don't break. Knip will flag dead code if you strip too much — re-run `bun run knip` locally.

**Known CI fallout** (test-side, not runtime):
- `app-entitlement-gate.test.tsx` — 9 tests assert the gate blocks/pauses/re-verifies. Adapt or skip.
- `app-entitlement.test.ts` — 1 assertion flips.
- `zz-account-basic-upgrade-billing.spec.ts` — e2e tests the now-meaningless upgrade flow.

---

## 2. Tauri signing key

The fork has no upstream `TAURI_PRIVATE_KEY`. Generate a fork-owned keypair once, then swap the pubkey in 3 sibling configs.

### One-time setup (already done on patrick's mac)

```bash
mkdir -p ~/.tauri
export TAURI_KEY_PASSWORD="$(openssl rand -base64 24)"
printf '%s' "$TAURI_KEY_PASSWORD" > ~/.tauri/.fork-signer-password
chmod 600 ~/.tauri/.fork-signer-password
cd apps/screenpipe-app-tauri
./node_modules/.bin/tauri signer generate -w ~/.tauri/screenpipe-fork.key -p "$TAURI_KEY_PASSWORD"
# → ~/.tauri/screenpipe-fork.key (private)
# → ~/.tauri/screenpipe-fork.key.pub (public)

gh secret set TAURI_PRIVATE_KEY --repo patrickwilliams2345/screenpipe < ~/.tauri/screenpipe-fork.key
gh secret set TAURI_KEY_PASSWORD --repo patrickwilliams2345/screenpipe < ~/.tauri/.fork-signer-password
```

The private key + password live on one Mac (`~/.tauri/`). Don't commit them. Don't share them in 1Password unless you want other machines building.

### Re-apply on sync: swap pubkey in 3 configs

Replace the upstream pubkey (`dW50cnVzdGVk...IDIyQjQ2RkQz...`) with the fork pubkey from `~/.tauri/screenpipe-fork.key.pub` in:

- `apps/screenpipe-app-tauri/src-tauri/tauri.prod.conf.json` ← **this is the one the workflow actually uses**
- `apps/screenpipe-app-tauri/src-tauri/tauri.beta.conf.json`
- `apps/screenpipe-app-tauri/src-tauri/tauri.enterprise.conf.json`

### Critical workflow gotcha

`release-app.yml` has a step `Use production config for release` that runs:
```
cp apps/screenpipe-app-tauri/src-tauri/tauri.prod.conf.json apps/screenpipe-app-tauri/src-tauri/tauri.conf.json
```
**Edits to `tauri.conf.json` are silently overwritten.** Always edit `tauri.prod.conf.json`.

### Pass the key to the macOS Build step

The Build (with codesign retry) step env must include:
```yaml
TAURI_SIGNING_PRIVATE_KEY: ${{ secrets.TAURI_PRIVATE_KEY }}
TAURI_SIGNING_PRIVATE_KEY_PASSWORD: ${{ secrets.TAURI_KEY_PASSWORD }}
```
Without these, tauri build fails with `A public key has been found, but no private key`.

---

## 3. Remove R2 uploader — post DMG to workflow page

The fork has no `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` / `CLOUDFLARE_ACCOUNT_ID`. R2 upload fails with `Invalid endpoint: https://.r2.cloudflarestorage.com`.

Replace the `Upload to Cloudflare R2 (macOS)` step with `actions/upload-artifact@v4`:

```yaml
- name: Upload macOS artifacts
  if: matrix.os_type == 'macos'
  uses: actions/upload-artifact@v4
  with:
    name: screenpipe-${{ matrix.target }}
    path: |
      apps/screenpipe-app-tauri/src-tauri/target/${{ matrix.target }}/release/bundle/macos/*.app
      apps/screenpipe-app-tauri/src-tauri/target/${{ matrix.target }}/release/bundle/macos/*.tar.gz
      apps/screenpipe-app-tauri/src-tauri/target/${{ matrix.target }}/release/bundle/macos/*.sig
      apps/screenpipe-app-tauri/src-tauri/target/${{ matrix.target }}/release/bundle/dmg/*.dmg
    if-no-files-found: error
    retention-days: 90
```

The `.app`, `.dmg`, `.tar.gz`, and `.sig` are then downloadable from the Actions run page for 90 days.

---

## 4. Workflow: arm64-only + skip notarization

### Matrix — arm64 macOS only

`release-app.yml` `publish-tauri` matrix should have one entry:
```yaml
- platform: ${{ needs.check_commit.outputs.macos_arm_runner || 'macos-latest' }}
  args: "--target aarch64-apple-darwin --features metal,parakeet-mlx,rfdetr-mlx,redact-onnx-coreml"
  target: aarch64-apple-darwin
  tauri-args: "--target aarch64-apple-darwin --features metal,parakeet-mlx,rfdetr-mlx,redact-onnx-coreml,official-build"
  os_type: "macos"
```
Drop x86_64 macOS, Windows, Linux entries — fork has no secrets/runners for them.

### Skip notarization

Apple Development cert (not Developer ID) can't be notarized. Two steps get `&& false`:
- `Notarize and staple DMGs (macOS)` → `if: matrix.os_type == 'macos' && false`
- `Staple .app and rebuild updater tarball (macOS)` → `if: matrix.os_type == 'macos' && false`

And strip `APPLE_ID` / `APPLE_PASSWORD` / `APPLE_TEAM_ID` from the macOS Build step env — tauri's bundler treats their presence as a notarization request and fails with `Team ID must be at least 3 characters` when they're empty.

Keep `APPLE_SIGNING_IDENTITY` — codesigning still works.

---

## Fork secrets inventory

```
APPLE_CERTIFICATE          # .p12 base64
APPLE_CERTIFICATE_PASSWORD # .p12 password
APPLE_SIGNING_IDENTITY     # "Apple Development: Patrick Williams (Patrick Williams)"
TAURI_PRIVATE_KEY          # ~/.tauri/screenpipe-fork.key contents
TAURI_KEY_PASSWORD         # ~/.tauri/.fork-signer-password contents
PAT                        # github.com/patrickwilliams2345 PAT with repo + workflow scopes
```

Missing (intentionally): `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `CLOUDFLARE_ACCOUNT_ID`, `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`, `TAURI_PRIVATE_KEY` (upstream's), `TAURI_KEY_PASSWORD` (upstream's).

---

## Diagnosis pattern (for next agent)

1. **Read the failed step's log.** `gh run view <run-id> --log-failed --job <job-id> | tail -200 | grep -iE "error|fail|❌"`
2. **Don't guess.** Three failed builds this session came from guessing at Tauri's config merge semantics. The fourth succeeded because the log was read.
3. **`tauri.conf.json` edits are overwritten.** Always edit `tauri.prod.conf.json`.
4. **The bundler always signs the updater artifact** if a pubkey exists in any merged config. `active: false` doesn't help. Either swap the pubkey or delete the `plugins.updater` block from all configs.
5. **`bun install --frozen-lockfile`** must run before `bunx tauri signer generate` — the CLI is a node dep.