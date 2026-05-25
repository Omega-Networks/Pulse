# ADR 0001 — SSH Terminal & In-App Web: Architectural Foundations

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-05-23 |
| **Decision owner** | Leon Cassidy |
| **Applies to** | `Pulse/SSH/**`, `Pulse/Web/**`, `Pulse/Networking/**`, `Pulse/Views/Terminal/**`, `Pulse/Views/Web/**`, `Pulse/Models/SwiftData Models/SSHCredential.swift`, `Pulse/Models/SwiftData Models/KnownHost.swift` |

## Principle

**Governance is code.** The foundations in this document are structural. They live in the data model, the type system, and the API surface — not in operator memory, not in a runbook, not in convention. The insecure path is unavailable, not merely discouraged.

Operators will use Pulse to interact with critical infrastructure. The defaults must be safe; the unsafe options must require explicit, labelled gestures; and the audit trail must be the byproduct of using the system normally, not a feature to enable.

## Context

Pulse currently surfaces device inventory from NetBox and exposes `Device.primaryIP`. Operators leave the app to reach those devices over SSH and HTTP. Bringing both flows in-app lets us:

1. Eliminate the context switch and the SecureCRT / Terminal.app / browser sprawl.
2. Route device traffic through code we control — the seam for the in-app tunnel.
3. Make Zero Trust the default, not an aspiration. Every device interaction goes through credentials we manage, host trust we attest, and audit logs we own.

This ADR captures the non-negotiables. The implementation plan is layered on top.

## Non-negotiables

### 1. Credentials are device-bound by default

| Tier | Storage | Exportable | Algorithm (v1) | UI label |
|---|---|---|---|---|
| **Primary** | Secure Enclave, biometric-gated | No | ECDSA P-256 | (none — default) |
| **Legacy** | Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | Yes | ECDSA P-256/384/521, Ed25519 — unencrypted only | "Legacy (portable key)" |

> **v1 portable scope amendment (Slice 3 commit 7b₁).** The original table read "Ed25519 / ECDSA / RSA" for the Legacy tier. Two findings during Slice 3 implementation narrow this for v1:
>
> - **RSA portable signing is deferred.** `swift-nio-ssh` 0.13.0 (the pinned version) and the `main` branch carry no RSA private-key path in `NIOSSHPrivateKey`; the only init methods accept Ed25519, P-256, P-384, P-521, and Secure-Enclave-P-256 keys. Forking the dependency to add an RSA case carries merge-debt for a security-critical library and is explicitly out of scope. RSA imports are rejected at the front door with operator-facing remediation guidance; the modulus-enforcement work from Slice 3 commit 3 and the public-key derivation from commit 4 stay as defensive scaffolding for the day upstream lands RSA signing.
> - **Encrypted portable keys are deferred.** Decrypting `BEGIN ENCRYPTED PRIVATE KEY` PKCS#8 (PBKDF2 + AES) and OpenSSH new-format encrypted blobs (bcrypt-pbkdf + AES-CTR) requires implementing key-derivation functions in-house — the third-party crypto prohibition in §10 cuts both ways. Encrypted PEMs are rejected at import; operators re-export without a passphrase, then Pulse manages access through SE biometric or the at-rest data-protection-keychain class. Future slice may add encrypted-PEM support if a credible KDF source ships in Apple's SDKs.
>
> Both algorithms remain reserved in `SSHKeyImporter.Algorithm` and on the `SSHCredential` model so forward compatibility doesn't require a schema migration.

