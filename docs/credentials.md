# SSH credentials in Pulse

This guide explains how Pulse stores the SSH keys you use to reach devices, why those keys behave the way they do, and what to expect when something changes about how Pulse is built or signed. It's written for the operators using Pulse day-to-day, with notes for anyone maintaining a fork or running a beta channel.

For the underlying architecture decisions see [ADR 0001](architecture/0001-ssh-terminal-and-web-foundations.md). This document doesn't restate those decisions; it explains what they mean in practice.

## The Secure Enclave, briefly

Modern Apple Silicon Macs and recent T2-based Intel Macs include a small dedicated cryptographic coprocessor called the Secure Enclave. Private keys generated inside it never leave: signature requests cross a hardware boundary, the key signs internally, the signature comes back out. The macOS kernel can't read the key. A user-space process can't read the key. Even with full disk access, an attacker can't extract the key. The only way to use it is to ask the Enclave to sign something on your behalf, and the Enclave only does that if it can verify a user is present (Touch ID, or device passcode).

Pulse's default credential tier puts SSH keys in the Secure Enclave. This is the strongest credential model the platform makes available.

## Why ECDSA P-256

The Secure Enclave only supports one signature algorithm: ECDSA over the NIST P-256 curve (`secp256r1`). Not Ed25519. Not RSA. Not anything else. This is hardware; no software change relaxes it.

`ecdsa-sha2-nistp256` was added to OpenSSH in version 6.5 (released January 2014) and has been accepted by every modern SSH server since. If you're connecting to gear from this decade, the algorithm isn't a compatibility concern.

If you must use Ed25519 or RSA — older industrial gear, vendor defaults that hardcode an algorithm, or interop with non-OpenSSH stacks — the legacy portable tier covers those cases. Trade-off: portable keys live in the regular Keychain as exportable bytes, not in hardware. The credential editor labels them "Legacy" so the choice is deliberate.

## Biometric gating

Every signing operation against a Secure Enclave credential prompts for Touch ID or your device passcode. There is no per-session cache. Connecting to a host, re-authenticating mid-session, running a `git fetch` over SSH inside a Pulse-managed shell — each signature triggers a prompt.

This is structural. The access control flags on the key (`kSecAccessControlBiometryAny` combined with `.privateKeyUsage` and `.devicePasscode` fallback) tell the Enclave to require user presence per use, and the prompt is driven by the Enclave itself rather than by Pulse asking `LAContext`. You can't relax it from inside Pulse; you'd have to generate a new credential with different access flags, which Pulse doesn't offer.

The biometric requirement survives changes to your Touch ID enrolment. Adding or removing a fingerprint, or changing the device passcode, does not invalidate existing credentials. The stricter alternative (`biometryCurrentSet`) would protect against an attacker who already possesses your device passcode enrolling their own biometric — a niche threat already gated by passcode possession. The operational cost of invalidating every credential on a routine Touch ID change isn't worth that marginal extra coverage.

The intent: every SSH session, and every authenticated action within it, has a human at the keyboard. No background process signs on your behalf.

## Where credentials live

Pulse has two credential tiers, distinguished by where the private material lives.

**Secure Enclave (default).** Private key material resides in the Enclave hardware and never leaves. The Keychain holds only an opaque reference — CryptoKit's `SecureEnclave.P256.Signing.PrivateKey.dataRepresentation`, an SE-encrypted blob that's useless to any other app and any other device. The blob lives in a `kSecClassGenericPassword` item under service `<bundle-id>.ssh` (for the Omega distribution build: `nz.net.omega.pulse.ssh`) and account `<credentialUUID>`. The service deriving from `Bundle.main.bundleIdentifier` rather than a hardcoded string makes the bundle reachability contract structural: a fork with a different `BUNDLE_IDENTIFIER` automatically lands credentials in a disjoint keychain namespace. The item lives under the access group `<TeamID>.<BundleID>`, uses access class `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, is pinned to the data-protection keychain, and is explicitly non-synchronisable.

**Legacy portable (PEM).** Private key material is a PEM-encoded byte string in the regular file-based Keychain, at key `ssh-cred-<UUID>-privateKey`. If the key has a passphrase, the passphrase lives at `ssh-cred-<UUID>-passphrase`. Access class `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background polling can read it when the device is unlocked-but-locked-screen.

