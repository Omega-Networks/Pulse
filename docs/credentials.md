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

The access group on every Secure Enclave credential is `<TeamID>.<BundleID>`. For example, a build signed under team `ABCDE12345` with bundle ID `nz.net.omega.pulse` resolves to:

```
ABCDE12345.nz.net.omega.pulse
```

Where `ABCDE12345` stands in for your Apple Developer team ID and `nz.net.omega.pulse` is the bundle identifier the app is signed under.

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
Access group: ABCDE12345.nz.net.omega.pulse
Token ID: (CryptoKit SE.P256 — generic-password storage)
Synchronizable: false
Access control: biometryAny OR devicePasscode, privateKeyUsage, WhenUnlockedThisDeviceOnly
```

What each value should be, and what it tells you:

- **Access group** — should be `<TeamID>.<BundleID>` for your build. If it's something else, the entitlement file isn't expanding correctly at sign time and SE writes will fail.
- **Token ID** — current builds report this field as `(CryptoKit SE.P256 — generic-password storage)`. The placeholder string is honest about the storage shape: SE keys are stored as opaque CryptoKit `dataRepresentation` blobs in `kSecClassGenericPassword` items, which don't carry a `kSecAttrTokenID`. If this field shows `com.apple.setoken` you're looking at an orphan from a previous storage model that the current build cannot reach (see Troubleshooting). If blank, the key isn't actually SE-backed (something fell back to software).
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
Inspect the credential. Under the current storage model (CryptoKit's `SecureEnclave.P256.Signing.PrivateKey`) the Inspect alert reports `CryptoKit SE.P256 — generic-password storage` in the Token ID field; that's the expected value. If the credential predates the CryptoKit migration it will not be findable at all (see the orphan note below); delete the SwiftData row and regenerate. If the credential is current and signing still doesn't prompt, the most likely cause is the device having a configured biometric that's now in a "needs re-enrolment" state at the OS level; resolve at System Settings → Touch ID & Password before retrying.

**Orphan `kSecClassKey` entries from before the CryptoKit migration.**
An earlier implementation stored SE keys as `kSecClassKey` items with `kSecAttrTokenIDSecureEnclave`. The CryptoKit migration moved storage to `kSecClassGenericPassword` items carrying CryptoKit's `dataRepresentation`. Any dev-test credentials from before that migration become unreachable to the current build and stop appearing in Pulse's credential list; the underlying `kSecClassKey` entries remain in the data-protection keychain as harmless orphans taking trivial space. They cannot be used (the SecAccessControl is bound to the previous build's process) and Pulse no longer enumerates them. Clear with Keychain Access (search for `nz.omega.pulse.ssh.`) if tidy housekeeping matters; otherwise ignore.

**Public key shows "PEM stored, public key derived on first use" on a Legacy credential.**
Expected when the imported PEM is in an encrypted traditional form (`Proc-Type: 4,ENCRYPTED`) or a traditional EC PEM. The importer derives the OpenSSH wire-format public key at import time for OpenSSH new-format (any algorithm, encrypted or not), unencrypted PKCS#1 RSA, and unencrypted PKCS#8 RSA; those credentials show the Copy public key button immediately. For the deferred cases, the auth delegate backfills the public key from the decrypted private material at first use.

**"Couldn't update credentials" alert during delete.**
The secret-material cleanup failed. The credential row stays in place so you can retry. Common causes: device locked partway through (deletion needs the unlocked-class state), or some other process is holding a reference to the Keychain entry. Wait a moment and try again.

**The credential editor refuses an imported PEM.**
The classifier didn't recognise it. Two likely reasons: a corrupted paste (line breaks munged by a chat app), or DSA (rejected on purpose; modern OpenSSH dropped DSA support). Try copying the PEM directly from the file rather than through an intermediate app.

## Connecting to a device

The SSH terminal opens from any device row's context menu, "Open SSH Terminal". The item is disabled when the device has no `primaryIP` recorded in NetBox; populate that field in NetBox first.

When you open the terminal, Pulse presents an inline connect form before any handshake runs. The form shows the connection target (host:port), a Username field, a Credential picker, and a small biometric hint that tells you how many Touch ID prompts the upcoming connection will fire. The Connect button stays disabled until you've supplied a non-empty username and picked a credential explicitly — there's no "first credential in your list" silent default, because picking the wrong-tier credential against a sensitive device is the kind of mistake the form exists to catch. After a failed connection the same form re-appears with the failure reason as a banner above it; fix the field that was wrong and click Connect again, no need to close the window.

If the device row has both a default username and a default credential set, and the credential still exists in your local store, the form is bypassed and the connection auto-fires on window open — preserving the "double-click and go" muscle memory for fully-configured devices. After any failure the form always shows, regardless of defaults, so you can think about what went wrong before retrying. The form runs the full handshake on Connect: TCP connect, host-key check, user-auth, channel open, PTY request, shell.

**Save as default.** The form carries a "Save as default for this device" checkbox below the credential picker (device mode only — the checkbox does not render for the Debug menu's ad-hoc surface, which has no Device row to persist to). Tick the box, fill the form, click Connect; if the connection succeeds, Pulse writes your username and credential choice to the device row, and the next open of this device row auto-fires with no form. The persistence happens **only after the connection reaches `connected`** — a failed handshake never writes incorrect defaults, regardless of whether the box was ticked. The posture is explicit opt-in rather than silent-persist-on-every-success: shared or jumphost credentials in a multi-operator team would otherwise stomp each other's defaults on autopilot, and one extra click per "make this the default" is the right trade against that. A small "Clear saved defaults" button appears below the Connect button when the device row has either default field populated; tapping it nils both fields in one transaction, leaving the device in the un-configured state where the next open shows the empty form. If saving the defaults fails (a SwiftData write error, full disk), the audit log under `category == "ssh.session"` carries the error and your session continues uninterrupted — the persistence is opportunistic and never blocks the operator's terminal.

The first SSH connection of an app session triggers two biometric prompts back-to-back. The first signs the user-auth handshake against the Secure Enclave credential; the second unwraps the session-recording wrapping key if recording is enabled on the credential. Subsequent connections during the same app session re-trigger the signing prompt (per ADR §1, there is no per-session cache) but reuse the already-unwrapped recording key.

Each open invocation activates an existing terminal window for the same device when one is already on screen (SwiftUI's per-value `WindowGroup` semantics). One terminal per device matches the operator mental model and avoids the "did I leave one open?" footgun. If you need a second session against the same device, close the first window first.

While the terminal is open, every keystroke flows directly to the SSH session and every byte from the server renders into SwiftTerm. The window toolbar carries a status pill: a colour-coded dot plus a one-word label tracking the connection state. Connecting is yellow (handshake in flight), Connected is green (the steady state), Disconnected is neutral (a clean teardown), Failed is red (a connection error). The pill is hidden in the Idle state before the first attempt. Next to it, a context-sensitive primary action button reads **Disconnect** while connected (closes the window and tears down the session) and **Reconnect** once disconnected or failed (re-fires the connection against the username and credential the form captured; the in-view Close button is its deliberate complement). When connected, an in-view endpoint strip below the toolbar shows the live `host:port` target in monospace, so you can confirm where your keystrokes are going before you type.

**Closing the terminal closes the connection.** When you close the window, Pulse cancels the connection task, which tears down the SSH session, finalises the recording if one was running (the `.meta` sidecar gets `closed_at` and `chain_head_hash`), and shuts down the SwiftNIO event loop. There is no idle-disconnect timer; the connection lives until you close it or the server hangs up.

For lab testing, the Debug menu's "Open SSH Test Window" surface offers a device picker that routes through the same context-menu gesture. Register a device with `primaryIP = 127.0.0.1` once and the debug surface gives you a one-click path to a loopback terminal against a `Remote Login`-enabled dev Mac.

## Terminal preferences

A small set of operator preferences live as global `@AppStorage` keys. Defaults are sensible and Pulse ships without a Settings UI surface for them; operators who need to change them can override via `defaults write nz.net.omega.pulse <key> <value>` while Pulse is not running. A future Settings → SSH "Terminal preferences" sub-pane will surface the toggles without migrating storage.

**Bell behaviour.** When the server emits BEL (`^G`, `0x07`), Pulse fires an audible beep and a brief visual flash on the terminal area by default. Both axes are independently toggleable:

- `pulse.terminal.bell.audible` — Bool, defaults `true`. Audible beep on `^G`. macOS uses `NSSound.beep` (respects your Sound preferences and system volume); iOS uses a warning haptic in lieu of audio because most ops happen on devices in silent mode. Audible bells are rate-limited to ~4 Hz (a 250 ms sliding window between fires) so a server sending `\a` in a tight loop produces a recognisable beep cadence rather than a continuous tone or a queue of beep calls.
- `pulse.terminal.bell.visual` — Bool, defaults `true`. Brief 120 ms white overlay at 18 % opacity. Long enough to register peripherally without obscuring contents; repeated bells from a runaway script hold the flash and fade cleanly once the bell storm subsides.

The closure that handles the bell reads both keys from `UserDefaults` at fire time (not at session-connect time), so toggling either preference mid-session takes effect on the next bell without a reconnect.

**Font size.** Pulse pins the terminal font to a single global size for consistency across reconnects and across device targets — font preference is a personal-environment setting, not a per-device one (matches Terminal.app, iTerm, Ghostty).

- `pulse.terminal.fontSize` — Double, defaults `12.0`, clamped to the range `[9.0, 24.0]`. The clamp applies on read and on write so a stale UserDefaults value outside the bound still produces a sane render.

Adjust the size at runtime:

- **macOS:** Cmd-+ or Cmd-= grows the font by one point, Cmd-- shrinks by one point, Cmd-0 returns to the 12-point default. The shortcuts live on invisible buttons inside the terminal view and are active whenever the window is frontmost.
- **iOS:** Pinch on the terminal area. Pinch composes with SwiftTerm's existing one-finger scroll gesture because pinch requires two fingers.

**Scroll-to-bottom-on-input.** When you type while scrolled back in scrollback, Pulse snaps the viewport to the latest line *before* the keystroke renders. This is the standard terminal-emulator UX (Terminal.app, iTerm, tmux, screen all behave the same way); no preference exists because off-behaviour for this gesture would silently lose the operator's correlation between what they typed and what they see on screen.

**Recording badge.** When you connect with a credential whose `recordSessions` flag is on, an SF Symbol `record.circle.fill` icon plus the word "Recording" appears in the window toolbar, where session-state indicators conventionally live (matching Terminal.app and iTerm). The badge is red but uses a distinct symbol shape so it cannot be mistaken for the red `.failed` status dot in the pill. The badge clears automatically when the session ends (clean disconnect, server hang-up, window close).

The badge tracks credential intent + session state. If the recording stack fails mid-session (encryption error, disk full, internal queue overflow), the writer transitions to a terminal stop and emits `session.recording.failed` in the audit log; the session continues but the badge stays on until the session itself ends. The audit log is the source of truth on whether bytes are actually being written; the badge is the operator-facing intent signal.

## Host-key mismatch

When you connect to a device for the first time, Pulse pins (TOFU) the server's host key fingerprint to a `KnownHost` row in the local SwiftData store. Every subsequent connection compares the presented fingerprint to the stored pin. A match proceeds silently; a mismatch triggers the mismatch sheet.

The mismatch sheet displays:

- The host and port being connected to.
- The **stored** fingerprint, the algorithm under which it was pinned, and the date Pulse first saw it.
- The **presented** fingerprint and algorithm — what the server is offering right now.
- Three operator actions.

The three actions:

- **Accept** (amber). You've confirmed this is a legitimate key rotation (the operator at the other end re-keyed sshd; a hardware upgrade; a certificate renewal). Pulse replaces the stored pin with the new fingerprint and the connection proceeds. The audit log captures `host.mismatch.accepted` with both fingerprints. **The intent is logged before the trust-store commit**: if the commit fails (storage corruption, sandbox permission, full disk), an additional `host.mismatch.accepted.commit_failed` error event lands in the audit log carrying the failure reason, and the connection aborts. SIEM rules keyed on `host.mismatch.accepted` (leading-token match) record your intent unconditionally; the `.commit_failed` sub-event is the diagnosis hook for trust-store problems.
- **Reject** (red, default focus). You don't trust the new key. The connection aborts with `fingerprintMismatch`; the stored pin is unchanged. The audit log captures `host.mismatch.rejected`. **This is the default**: a stray Return key on the sheet rejects rather than accepts, so you cannot accidentally trust a man-in-the-middle just by pressing Enter.
- **Forget** (neutral). You want to abandon the trust relationship entirely and let the next connection TOFU fresh. Pulse deletes the stored row; the connection aborts. The next connection will pin whatever fingerprint it sees. The audit log captures `host.mismatch.forgotten`, and a `host.mismatch.forgotten.commit_failed` lands if the delete fails (same diagnosis hook shape as the Accept path).

**Sheet dismissal is restricted to the three buttons.** iOS swipe-down and macOS unintended dismissal are blocked (`.interactiveDismissDisabled()`), so the audit trail always carries one of the three explicit decisions or one of the system-driven outcomes below; there is no "the sheet just vanished" path.

The sheet has a **90-second decision timeout**. If you walk away or get distracted, the sheet self-dismisses after 90 seconds and the connection rejects with `reason: "decision_timeout"` in the audit log. This bounds the half-open SSH channel: a real operator decision takes seconds, and 90 seconds is plenty for "actually read both fingerprints and decide".

**Parent-task cancellation** (you closed the terminal window mid-decision, or navigation popped the view) resolves the decide call **immediately** with `reason: "cancelled"` rather than holding for the 90-second timeout. The audit log distinguishes "walked away" (`decision_timeout`) from "closed the window" (`cancelled`); operations runbooks should treat them differently — walked-away suggests the operator was interrupted and may return; closed-the-window suggests the operator deliberately abandoned the connection attempt.

**Contract-violation degrade.** The mismatch coordinator's contract is one decision at a time per terminal view. If two `decide` calls overlap (a defect in calling code, not the operator's fault), the second resolves to `reason: "concurrent_decide"` and a `hostkey.coordinator.concurrent_decide` fault-level event lands in the unified log. The first decision continues normally. This is a release-build degrade, not a crash; the SIEM signal is the diagnosis hook for the upstream defect.

The full reject-reason vocabulary is documented in the ADR (`docs/architecture/0001-ssh-terminal-and-web-foundations.md` §7, "Reject-reason vocabulary").

**The trust store is the source of truth.** The sheet only gathers your decision; the `SSHHostKeyDelegate` mutates `KnownHost` and emits the audit event. The UI never writes to the trust store directly. This means a future "Forget all hosts" gesture, or an automated policy that revokes certain hosts on alert, can run through the same delegate code path.

**Lab procedure.** A repeatable end-to-end walk to verify the mismatch flow on a fresh build. Done on an Apple Silicon Mac with Remote Login enabled and a credential targeting the loopback dev Mac (`primaryIP = 127.0.0.1`).

1. Fresh build of the current branch. Backup the dev Mac's sshd host keys: `sudo cp /etc/ssh/ssh_host_* /tmp/ssh-keys-backup/`.
2. Open Pulse. Connect once via the device row context menu to populate the `KnownHost` row (TOFU pin). Confirm `host.pinned` lands in `log show --predicate 'subsystem == "pulse" AND category == "ssh.session"' --last 1m`.
3. Disconnect. Rotate the sshd host keys on the dev Mac: `sudo /usr/bin/ssh-keygen -A` followed by `sudo /usr/sbin/launchctl kickstart -k system/com.openssh.sshd`.
4. Reconnect from Pulse. The mismatch sheet appears displaying the stored fingerprint, the new fingerprint, and three actions.
5. Walk each action in a fresh connection attempt (restart the connect-and-disconnect cycle for each):
   - **Accept.** Click Accept. Confirm `host.mismatch.accepted` (warning level) lands in the audit log *before* any commit-related event. Confirm the next reconnection succeeds silently against the new pin (no sheet). To force the `.commit_failed` path, temporarily revoke write access to the SwiftData store (e.g. `chmod -w` on the container path) before clicking Accept; confirm both `host.mismatch.accepted` and `host.mismatch.accepted.commit_failed` (error) land, with leading-token-disjoint names (a substring rule on the intent does not match the failure line).
   - **Reject.** Click Reject. Confirm `host.mismatch.rejected` (warning) with no `reason` field. Confirm the stored `KnownHost` row is unchanged (next reconnect surfaces the sheet again).
   - **Forget.** Click Forget. Confirm `host.mismatch.forgotten` (warning) and that the `KnownHost` row is deleted (next reconnect TOFUs fresh and emits `host.pinned`).
   - **90-second decision timeout.** Open the sheet and walk away without clicking. After 90 seconds, confirm `host.mismatch.rejected reason="decision_timeout"` lands and the sheet self-dismisses.
   - **Cancellation.** Open the sheet and close the parent window via Cmd-W. Confirm `host.mismatch.rejected reason="cancelled"` lands *immediately* (not at the 90-second mark) and the sheet clears.
6. Restore the original sshd host keys: `sudo cp /tmp/ssh-keys-backup/ssh_host_* /etc/ssh/ && sudo /usr/sbin/launchctl kickstart -k system/com.openssh.sshd`. Reconnect from Pulse and either Accept or Forget to clear the now-stale pin.

If every action lands the expected events at the expected level with the expected token names, the mismatch flow is intact. Any deviation — especially `host.mismatch.accepted` landing *after* a `.commit_failed` event, or `cancelled` taking the full 90 seconds — is a regression to investigate before shipping.

## Session recording

Each credential carries a `recordSessions: Bool` toggle, off by default. Operators flip it from Settings → SSH (right-click a credential row → "Record sessions"). When on, every SSH session driven by that credential writes an encrypted log to disk under `<Application Support>/Pulse/Sessions/dev-<Device.id>/<timestamp>_<sessionUUID>.{pulselog,meta}` (or `Pulse/Sessions/unassigned/` for ad-hoc connections that aren't tied to a NetBox device). The toggle is suggested-on at credential creation time for break-glass and production-change credentials; the default-off posture matches ADR §6's opt-in stance.

The `.pulselog` is JSONL with one base64-encoded `AES.GCM.SealedBox.combined` per line. The session's symmetric key (256-bit) is wrapped to a device-resident Secure-Enclave ECDH-P256 key (the "log wrapping key", one per device) via `ECDH + HKDF<SHA256> + AES.GCM`, end-to-end CryptoKit-native. Every record carries a `prev` field with the SHA-256 of the previous record's ciphertext bytes — a hash chain that detects insertion, deletion, reordering, and single-byte tampering at replay time.

The `.meta` sidecar is unencrypted searchable metadata: device ID, credential ID, username, host, port, opened/closed timestamps, exit cause, record count, and the chain-head hash. Readable without biometric; lets a future browser list and search recordings without prompting per row. Decrypting a `.pulselog` requires biometric on this device's wrapping key — the unwrap happens through `SecureEnclave.P256.KeyAgreement.PrivateKey.sharedSecretFromKeyAgreement`, which fires Touch ID / device passcode the same way SSH signing does.

**File-protection posture, honestly.** On iOS, the recording directory carries `FileProtectionType.complete` as defence-in-depth. On macOS there is no per-file protection class equivalent — `FileProtectionType` symbols compile but only `.none` carries real semantics outside the iOS family, so the macOS at-rest answer is FileVault (whole-volume) and we don't manufacture macOS-side ceremony that wouldn't add real protection. The actual confidentiality guarantee on both platforms is the SE-wrapped per-session key: `.pulselog` ciphertext is unreadable without biometric on the device that recorded it, FileVault or no FileVault. This iOS-vs-macOS asymmetry is documented openly rather than papered over.

**Retention** is configurable per tenant; the default is one year. A retention pass runs at every app launch on a detached background task — never on the critical path for first paint. Failures emit `session.recording.purgeFailed` under category `ssh.recording` and the app continues; the next launch retries.

**Recordings do not migrate.** This is the operator-facing implication of "the wrapping key is device-bound":

- The wrapping-key keychain item is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and `kSecAttrSynchronizable: false`. It cannot leave the Secure Enclave, cannot be exported, cannot follow you to a new Mac.
- `.pulselog` and `.meta` files do appear in Time Machine and Migration Assistant backups (they're regular files under Application Support). The wrapping key does not. So on a new Mac after a restore, the files are present but unreadable — biometric will fire, the SE will refuse the ECDH, and replay will surface as "session key unwrap failed". This is by design and inherits the same trust-boundary posture as SSH credentials themselves.
- The "Forget this credential" gesture and "Delete this device's recordings" gesture (future Slice) both make the recordings recoverable only via an off-device archive that was made before deletion. There is no key-recovery path.

Operators who need long-term audit archives outside the device should use the future biometric-gated export flow (deferred from the recording stack as it ships today) to materialise a decrypted bundle for placement in their existing archive system. The off-device chain-head attestation surface, signed chain heads forwarded to FreeIPA or an internal log service, is scheduled for v2 per ADR §6.

**Mid-session failures are visible.** A `.pulselog` is either complete-and-chain-validated end to end, or it ended early and `.meta.exit_cause` says `recording_failed_midstream`. There are no "valid chain with holes" recordings and no sentinel gap records — the writer transitions to a terminal stop on the first structural failure (encryption error, disk full, internal queue overflow) and emits `session.recording.failed` under category `ssh.recording`. The SSH session itself continues unaffected; the byte pump never blocks on recording.

**Audit events** under the `pulse` subsystem, category `ssh.recording` (plus `ssh.credentials` for the toggle):

- `credential.recording.enabled`, `credential.recording.disabled` — operator gestures.
- `session.recording.opened`, `session.recording.closed` — recording lifecycle; `closed` carries record count, chain-head hash, and duration.
- `session.recording.failed` — terminal-stop with `reason` field (`seal_failure`, `write_failure`, `encode_failure`, `back_pressure_overflow`).
- `session.recording.replayUnwrapped` — biometric succeeded; the operator now has access to the recorded plaintext. Fires regardless of subsequent chain state.
- `session.recording.replayChainBroken` — chain validation failed during replay. Distinct event so SIEM rules can fire cleanly on tamper-after-access.
- `session.recording.purged`, `session.recording.purgeFailed` — launch-time retention outcomes.

Filter the full set with `log show --predicate 'subsystem == "pulse" AND category BEGINSWITH "ssh"'`. Session bytes and key material are never carried in audit signal — only identifiers and outcomes.

**Lab procedure.** An end-to-end round-trip to verify the recording stack on a fresh build. Done on an Apple Silicon Mac with Touch ID enabled, Remote Login enabled, and a credential targeting the loopback dev Mac.

1. In Settings → SSH, right-click a credential and toggle **Record sessions** on. Confirm `credential.recording.enabled` lands in `log show --predicate 'subsystem == "pulse" AND category == "ssh.credentials"' --last 1m`.
2. Open the terminal against the dev Mac via the device row context menu. Expect two biometric prompts back-to-back per the "Connecting to a device" section — the first signs the SSH user-auth handshake, the second unwraps the recording wrapping key.
3. With the terminal connected, confirm the recording badge (red `record.circle.fill` SF Symbol + "Recording" caption) appears in the window toolbar.
4. Run a short interactive session that exercises the readline path: `ls`, `echo "lab-marker-$(date +%s)"`, type a sentence and use Backspace plus arrow keys to edit it before pressing Return.
5. Close the terminal window. Confirm `session.recording.closed` lands with `recordCount`, `chainHeadHash`, and `durationMs`. Confirm the badge clears (visible via the toolbar pill's Disconnected state).
6. Inspect the file output:
   ```
   ls -la ~/Library/Application\ Support/Pulse/Sessions/dev-<device-id>/
   ```
   Confirm exactly one `.pulselog` plus one `.meta` per session, naming `<timestamp>_<sessionUUID>.{pulselog,meta}`. The `.meta` is JSON; open it and confirm `chain_head_hash`, `record_count`, `device_id`, `credential_id`, `opened_at`, `closed_at`, and `exit_cause` populate.
7. Replay via the Debug menu's **Replay session…** action. Pick the just-finished `.meta`. Confirm:
   - Touch ID / device passcode prompt fires before the first plaintext renders.
   - `session.recording.replayUnwrapped` lands in `log show ... --category == "ssh.recording"`.
   - The `lab-marker-…` line is visible in the replay output, in the same position it appeared during the live session.
8. Tamper with the chain mid-file (test environment only):
   ```
   printf 'X' | dd of=~/Library/Application\ Support/Pulse/Sessions/dev-<id>/<timestamp>_<uuid>.pulselog bs=1 count=1 seek=200 conv=notrunc
   ```
   Replay the same `.meta` again. Confirm `session.recording.replayChainBroken brokenAtSeq=<N>` lands and that plaintext stops at sequence `<N>` rather than continuing past the break.
9. (Cleanup) Toggle **Record sessions** off on the credential when finished. Confirm `credential.recording.disabled`.

If every step matches expectations, the recording stack is intact end to end. Any deviation — particularly step 7's plaintext mismatch, or step 8 surfacing plaintext past the tamper point — is a regression to investigate before shipping.

## No iCloud sync

Nothing in Pulse's SSH credential model is syncable. Both tiers are `ThisDeviceOnly`. The `kSecAttrSynchronizable` flag is explicitly set to `false` on Secure Enclave keys (defence-in-depth — the default for the data-protection keychain is already non-syncing, but Pulse sets it explicitly so a future code change can't quietly opt in). Legacy keys use `AfterFirstUnlockThisDeviceOnly`, which is also non-syncing.

Operators with multiple Macs maintain separate credential sets per machine. The Inspect feature on either machine should show the same access group string (because it's derived from team + bundle, which are identical across machines), but the credentials themselves are independent. Audit logs from each machine show distinct fingerprints.

## Memory residency of secret material

Imported PEM bodies and passphrases are held as `Data`-backed `@State` buffers in the legacy-import sheet. On dismissal (Cancel, successful commit, or window close) `Data.resetBytes(in:)` zeroes the persistent buffers; no Pulse-owned plaintext residue remains after the sheet goes away. The `Configuration` setters accept `Data` directly and write `kSecValueData` to the Keychain without round-tripping through an intermediate `String`.

This is bounded but not absolute. Two residual exposures remain, called out honestly rather than papered over:

- **The SwiftUI text-input layer.** `TextEditor` and `SecureField` bind to `String`. Each keystroke materialises an ephemeral `String` via the `Binding<String>` adapter; the underlying AppKit/UIKit text-input maintains its own buffer Pulse cannot reach. Those instances are dropped to the runtime allocator without being zeroed.
- **The SSH auth-signing path.** When `SSHAuthDelegate` loads a portable PEM for signing, the bytes pass through a transient `String` to satisfy CryptoKit's `pemRepresentation` initialisers. The window is bounded by the SSH handshake duration (milliseconds) rather than by sheet lifetime, but the `String` is unzeroable. The conversion happens at the CryptoKit API boundary and cannot be avoided without writing our own PEM parser, which would be a worse trade than the residual exposure.

The improvement is real: the persistent post-dismissal plaintext residue is gone. The improvement is not absolute: an attacker with code execution inside the Pulse process at the wrong moment can still observe secret material in the transient cases above. An attacker who has reached that level can observe much more besides.

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

- RSA portable signing is not supported in v1. The implementation plan originally specified modulus enforcement at the importer (NZISM 17.1.40); implementation surfaced that `swift-nio-ssh` 0.13.0 carries no RSA private-key signing path, so v1 rejects RSA at the importer's front door with operator-facing remediation guidance. The modulus-enforcement code shipped briefly as defensive scaffolding and was deleted before the SSH foundations PR closed; the front-door reject is the single source of truth for the policy. Operators with RSA keys regenerate as ECDSA P-256/384/521 or Ed25519.
- SSH authentication-event audit logging is complete in v1. Credential lifecycle under `ssh.credentials`, host-key decisions under `ssh.session`, auth outcomes under `ssh.auth`, certificate presentation outcomes under `ssh.certificates`, session lifecycle under `ssh.session`. Filter the full set with `log show --predicate 'subsystem == "pulse" AND category BEGINSWITH "ssh"'`.
- Centralised audit collection (NZISM 18.1) is a deployment concern. `os_log` events under the `pulse` subsystem can be forwarded to a SIEM via standard macOS logging pipelines.

## Related

- [ADR 0001 — SSH terminal & in-app web foundations](architecture/0001-ssh-terminal-and-web-foundations.md) — the underlying decisions.
- [CLAUDE.md](../CLAUDE.md) — repository conventions.