- New credentials default to Secure Enclave generation. The "Import PEM" path requires an explicit second screen and the resulting credential is tagged `legacy` in the data model.
- SE keys produce only a public-key export. `SecKeyCopyExternalRepresentation` on the private half must return `nil`; this is enforced by SE itself and verified in tests.
- Each device (each Mac, each iPad) that runs Pulse generates its own SE key with its own public key. Credentials do not sync. This is a feature.
- Biometric or device passcode is required *per signing operation* via `kSecAccessControlBiometryAny` (with `or devicePasscode` fallback). The policy is `.biometryAny` rather than `.biometryCurrentSet`: adding or removing a Touch ID fingerprint, or changing the passcode, does not invalidate existing credentials. The stricter posture would guard against an attacker who already possesses the device passcode enrolling their own biometric — a threat already gated by passcode possession, not worth the operational cost of credential churn on every routine Touch ID change. Every SSH session still begins with a human attestation.
- SE keys land in the default `$(AppIdentifierPrefix)$(CFBundleIdentifier)` access group. Both the Team ID and the bundle ID are part of the credential's reachability contract: changing either renders existing SE keys unreachable from the new build (they remain in the Enclave but no entitled app can find them via the Keychain). This is intentional. Forks, beta channels with a `.beta` suffix, or any re-signing under a different team require operators to re-enrol on first launch. See `docs/credentials.md`.

### 2. Passwords are not a v1 auth method

Password authentication is not implemented in v1. The `SSHAuthMethod` enum exposes only key-based variants:

```swift
enum SSHAuthMethod {
    case secureEnclaveKey(keyRef: SecKey)
    case secureEnclaveKeyWithCertificate(SecKey, NIOSSHCertifiedPublicKey)
    case portablePrivateKey(keychainID: UUID)                 // legacy
    case portableKeyWithCertificate(UUID, NIOSSHCertifiedPublicKey)
}
```

If a future "legacy break-glass password" path is added, it lives in a separate enum case explicitly labelled in the UI and emits an `os_log` warning at every use. It is never the default and never silent.

### 3. SSH certificates are first-class from v1

The data model carries optional certificates alongside every credential. `swift-nio-ssh`'s `NIOSSHCertifiedPublicKey` is wired in from day one. The UI surfaces certificate expiry, principals, and CA fingerprint. Re-enrolment is a single action.

The intended deployment is FreeIPA-issued user certificates over SE-generated public keys, but the design is identity-provider-agnostic — Microsoft, HashiCorp Vault, smallstep, or any other SSH CA works the same way.

### 4. Username belongs on the connection, not the credential

`SSHCredential` does not carry a username. The same key can authenticate `root`, `admin`, vendor-default, or operator accounts on different devices. Username lives on:

- `Device.defaultUsername: String?` — preferred username for this device.
- `SSHConnectSheet` per-session override field.

This matches how SSH actually works and stops operators from cloning credentials just to vary the user.

### 5. Host trust is polymorphic from day one

```swift
enum HostTrust {
    case pinned(fingerprintSHA256: String, algorithm: String)
    case trustedCA(caFingerprintSHA256: String, principalPattern: String)
    case explicitlyDistrusted(reason: String, recordedAt: Date)
}
```

TOFU (Trust On First Use) is the *fallback*, not the model. The `pinned` case ships in v1; `trustedCA` ships with FreeIPA enrolment in v2. The enum case is reserved now so the schema does not need a breaking migration.

A per-site / per-tenant policy `requireCertificateVerification: Bool` is supported in v1 (default `false`). When `true`, non-cert-attested connections are refused without an explicit override that is logged.

The UI distinguishes the trust modes at a glance: CA-attested (green), pinned (amber), unverified (red). No exceptions to this visual contract.

### 6. Session recording: opt-in, encrypted, tamper-evident

Per-credential `recordSessions: Bool` toggle. Off by default. On for credentials used for break-glass / production-change work.

When on:

- Raw byte streams in both directions are recorded.
- Each session writes to two files under `~/Library/Application Support/Pulse/Sessions/<deviceUUID>/<timestamp>_<sessionUUID>.{pulselog,meta}`.
- `.pulselog` is JSONL. Each record is encrypted with `AES.GCM` (CryptoKit) using a per-session 256-bit symmetric key. Records carry a `prev` field holding the SHA-256 of the previous record's ciphertext — a hash chain that detects insertion, deletion, or reordering.
- The session key is wrapped to a Secure Enclave-backed P-256 key (the "log wrapping key") via `SecKeyCreateEncryptedData` with `eciesEncryptionStandardX963SHA256AESGCM`. The wrapped key lives in the file header. Unwrapping requires biometric.
- File protection is `NSFileProtectionComplete` (iOS) / equivalent on macOS with FileVault.
- `.meta` sidecar holds searchable, unencrypted metadata: deviceID, credentialID, username, host, opened/closed timestamps, duration, exit cause, chain-head hash. Lets the session browser list and search without prompting biometric on every refresh.
- Retention is configurable per-tenant. Default 1 year. Auto-purge runs at launch.
- **No plaintext log is ever written to disk.** This is enforced by routing all session-byte writes through a single `SessionLogWriter` whose only output method takes a ciphertext record.

### 7. Audit metadata is always on

Independent of the recording toggle, every session emits structured `os_log` events under the project's `pulse` subsystem with categories beginning `ssh` (e.g. `ssh.secureenclave`, `ssh.credentials`, `ssh.session`):

- `session.open`, `session.close`
- `auth.success`, `auth.failure`
- `host.pinned`, `host.mismatch`, `host.ca-accepted`, `host.ca-rejected`
- `cert.offered`, `cert.accepted`, `cert.rejected`, `cert.expired` — `cert.offered` emits when the auth delegate decides to present a stored certificate; `cert.accepted` confirms the server accepted it after session-open. Two separate events because the audit log needs to distinguish delegate-side intent from server-side outcome.
- `credential.created`, `credential.deleted`, `credential.rotated`

Metadata fields: `deviceID`, `credentialID`, `username`, `host`, `port`, `openedAt`, `closedAt`, `exitCause`. Session contents and key material are never included. This signal is captured by `log show` and falls into sysdiagnose by default — it is recoverable even when the device is examined offline.

### 8. Transport abstraction is the single tunnel seam

```swift
protocol PulseTransport {
    func connect(to host: String, port: Int, on eventLoop: EventLoop) -> EventLoopFuture<Channel>
}
```

- v1 default: `DirectTransport` using `NIOTSConnectionBootstrap`.
- Future tunnel: `TunnelTransport` returning a `Channel` whose I/O is forwarded through the in-app tunnel.
- SSH and Web both consume `PulseTransport`. The Web side does so via `WebPage.Configuration.urlSchemeHandlers["pulse-tunnel"]` registered to a handler that resolves requests through `PulseTransport`.
- Every `PulseTransport` implementation sets a finite connect timeout. The v1 default in `DirectTransport` is 10 seconds. Future implementations may surface a config knob but must never default to an unbounded wait; hanging operator UI is a failure mode the seam exists to prevent. `NIOTSConnectionBootstrap`'s default behaviour is an infinite wait, so the timeout is set explicitly via `.connectTimeout(...)`.
- Transports must support dual-stack addresses (IPv4 and IPv6). `NIOTSConnectionBootstrap` satisfies this via Happy Eyeballs through Network.framework. Loopback verification covers both stacks (`127.0.0.1` and `::1`) so an IPv6 regression trips a test rather than surfacing in the field.
- The protocol stays small. If it grows beyond `connect`, the abstraction has failed and should be reviewed.

### 9. UI surface — two windows, one Settings pane

- `WindowGroup("SSH Terminal", for: Device.ID.self)` and `WindowGroup("Device Web", for: Device.ID.self)`, mirroring the existing `WindowGroup("Site View", for: Site.ID.self)` in `PulseApp.swift:159`.
- Entry points: `DeviceRow.contextMenu` and `DeviceView` popover, disabled when `device.primaryIP == nil`.
- Settings → SSH:
  - **Credentials** — CRUD, SE-backed generation (default), PEM import (legacy, second screen).
  - **Host Trust** — browse, forget, import CA bundle, set per-site enforcement policy.
  - **Session History** — `.meta` list, biometric-gated playback through a non-interactive `SwiftTerm.TerminalView` re-using the same renderer.
  - **Identity Provider** — FreeIPA enrolment (v2).