Neither tier syncs to iCloud. Both are `ThisDeviceOnly`. A credential created on your work Mac doesn't follow you to your laptop. This is intentional and called out in the iCloud section below.

## Bundle ID and team ID coupling

This is the section to read carefully.

The access group on every Secure Enclave credential is `<TeamID>.<BundleID>`. For the Omega Networks distribution build of Pulse, that resolves to:

```
ADC5AJV3TU.nz.net.omega.pulse
```

Where `ADC5AJV3TU` is the Omega Networks Apple Developer team ID and `nz.net.omega.pulse` is the bundle identifier the app is signed under.

The Enclave uses the access group as part of how it authorises Keychain reads: only an app signed by the same team, under the same bundle ID, can ask the Enclave for that key reference. Change either half of the tuple and existing SE credentials become unreachable.

To be precise about what "unreachable" means:

- The private key material is still inside the Enclave. It hasn't been deleted.
- Pulse, signed under the new identity, cannot find it via the Keychain.
- There is no recovery procedure that brings the old key forward. Even the original signing identity wouldn't recover it without re-signing back to the original bundle and team.
- The orphaned Enclave entry remains until the device is wiped or the OS reclaims it.

This affects three scenarios:

**Forks.** If you fork Pulse and change the bundle ID (you almost certainly will, since you'd be signing under your own developer account), your operators' SE keys from any prior Pulse install are invisible to your build. They need to create new credentials and re-enrol the new public keys on every device they want to reach.

**Beta channels.** If you ship a `.beta` build alongside production with a different bundle ID (a common pattern), operators of the beta channel maintain a separate credential set from the production channel. SE keys created in beta don't follow them to production and vice versa.

**Re-signing.** If you change the signing team between releases (e.g. Omega Networks moves their App Store Connect organisation), every existing operator hits a one-time re-enrolment after the team change lands. Their credentials in the Pulse UI list will show, but signing will fail; they delete and recreate.

The design favours strictness over convenience. SSH credentials shouldn't silently follow an operator across trust boundaries — a build under a different signing identity is a different application from the OS's perspective, and Pulse treats it that way.

Pulse's strongest credential model relies on Apple's Secure Enclave hardware. Operators who need cross-platform key portability use the legacy tier and accept its weaker isolation. Pulse's sovereignty principles emphasise community-owned, portable tools; the SE-backed tier is the deliberate trade-off for hardware-grade isolation on Apple devices, and the legacy tier is the escape hatch when you need to move keys somewhere else.

## The Settings → SSH pane

Open Pulse → Settings → SSH (the **SSH** tab between PowerSense and Database) to manage credentials.

**Create Secure Enclave credential…** Generates a fresh ECDSA P-256 key inside the Enclave. You pick a label, click Generate. The OS may prompt you the first time the new keychain access group is touched. The new credential shows up as a row with a green Secure Enclave badge.

**Import legacy key (PEM)…** Imports a PEM-encoded private key into the regular Keychain. Two-step flow: the first screen labelled "Legacy (portable key)" explains what you're doing and why; you have to actively continue to reach the import form. The form classifies what you paste (Ed25519 / ECDSA / RSA / unknown) and asks for a passphrase only if the key is encrypted. After import, the credential row gets an orange Legacy badge.

**Copy public key (clipboard icon on each row).** Copies the OpenSSH `authorized_keys` line for that credential — `ecdsa-sha2-nistp256 AAAA…label` — to your clipboard so you can paste it into a switch or server's `~/.ssh/authorized_keys`. Available on Secure Enclave rows. Not shown on Legacy rows: the OpenSSH public-key line for a portable PEM is derived by the SSH signer at first use, so the row's caption reads "PEM stored — public key derived on first use" until that derivation has happened. Click triggers no biometric prompt; deriving a public key from an SE reference doesn't need user presence.

**Delete (trash icon).** Removes the secret material first (SE key from the Enclave, or PEM and passphrase from the Keychain), then removes the credential metadata from the local SwiftData store. If the Keychain delete fails, the credential row stays put so you can retry — an orphaned secret with no metadata is a worse end state than a row you can delete again.

## Debug inspection (Debug builds only)

In Debug builds of Pulse, right-clicking any credential row shows an **Inspect key attributes** option in the context menu. Picking it pops an alert showing the four Keychain attributes that matter:

```
Credential: Lab-1
Access group: ADC5AJV3TU.nz.net.omega.pulse
Token ID: (CryptoKit SE.P256 — generic-password storage)
Synchronizable: false
Access control: biometryAny OR devicePasscode, privateKeyUsage, WhenUnlockedThisDeviceOnly
```

What each value should be, and what it tells you:

- **Access group** — should be `<TeamID>.<BundleID>` for your build. If it's something else, the entitlement file isn't expanding correctly at sign time and SE writes will fail.
- **Token ID** — under Slice 3+ this field reports `(CryptoKit SE.P256 — generic-password storage)`. The placeholder string is honest about the storage shape: SE keys are stored as opaque CryptoKit `dataRepresentation` blobs in `kSecClassGenericPassword` items, which don't carry a `kSecAttrTokenID`. If this field shows `com.apple.setoken` you're looking at a pre-Slice-3 orphan that the current build cannot reach (see Troubleshooting). If blank, the key isn't actually SE-backed (something fell back to software).
- **Synchronizable** — must be `false`. If `true`, the credential could in principle leave the device via iCloud Keychain, which contradicts the whole credential model.
- **Access control** — sourced from the SecAccessControl flags set at creation for SE credentials; decoded from `kSecAttrAccessible` for portable ones. SE credentials should always show `biometryAny OR devicePasscode, privateKeyUsage, WhenUnlockedThisDeviceOnly`. Portable credentials should show `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Anything else is a misconfiguration.

This is the operator-side self-check. If a credential is misbehaving and you want to be sure the build is configured correctly without dropping into Xcode, run Inspect first.

Release builds compile this feature out entirely. The context-menu item is not present.

## Re-signing playbook

If you maintain a fork, run a beta channel, or are about to migrate the production bundle ID, here's what to expect and do:

1. **Pre-announce.** Tell operators they'll need to re-enrol. Provide a target date.
2. **Ship the new build.** Operators install it like any update.
3. **First launch under the new identity.** Existing Secure Enclave credential rows are still in the SwiftData store but their underlying keys are now unreachable. Attempting to use one fails with `errSecItemNotFound` (visible in the row's error alerts).
4. **Operators delete the orphaned rows.** Trash icon on each. The Keychain cleanup will succeed cleanly because there's nothing to delete (the rows reference keys the new build can't see anyway).
5. **Operators create new Secure Enclave credentials.** Same flow as initial setup.
6. **Re-enrol the new public keys on every device they connect to.** Copy public key → paste into the switch / router / server's `~/.ssh/authorized_keys`.

Legacy portable credentials are unaffected by team or bundle ID changes — they're regular Keychain items keyed by UUID, not access-group-scoped. Operators who imported their keys instead of generating SE-backed ones can keep using them across re-signs. This is one of the legacy tier's small upsides.

For fork maintainers specifically: **use a stable bundle ID from the start**. If you change it later, every operator on your fork hits the re-enrolment dance. Pick `<your-org-reverse-dns>.pulse` (or similar) at fork creation and don't change it.

## Troubleshooting

**`errSecItemNotFound` when using a credential that "should" exist.**
By far the most common cause is a bundle ID or signing team change between the install that created the credential and the install trying to use it. Verify in Debug builds via Inspect; if the access group doesn't match the current build's identity, the credential is from a previous incarnation. Delete and recreate.

**No biometric prompt fires when signing.**
Inspect the credential. Under the Slice 3+ storage model (CryptoKit's `SecureEnclave.P256.Signing.PrivateKey`) the Inspect alert reports `CryptoKit SE.P256 — generic-password storage` in the Token ID field; that's the expected value. If the credential predates the Slice 3 7a refactor it will not be findable at all (see the orphan note below) — delete the SwiftData row and regenerate. If the credential is current and signing still doesn't prompt, the most likely cause is the device having a configured biometric that's now in a "needs re-enrolment" state at the OS level; resolve at System Settings → Touch ID & Password before retrying.

**Orphan `kSecClassKey` entries from before Slice 3 7a.**
The Slice 1 implementation stored SE keys as `kSecClassKey` items with `kSecAttrTokenIDSecureEnclave`. Slice 3 7a migrated to `kSecClassGenericPassword` items carrying CryptoKit's `dataRepresentation`. Any pre-Slice-3 dev-test credentials become unreachable to the current build and stop appearing in Pulse's credential list; the underlying `kSecClassKey` entries remain in the data-protection keychain as harmless orphans taking trivial space. They cannot be used (the SecAccessControl is bound to the previous build's process) and Pulse no longer enumerates them. Clear with Keychain Access (search for `nz.omega.pulse.ssh.`) if tidy housekeeping matters; otherwise ignore.

**Public key shows "PEM stored, public key derived on first use" on a Legacy credential.**
Expected when the imported PEM is in an encrypted traditional form (`Proc-Type: 4,ENCRYPTED`) or a traditional EC PEM. Slice 3 derives the OpenSSH wire-format public key at import time for OpenSSH new-format (any algorithm, encrypted or not), unencrypted PKCS#1 RSA, and unencrypted PKCS#8 RSA — those credentials show the Copy public key button immediately. For the deferred cases, the auth delegate backfills the public key from the decrypted private material at first use.

**"Couldn't update credentials" alert during delete.**
The secret-material cleanup failed. The credential row stays in place so you can retry. Common causes: device locked partway through (deletion needs the unlocked-class state), or some other process is holding a reference to the Keychain entry. Wait a moment and try again.

**The credential editor refuses an imported PEM.**
The classifier didn't recognise it. Two likely reasons: a corrupted paste (line breaks munged by a chat app), or DSA (rejected on purpose; modern OpenSSH dropped DSA support). Try copying the PEM directly from the file rather than through an intermediate app.

## iCloud sync

Nothing in Pulse's SSH credential model is syncable. Both tiers are `ThisDeviceOnly`. The `kSecAttrSynchronizable` flag is explicitly set to `false` on Secure Enclave keys (defence-in-depth — the default for the data-protection keychain is already non-syncing, but Pulse sets it explicitly so a future code change can't quietly opt in). Legacy keys use `AfterFirstUnlockThisDeviceOnly`, which is also non-syncing.

Operators with multiple Macs maintain separate credential sets per machine. The Inspect feature on either machine should show the same access group string (because it's derived from team + bundle, which are identical across machines), but the credentials themselves are independent. Audit logs from each machine show distinct fingerprints.

## Memory residency of secret material

Imported PEM bodies and passphrases are held as `Data`-backed `@State` buffers in the legacy-import sheet (Slice 3 commit `baf9ce9`). On dismissal — Cancel, successful commit, or window close — `Data.resetBytes(in:)` zeroes the persistent buffers; no Pulse-owned plaintext residue remains after the sheet goes away. The `Configuration` setters accept `Data` directly and write `kSecValueData` to the Keychain without round-tripping through an intermediate `String`.

This is bounded but not absolute. Two residual exposures remain, called out honestly rather than papered over:

- **The SwiftUI text-input layer.** `TextEditor` and `SecureField` bind to `String`. Each keystroke materialises an ephemeral `String` via the `Binding<String>` adapter; the underlying AppKit/UIKit text-input maintains its own buffer Pulse cannot reach. Those instances are dropped to the runtime allocator without being zeroed.
- **The SSH auth-signing path.** When `SSHAuthDelegate` loads a portable PEM for signing, the bytes pass through a transient `String` to satisfy CryptoKit's `pemRepresentation` initialisers. The window is bounded by the SSH handshake duration (milliseconds) rather than by sheet lifetime, but the `String` is unzeroable. The conversion happens at the CryptoKit API boundary and cannot be avoided without writing our own PEM parser, which would be a worse trade than the residual exposure.

The improvement Slice 3 delivered is real: the persistent post-dismissal plaintext residue is gone. The improvement is not absolute: an attacker with code execution inside the Pulse process at the wrong moment can still observe secret material in the transient cases above. An attacker who has reached that level can observe much more besides.

## Lab test procedure

A five-minute end-to-end procedure to run before pushing changes that touch SSH credentials. Done on an Apple Silicon Mac with Touch ID enabled.

1. Fresh build of the current branch. Clean DerivedData if you've changed entitlements.
2. Open Pulse → Settings → SSH → **Create Secure Enclave credential**. Label it `Lab-1`. Click Generate. Expect no biometric prompt (creation doesn't sign anything; the prompt only fires on first signature). New row with green badge and SHA256 fingerprint.
3. Click the clipboard icon on the `Lab-1` row. Icon flips to a green checkmark for ~1.5 s. Paste somewhere (TextEdit, Terminal). Confirm the line begins `ecdsa-sha2-nistp256 ` and ends with ` Lab-1`. Run `ssh-keygen -lf -` and paste the line followed by Ctrl-D; the printed SHA256 fingerprint must match the row.
4. Right-click `Lab-1` → **Inspect key attributes**. Confirm:
   - Access group ends in `.nz.net.omega.pulse` (or your fork's bundle ID, prefixed by your team ID).
   - Token ID is `com.apple.setoken`.
   - Synchronizable is `false`.
   - Access control is `biometryAny OR devicePasscode, privateKeyUsage, WhenUnlockedThisDeviceOnly`.
5. Delete the `Lab-1` row. Confirmation dialog. Confirm.
6. Create `Lab-2`. Force-quit Pulse (Cmd-Q or Activity Monitor). Re-launch. Confirm `Lab-2` still appears in the list with its original fingerprint.
7. Click **Import legacy key (PEM)…**. Confirm the first screen says "Legacy (portable key)" in orange. Continue. Paste a known Ed25519 PEM. Validate. Expect "Detected: Ed25519 (OPENSSH PRIVATE KEY)" and no passphrase prompt. Import. Confirm the row has an orange Legacy badge.

If every step matches expectations, the credential model is intact for this build. Any deviation — particularly in step 4's Inspect output — is a signal to investigate before shipping.

## NZISM and similar regulatory frameworks

Pulse's credential model aligns with NZISM section 17 (Cryptography) by default: ECDSA P-256 (an approved algorithm per NZISM 17.1.40), SHA-256, hardware-generated and hardware-protected keys via the Secure Enclave (a hardware cryptographic module per NZISM 17.2.5), no deprecated algorithms accepted (DSA refused at import; no SHA-1 or 3DES anywhere), and per-signature human attestation contributing to multi-factor authentication per NZISM 16.4.

Outstanding:

- RSA portable signing is not supported in v1. The Slice 3 plan originally specified modulus enforcement at the importer (NZISM 17.1.40); implementation surfaced that `swift-nio-ssh` 0.13.0 carries no RSA private-key signing path, so v1 rejects RSA at the importer's front door with operator-facing remediation guidance. The modulus-enforcement code shipped briefly as defensive scaffolding and was deleted at the close of Slice 3 (recoverable from `git show 4238b35` if upstream NIOSSH ever ships RSA signing); the front-door reject is the single source of truth for the policy. Operators with RSA keys regenerate as ECDSA P-256/384/521 or Ed25519.
- SSH authentication-event audit logging is complete in v1 (Slice 3 wired this up end-to-end). Credential lifecycle under `ssh.credentials`, host-key decisions under `ssh.session`, auth outcomes under `ssh.auth`, certificate presentation outcomes under `ssh.certificates`, session lifecycle under `ssh.session`. Filter the full set with `log show --predicate 'subsystem == "pulse" AND category BEGINSWITH "ssh"'`.
- Centralised audit collection (NZISM 18.1) is a deployment concern. `os_log` events under the `pulse` subsystem can be forwarded to a SIEM via standard macOS logging pipelines.

## Related

- [ADR 0001 — SSH terminal & in-app web foundations](architecture/0001-ssh-terminal-and-web-foundations.md) — the underlying decisions.
- [CLAUDE.md](../CLAUDE.md) — repository conventions.