### 10. Dependencies

| Package | Source | Justification |
|---|---|---|
| `swift-nio-ssh` | apple/swift-nio-ssh | Apple-maintained, pure Swift, supports iOS/macOS/Linux. |
| `swift-nio-transport-services` | apple/swift-nio-transport-services | Network framework integration — Happy Eyeballs, interface transitions, TLS. |
| `SwiftTerm` | migueldeicaza/SwiftTerm | Only viable terminal emulator on Apple platforms. Vendored at a pinned tag; version bumps require explicit review. Source-bounded fork strategy in case of upstream abandonment. |
| WebKit for SwiftUI | system | `WebView` / `WebPage`, iOS 26 / macOS 26. |
| CryptoKit, Security | system | All cryptographic operations. No third-party crypto. |

There are no other in-process terminal emulator options on Apple platforms. The SwiftTerm maintainer risk is accepted with the vendoring mitigation above.

## What ships when

### v1 (this feature)
- Secure Enclave key generation + signing (ECDSA P-256).
- PEM import for legacy credentials, unencrypted only: ECDSA P-256/384/521 (traditional, PKCS#8, OpenSSH new-format) and Ed25519 (OpenSSH new-format).
- SSH certificate authentication (`NIOSSHCertifiedPublicKey`).
- Polymorphic `HostTrust` (pinned case implemented; `trustedCA` schema reserved).
- Audit metadata via `os_log`.
- Encrypted session recording behind per-credential toggle.
- Session browser with biometric-gated playback.
- SSH terminal window + Web companion window.
- `PulseTransport` seam with `DirectTransport` implementation.

### v2
- FreeIPA enrolment UI and trusted-CA import.
- Off-device log attestation (signed chain heads shipped to FreeIPA / internal log service).
- iOS SwiftUI surface (the underlying Swift already compiles for iOS).

### Future portable-tier additions (deferred from v1)
- Encrypted PEM import (PBKDF2 + AES for PKCS#8, bcrypt-pbkdf + AES-CTR for OpenSSH new-format) — requires KDF implementations that don't fit the §10 third-party-crypto prohibition without an Apple-shipped source.
- RSA portable signing — pending upstream `swift-nio-ssh` RSA private-key support.

### Out of scope
- SFTP, agent forwarding, port forwarding, jump hosts.
- Multi-tab terminal in a single window — open multiple windows.
- Migrating NetBox / Zabbix `URLSession` calls onto SwiftNIO HTTP.
- The tunnel implementation itself — `PulseTransport` + `DeviceURLSchemeHandler` are the seams left behind.
- Password authentication.

## Structural enforcement

These rules are enforced by code, not convention:

1. **No `SSHAuthMethod.password` case exists in v1.** Compilation fails if anyone tries to construct one.
2. **`SessionLogWriter.write(record:)` accepts only `EncryptedRecord`.** Plaintext bytes have no path to disk.
3. **`SSHCredential` has no `username` property.** Reviewers cannot accidentally re-introduce the per-credential username binding.
4. **`HostTrust` is polymorphic from day one.** Adding `trustedCA` enforcement later does not require a schema migration that could be skipped or fail silently.
5. **`PulseTransport` is the single dependency for outbound bytes in SSH and Web code.** Direct use of `NIOTSConnectionBootstrap` or `URLSession` for device traffic is grep-checkable and reviewed.

## Verification

| # | Test | Pass criterion |
|---|---|---|
| 1 | Build | `xcodebuild -project Pulse.xcodeproj -scheme Pulse -configuration Debug build` succeeds for macOS and iOS destinations. |
| 2 | SE credential non-exportability | `SecKeyCopyExternalRepresentation` on the SE private key returns `nil`. Public key exports as a valid `ecdsa-sha2-nistp256` `authorized_keys` line. |
| 3 | Biometric gating | Each SSH connection triggers a biometric / passcode prompt before the first signing operation. |
| 4 | Loopback SSH | Enable Remote Login on the dev Mac, point a test `Device.primaryIP` at `127.0.0.1`, connect with an SE credential. Full interactive shell — colour, `top`, `vim`, `Ctrl+C`, resize updates `tput cols`/`tput lines`. |
| 5 | Host-key TOFU | First connection records a `HostTrust.pinned` entry. Second connection with a different key shows the mismatch sheet; acceptance updates the entry. |
| 6 | Cert acceptance | sshd configured with `HostCertificate` signed by a test CA. Pulse accepts when CA is in `HostTrust.trustedCA`; rejects when not, with `cert.rejected` event in `os_log`. |
| 7 | Encrypted log integrity | Recorded session file is non-zero; opens to AES-GCM authenticated ciphertext; decrypts only via biometric; hash chain validates; flipping one byte in any record causes validation to fail cleanly with no plaintext exposure. |
| 8 | Audit signal | `log show --predicate 'subsystem == "pulse" AND category BEGINSWITH "ssh"' --last 1h` shows lifecycle events for every session of the test run. |
| 9 | Web companion | Device with a local HTTP UI renders in `WebView`; toolbar binds to `page.title` / `page.estimatedProgress`. `pulse-tunnel://` URL invokes the scheme handler. Navigation decider blocks unrelated origins. |
| 10 | Lifecycle | Closing each window deinits `SSHClient` / `WebPage`; `os_log` deinit messages observed. No retain cycles in Instruments. |

## Alternatives considered

- **Shell out to Terminal.app via `NSWorkspace` or `osascript`.** Rejected: bypasses `PulseTransport`, loses the tunnel seam, no audit signal, no session recording.
- **Spawn `ssh(1)` as `NSTask` with a pty.** Rejected: same transport problem, plus would require us to write a terminal emulator to render the bytes — at which point SwiftTerm is the better answer.
- **`WKWebView` + `xterm.js`.** Rejected: replaces a Swift dependency with a heavier JS one, adds a bridge, harder to audit, no benefit.
- **Write our own xterm emulator.** Rejected for v1. Genuinely consistent with 30-year thinking but a 6-month detour from this feature. Re-evaluate if SwiftTerm becomes untenable.
- **Password authentication in v1.** Rejected per direction: all device validation uses keys; password is a separate concern to design carefully if ever needed.
- **Ed25519 in the Secure Enclave.** Not possible — the Secure Enclave only supports ECDSA P-256. Ed25519 stays available in the legacy portable-key tier.

## Operational consequences to document in the runbook

- SE-backed credentials do not survive device loss, factory reset, or moving to a new Mac/iPad. Each device enrols its own public key. This is consistent with Pulse's local-first stance (per `CLAUDE.md`).
- Biometric-gated session log keys mean historical logs become unrecoverable if the SE wrapping key is lost. Operators who need long-term archives must use the biometric-gated export flow and place the decrypted bundle in their existing archive.
- TOFU acceptance is recorded permanently until forgotten. The runbook must teach the "Forget this host" gesture and when to use it (legitimate key rotation events).
- "Record sessions" is opt-in per credential. Production-change credentials should have it on. The runbook must say so and the credential editor should suggest it during creation.
- SE credentials are bound to this signed build of Pulse. Changing the bundle identifier or signing team between releases requires operators to re-enrol every device. This is by design: credentials should not silently follow an operator across trust boundaries. The credentials guide (`docs/credentials.md`) explains the consequence for forks and beta channels.

## Review

This document is the contract. Changes require a new ADR or an amendment with explicit rationale. Implementation PRs touching SSH, Web, transport, credentials, or session logging must reference this ADR in their description.
