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
> - **RSA portable signing is deferred.** `swift-nio-ssh` 0.13.0 (the pinned version) and the `main` branch carry no RSA private-key path in `NIOSSHPrivateKey`; the only init methods accept Ed25519, P-256, P-384, P-521, and Secure-Enclave-P-256 keys. Forking the dependency to add an RSA case carries merge-debt for a security-critical library and is explicitly out of scope. RSA imports are rejected at the front door (`SSHKeyImporter.ImporterError.unsupportedAlgorithmInV1`) with operator-facing remediation guidance. Modulus-enforcement and derivation work shipped briefly as defensive scaffolding (commits 3 and 4 of Slice 3) and was removed at the slice's close (commit `7f545d2`); both code paths are recoverable from `git show 4238b35` and `git show 023bd07` if upstream NIOSSH ever ships RSA signing.
> - **Encrypted portable keys are deferred.** Decrypting `BEGIN ENCRYPTED PRIVATE KEY` PKCS#8 (PBKDF2 + AES) and OpenSSH new-format encrypted blobs (bcrypt-pbkdf + AES-CTR) requires implementing key-derivation functions in-house — the third-party crypto prohibition in §10 cuts both ways. Encrypted PEMs are rejected at import; operators re-export without a passphrase, then Pulse manages access through SE biometric or the at-rest data-protection-keychain class. Future slice may add encrypted-PEM support if a credible KDF source ships in Apple's SDKs.
>
> Both algorithms remain reserved in `SSHKeyImporter.Algorithm` and on the `SSHCredential` model so forward compatibility doesn't require a schema migration.

- New credentials default to Secure Enclave generation. The "Import PEM" path requires an explicit second screen and the resulting credential is tagged `legacy` in the data model.
- SE keys produce only a public-key export. CryptoKit's `SecureEnclave.P256.Signing.PrivateKey` exposes no API to extract the raw private key — the non-exportability guarantee is compile-time, not runtime. Tests verify the positive contract: `dataRepresentation` round-trips through `init(dataRepresentation:)` preserving the public key while the underlying private material stays inside the SE.
- Each device (each Mac, each iPad) that runs Pulse generates its own SE key with its own public key. Credentials do not sync. This is a feature.
- Biometric or device passcode is required *per signing operation* via `kSecAccessControlBiometryAny` (with `or devicePasscode` fallback). The policy is `.biometryAny` rather than `.biometryCurrentSet`: adding or removing a Touch ID fingerprint, or changing the passcode, does not invalidate existing credentials. The stricter posture would guard against an attacker who already possesses the device passcode enrolling their own biometric — a threat already gated by passcode possession, not worth the operational cost of credential churn on every routine Touch ID change. Every SSH session still begins with a human attestation.
- **SE key storage and reachability contract (updated Slice 3 commit 7a).** SE-resident keys are accessed through CryptoKit's `SecureEnclave.P256.Signing.PrivateKey`. The opaque `dataRepresentation` reference is persisted as a `kSecClassGenericPassword` Keychain item under service `<Bundle.main.bundleIdentifier>.ssh` (for the Omega distribution build: `nz.net.omega.pulse.ssh`) and account `<credentialUUID>`. Deriving the service string from the bundle ID at runtime rather than hardcoding a constant makes the bundle reachability contract structural: a fork or re-sign under a different `BUNDLE_IDENTIFIER` lands the new build's credentials in a disjoint keychain namespace automatically. Both the Team ID and the bundle ID remain part of the reachability contract: changing either renders existing SE keys unreachable from the new build. Forks, beta channels with a `.beta` suffix, or any re-signing under a different team require operators to re-enrol on first launch. See `docs/credentials.md`.

### 2. Passwords are not a v1 auth method

Password authentication is not implemented in v1. The credential model and the auth delegate expose only key-based paths — there is no `password` field on `SSHCredential`, no password case on `SSHCredentialTier`, no fallback in `SSHAuthDelegate`. The structural enforcement is the absence of every related field, not an enum case marked "do not use":

```swift
enum SSHCredentialTier {
    case secureEnclave  // ECDSA P-256 in the Enclave via CryptoKit's SecureEnclave.P256.Signing.PrivateKey
    case portable       // ECDSA P-256/384/521 or Ed25519, unencrypted PEM in the Keychain
}

@Model
final class SSHCredential {
    var tier: SSHCredentialTier
    var publicKey: Data           // OpenSSH wire-format
    var certificate: Data?        // optional CA-signed cert, textual OpenSSH form
    // no `password` field, no `passwordFallback` enum case, no auth-method enum
}
```

If a future "legacy break-glass password" path is ever added, it lives in a separate enum case explicitly labelled in the UI and emits an `os_log` warning at every use. It is never the default and never silent.

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
- Each session writes two files under `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)` with subpath `Pulse/Sessions/dev-<Device.id>/<timestamp>_<sessionUUID>.{pulselog,meta}`. Resolution is platform-correct without a literal tilde: macOS non-sandboxed `~/Library/Application Support/Pulse/Sessions/...`; macOS sandboxed `~/Library/Containers/<bundle-id>/Data/Library/Application Support/Pulse/Sessions/...`; iOS `<container>/Library/Application Support/Pulse/Sessions/...`. `Device.id` is the SwiftData `@Attribute(.unique)` `Int64` already in use across the model layer (the NetBox primary key); no fresh UUID is minted. When `deviceID` is unavailable (ad-hoc connections from debug surfaces, devices without a NetBox row), the path becomes `Pulse/Sessions/unassigned/<timestamp>_<sessionUUID>.{pulselog,meta}`. `SSHClient.connect(...)` accepts a required `deviceID: Int64?` parameter (no default); ad-hoc call sites pass `nil` deliberately and visibly.
- `.pulselog` is JSONL. Each record is encrypted with `AES.GCM` (CryptoKit) using a per-session 256-bit symmetric key. Records carry a `prev` field holding the SHA-256 of the previous record's `AES.GCM.SealedBox.combined` (nonce || ciphertext || tag) — a hash chain that detects insertion, deletion, or reordering. The chain hash is always computed from the raw on-disk bytes, never from a re-encoded `Codable` envelope; the pure-function surface in `SessionLogRecord.swift` exposes `chainHash(of combined: Data) -> String` operating on raw bytes, and no `SessionLogRecord`-typed re-encode helper exists (a Foundation patch that changes `JSONEncoder` key ordering, escaping, or number formatting would otherwise silently invalidate every historical log).
- The session key is wrapped via ECDH on a Secure-Enclave-resident `SecureEnclave.P256.KeyAgreement.PrivateKey` (the "log wrapping key") against an ephemeral `P256.KeyAgreement.PrivateKey` generated per session, feeding `sharedSecretFromKeyAgreement(with:)` into `HKDF<SHA256>.deriveKey(...)` to produce a 256-bit AES key, then `AES.GCM.seal(...)` over the 32-byte session-key material. The wrapped blob in the file header is the ephemeral public key (`x963Representation`, 65 bytes) concatenated with the `AES.GCM.SealedBox.combined`. Unwrapping reads the header, runs the same ECDH against the SE key (biometric prompt fires here), derives the same KEK, and opens the sealed box. CryptoKit-native end to end; no `Security.framework` cryptographic primitives. The wrapping key is one per device (not per credential, not per session), stored at service `<Bundle.main.bundleIdentifier>.ssh.logwrap`, mirroring the SSH-credential storage shape from Slice 3 commit 7a.
- File protection: iOS sets `FileProtectionType.complete` on the session-log directory as defence-in-depth. macOS has no per-file protection class equivalent — the `FileProtectionType` symbols compile on macOS but only `.none` carries real semantics outside the iOS family. macOS at-rest protection is FileVault (whole-volume). The actual confidentiality guarantee on both platforms is the SE-wrapped per-session symmetric key: `.pulselog` ciphertext is unreadable without biometric on the device that recorded it, FileVault or no FileVault. This iOS-vs-macOS asymmetry is documented openly rather than papered over with manufactured macOS-side ceremony that doesn't add real protection.
- `.meta` sidecar holds searchable, unencrypted metadata: `device_id: Int64?` (nil for unassigned), `credential_id: UUID`, username, host, port, opened/closed timestamps, duration, exit cause (from the seven-case `ExitCause` enum), record count, chain-head hash (hex SHA-256 of the final record's `SealedBox.combined`), and a relative `pulselog_path`. Lets the session browser list and search without prompting biometric on every refresh.
- Retention is configurable per-tenant. Default 1 year. Auto-purge runs at launch via `SessionLogRetention.purgeAtLaunch(maxAge:)`.
- **Mid-session recording-failure semantics: terminal stop, no gap records.** A `.pulselog` is either complete-and-chain-validated end to end, or it ended early and `.meta` carries the truth. On the first failure inside the writer (encryption failure, seal-then-write fault, queue overflow per the back-pressure rule below), the writer transitions to a terminal `.recordingStopped` state, emits `session.recording.failed` with the specific reason exactly once, and finalises `.meta` with `exit_cause: "recording_failed_midstream"`. Subsequent records are silently dropped. The underlying SSH session keeps flowing bytes through the tap and on to the consumer (SwiftTerm, debug menu) uninterrupted — recording failure never propagates into the byte pump. There are no "valid chain with holes" and no sentinel gap records: chain-continues-with-discontinuous-seq creates a recording that replays seamlessly with no operator-visible indication that bytes are missing, which is the worst framing for a tamper-evident log.
- **Back-pressure bound.** The recording tap dispatches into the writer actor via fire-and-forget `Task { await writer.record(...) }`. The actor's internal pending-record queue is bounded at **1024 records or 4 MiB total pending plaintext bytes**, whichever is reached first. On overflow the writer emits `session.recording.failed` with `reason: "back_pressure_overflow"` and transitions to the same `.recordingStopped` terminal state. The EventLoop is never blocked and the session byte pump never observes the overflow.
- **No plaintext log is ever written to disk.** This is enforced by routing all session-byte writes through a single `SessionLogWriter` whose only output method takes a ciphertext record. The recording tap (`SSHSessionRecordingTap`, a `ChannelDuplexHandler`) lives in `SSHClient`'s channel pipeline before `SSHSessionDataBridge`; `SSHSession` stays consumer-agnostic (the structural gate `grep -n "SessionLogWriter\|RecordingTap" Pulse/SSH/SSHSession.swift` returns empty).

### 7. Audit metadata is always on

Independent of the recording toggle, every session emits structured `os_log` events under the project's `pulse` subsystem with categories beginning `ssh`. The current category set is `ssh.auth`, `ssh.certificates`, `ssh.credentials`, `ssh.recording` (Slice 4), `ssh.secureenclave`, `ssh.session` (which carries both session-lifecycle and host-key events), plus `ssh.debug` for the `#if DEBUG`-gated DebugSSHMenu surface. Operators filter with `log show --predicate 'subsystem == "pulse" AND category BEGINSWITH "ssh"'`. Events emitted:

- `session.open`, `session.close` — once each per attempt; `session.close` carries `durationMs` and an `exitCause` from the seven-case `ExitCause` enum.
- `auth.success`, `auth.failure` — `auth.failure` emits at most once per connection attempt. The first key-load or offer-exhaustion failure latches; subsequent retries from the NIOSSH user-auth loop return `nil` immediately without re-emitting. This keeps a single failed connection from flooding the audit log.
- `host.pinned`, `host.mismatch`, `host.ca-accepted`, `host.ca-rejected`
- `cert.offered`, `cert.accepted`, `cert.rejected`, `cert.expired` — `cert.offered` emits when the auth delegate decides to present a stored certificate; `cert.accepted` confirms the server accepted it after session-open. Two separate events because the audit log needs to distinguish delegate-side intent from server-side outcome.
- `credential.created`, `credential.deleted`, `credential.rotated`
- `credential.recording.enabled`, `credential.recording.disabled` — operator toggled the per-credential `recordSessions` flag.
- `session.recording.opened`, `session.recording.closed` — recording lifecycle, fires only when `credential.recordSessions == true`. `closed` carries `recordCount`, `chainHeadHash`, `durationMs`.
- `session.recording.failed` — recording stopped mid-session. `reason` is one of `wrap_failure`, `disk_full`, `encode_failure`, `back_pressure_overflow`. The session continues; the recording does not.
- `session.recording.replayUnwrapped` — operator-driven replay; biometric succeeded. Fires regardless of subsequent chain validation outcome because the fact of operator access to a recorded log is security-relevant independent of file integrity.
- `session.recording.replayChainBroken` — chain validation failed during replay. Distinct from `replayUnwrapped` so any future SIEM rule can fire cleanly on tamper-after-access. Carries `brokenAtSeq`.
- `session.recording.purged`, `session.recording.purgeFailed` — launch-time retention purge outcome.

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
- **EventLoopGroup ownership.** v1 transports use `NIOTSEventLoopGroup` exclusively because Pulse runs only on Apple platforms; NIOTransportServices is the right group type for any Network.framework consumer. `SSHClient` constructs the group inside `connect()`. A future `TunnelTransport` will use the same group type for the same reason — there is no abstraction over the group type because there is no second consumer to abstract for. If Pulse ever grows a non-Apple build target this assumption needs revisiting.
- **`Channel` Sendable boundary.** NIOCore's `Channel` is not `Sendable` under Swift 6 strict-concurrency rules but every channel method dispatches internally to its `EventLoop`. The pattern used across `SSHClient` and `SSHSession`: store the channel as `nonisolated(unsafe)` on the actor, route work through `EventLoopFuture` chains, return only `Sendable` snapshots (the session, byte slices, errors) across the actor boundary. `SSHSession`'s output and exit handlers live in an `NIOLockedValueBox` so the inbound EventLoop thread can deliver bytes synchronously without paying for an actor hop per chunk — the hot path tolerates the lock but not the cooperative-pool latency at terminal-responsiveness scales. Slice 4's `SessionLogWriter` and Slice 5's SwiftTerm consumer inherit this discipline.
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
| `swift-nio-ssh` | apple/swift-nio-ssh (pinned 0.13.0) | Apple-maintained, pure Swift, supports iOS/macOS/Linux. |
| `swift-nio-transport-services` | apple/swift-nio-transport-services | Network framework integration — Happy Eyeballs, interface transitions, TLS. |
| `swift-asn1` | apple/swift-asn1 (transitive via swift-nio-ssh) | ASN.1 decoding used inside swift-nio-ssh for certificate parsing. Apple-maintained. |
| `swift-crypto` | apple/swift-crypto (transitive via swift-nio-ssh) | Apple's cross-platform CryptoKit shim. On Apple platforms forwards to system CryptoKit; included transitively so swift-nio-ssh compiles on Linux. No Pulse code imports it directly. |
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
| 2 | SE credential non-exportability | `SecureEnclave.P256.Signing.PrivateKey` exposes no API for raw private-key extraction (compile-time guarantee, not a runtime check). `dataRepresentation` round-trips through `init(dataRepresentation:)` with the public key preserved, confirming the SE-encrypted blob is the only reference the Keychain ever holds. Public key exports as a valid `ecdsa-sha2-nistp256` `authorized_keys` line. |
| 3 | Biometric gating | Each SSH connection triggers a biometric / passcode prompt before the first signing operation. |
| 4 | Loopback SSH | Enable Remote Login on the dev Mac, point a test `Device.primaryIP` at `127.0.0.1`, connect with an SE credential. Full interactive shell — colour, `top`, `vim`, `Ctrl+C`, resize updates `tput cols`/`tput lines`. |
| 5 | Host-key TOFU | First connection records a `HostTrust.pinned` entry. Second connection with a different key shows the mismatch sheet; acceptance updates the entry. |
| 6 | Cert acceptance | sshd configured with `HostCertificate` signed by a test CA. Pulse accepts when CA is in `HostTrust.trustedCA`; rejects when not, with `cert.rejected` event in `os_log`. |
| 7 | Encrypted log integrity | Recorded session file is non-zero; opens to AES-GCM authenticated ciphertext; decrypts only via biometric; hash chain validates; flipping one byte in any record causes validation to fail cleanly with no plaintext exposure. |
| 8 | Audit signal | `log show --predicate 'subsystem == "pulse" AND category BEGINSWITH "ssh"' --last 1h` shows the full session lifecycle: `session.open`, `auth.success`, `cert.offered` and/or `cert.accepted` when a cert is presented, `host.pinned` or `host.mismatch`, and `session.close` with `durationMs` and `exitCause` for every session in the test run. |
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
- Pre-Slice-3 SE credentials (stored under the Slice 1 `kSecClassKey + kSecAttrTokenIDSecureEnclave` model) are unreachable from Slice 3+ builds. The orphaned entries remain in the data-protection keychain consuming trivial space; they cannot be used (the `SecAccessControl` is bound to the previous build's process) and Pulse no longer enumerates them. Operators on dev machines can clear them via Keychain Access by searching for `nz.omega.pulse.ssh.`; otherwise they're harmless. See `docs/credentials.md` Troubleshooting.

## Slice 3 amendments summary

Slice 3 (`feat/ssh-terminal-foundations`, 22 commits) absorbed three structural cascades into this document. Inline edits above reflect the current state; this section lists what changed and where so future readers can trace the contract evolution without re-reading every commit:

- **§1 v1 portable scope** — narrowed from "Ed25519 / ECDSA / RSA" to unencrypted ECDSA P-256/384/521 plus Ed25519. RSA portable signing deferred pending upstream `swift-nio-ssh` support (no RSA private-key path in 0.13.0 or `main`); encrypted PEMs deferred pending an Apple-shipped KDF source (PBKDF2 for PKCS#8, bcrypt-pbkdf for OpenSSH new-format). Amendment block inline at §1; the dormant modulus-enforcement and derivation scaffolding was removed at the close of Slice 3 (commit `7f545d2`) and is recoverable from `git show 4238b35` and `git show 023bd07` if upstream lands RSA signing.
- **§1 SE storage model** — moved from `Security.framework` `SecKey` to CryptoKit's `SecureEnclave.P256.Signing.PrivateKey`. Storage shape changed from `kSecClassKey + kSecAttrTokenIDSecureEnclave` (Slice 1) to `kSecClassGenericPassword + (service, account)` with the service derived from `Bundle.main.bundleIdentifier` (Slice 3 commit 7a). Non-exportability contract tightened from runtime check to compile-time guarantee.
- **§2 credential model** — example updated to show `SSHCredentialTier` + `SSHCredential` rather than the pre-implementation `SSHAuthMethod` enum sketch. Policy unchanged: no password path exists.
- **§7 audit events** — `cert.offered` added (delegate-side intent) alongside `cert.accepted` (server-side confirmation); `auth.failure` documented as one-shot per connection attempt; category list extended to reflect the current six namespaces (`ssh.auth`, `ssh.certificates`, `ssh.credentials`, `ssh.secureenclave`, `ssh.session`, `ssh.debug`).
- **§8 transport seam** — EventLoopGroup ownership made explicit (NIOTSEventLoopGroup; Apple-only; no abstraction over the group type until a non-Apple consumer exists). Channel/Sendable boundary pattern documented: `nonisolated(unsafe)` storage on the actor, `NIOLockedValueBox` for hot-path handlers, no per-chunk actor hops on the inbound data path.
- **§10 dependencies** — `swift-asn1` and `swift-crypto` added to the dependency table; both are transitive via swift-nio-ssh and documented as such.
- **Verification row 2** — non-exportability test mechanism rewritten to reflect the CryptoKit-based positive contract (the SecKey-based negative test no longer applies because Pulse holds no SecKey-resident SSH credentials).
- **Operational consequences** — pre-Slice-3 orphan `kSecClassKey` entries documented as harmless and unenumerated.

## Slice 4 amendments summary

Slice 4 extends PR #14 rather than branching off — Slice 3 has not merged to main at the time recording lands, and stacking the work behind the same review queue is cheaper than rebasing later. The slice absorbed four §6 amendments at plan-lock, each surfaced by the API-surface verification pass the discipline section below describes, plus two §6 additions clarifying behaviour the original ADR was silent on, plus one §7 audit-event split:

- **§6 file-protection asymmetry** — replaced "equivalent on macOS with FileVault" (which conflated two different primitives) with an explicit iOS-vs-macOS split. iOS sets `FileProtectionType.complete` on the session-log directory as defence-in-depth; macOS has no per-file protection class equivalent and relies on FileVault whole-volume. The actual confidentiality guarantee on both platforms is the SE-wrapped per-session symmetric key; manufacturing macOS-side ceremony that doesn't add real protection would be dishonest.
- **§6 sandbox-correct path resolution** — replaced the literal `~/Library/Application Support/...` (a latent sandbox bug that worked on a non-sandboxed dev Mac by accident and broke the moment App Sandbox or iOS entered the picture) with `FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, ...)` + `Pulse/Sessions/dev-<Device.id>/...` subpath. Resolves correctly on macOS non-sandboxed, macOS sandboxed, and iOS without further branching.
- **§6 device identity** — `<deviceUUID>` corrected to `dev-<Device.id>`. Pulse's `Device.id` is `Int64` with `@Attribute(.unique)` (the NetBox primary key), not a UUID; `Device` does not conform to `Identifiable`. `SSHClient.connect(...)` grew a required `deviceID: Int64?` parameter (no default) so ad-hoc call sites have to pass `nil` deliberately and visibly rather than silently landing logs under `unassigned/`. The SSH layer, SwiftData store, and filesystem walk now name the same device the same way; no parallel identifier was minted.
- **§6 CryptoKit-native wrapping** — replaced the `SecKeyCreateEncryptedData` / `eciesEncryptionStandardX963SHA256AESGCM` reference (which is `Security.framework`, inconsistent with the Slice 3 7a migration to CryptoKit) with ECDH on `SecureEnclave.P256.KeyAgreement.PrivateKey` + `HKDF<SHA256>` + `AES.GCM`. End-to-end CryptoKit. Wrapping key is one per device at service `<Bundle.main.bundleIdentifier>.ssh.logwrap`.
- **§6 mid-session recording-failure semantics** — new prose. Terminal `.recordingStopped` state on first failure; no gap records, no chain holes. `.meta.exit_cause = "recording_failed_midstream"` carries the truth. Chosen over chain-continues-with-discontinuous-seq because the latter creates a recording that replays seamlessly with no operator-visible indication that bytes are missing, which is the worst framing for a tamper-evident log.
- **§6 back-pressure bound** — new prose. Writer queue capped at 1024 records or 4 MiB pending plaintext, whichever is reached first. Overflow emits `session.recording.failed` with `reason: "back_pressure_overflow"` and transitions to the same terminal stop. EventLoop is never blocked and the session byte pump never observes the overflow.
- **§7 replay event split** — `session.recording.replayUnwrapped` fires on biometric success regardless of subsequent chain validation outcome (operator access to a recorded log is security-relevant independent of file integrity); `session.recording.replayChainBroken` fires on validation failure during replay (distinct event so any future SIEM rule can fire cleanly on tamper-after-access).

Two implementation guardrails worth surfacing because they're easy to lose silently:

- The chain hash is always computed from the raw on-disk `SealedBox.combined` bytes, never from a re-encoded `Codable` envelope. Any path that round-trips through `JSONDecoder` then `JSONEncoder` to compute the next `prev` is a future-`JSONEncoder`-update timebomb (a Foundation patch changing key ordering, escaping, or number formatting would silently invalidate every historical log).
- The recording tap lives in `SSHClient`'s channel pipeline as a `ChannelDuplexHandler` before `SSHSessionDataBridge`. `SSHSession` stays consumer-agnostic — widening `SSHSession.setOutputHandler` to a multiplexer would push consumer-fan-out concern into a foundational class where the next slice (compliance audit, replay, metrics) would force it further. The structural gate `grep -n "SessionLogWriter\|RecordingTap" Pulse/SSH/SSHSession.swift` returns empty.

## Forward-looking implementation discipline

Slice 3 surfaced three structural cascades during implementation that were, in retrospect, knowable from public-API inspection before the plan was locked. The rolling pause-decide-resume discipline contained each cascade to one extra commit instead of multiple review rounds, but the cleaner cost reduction is earlier verification.

### API-surface verification before locking a slice plan

Every slice that depends on external API surfaces (Apple SDK, vendored package, system framework) should perform a short verification pass before code starts:

1. **Type existence.** For every external type the plan names, confirm the type exists at the pinned dependency version. Five-minute pass through the package source or Apple developer docs.
2. **Init / method / property reachability.** For every external API the plan calls, confirm the init or method exists in the public API and is reachable from Pulse code (not `internal` or `private`).
3. **Capability coverage.** Confirm the external type's documented capabilities cover what the plan requires (e.g., "Does CryptoKit's Curve25519 init from PEM?"). When the answer is uncertain, write a ~20-line spike before locking the plan rather than assuming.
4. **Dependency version confirmation.** Re-check `Package.resolved` if the slice depends on transitively-pulled deps; surfaces can move across minor versions.

Three cascades from Slice 3 that this discipline would have caught at planning rather than implementation time:

- NIOSSH's `BackingKey` is `internal` — visible in the swift-nio-ssh source in five minutes.
- NIOSSH has no RSA private-key path — visible from `NIOSSHPrivateKey`'s init methods in the same five minutes.
- CryptoKit's `Curve25519.Signing.PrivateKey` has no PEM init — visible in Apple's Developer documentation.

The discipline is cheap and forces explicit confrontation with the v1 dependency surfaces before commitments are made. It complements the pause-decide-resume discipline; doesn't replace it.

### Per-slice verification questions

These are the known-risk surfaces for upcoming slices, captured while Slice 3's lessons are fresh. Each upcoming planning conversation should walk this list as the first step, plus whatever the API-surface pass surfaces fresh.

**Slice 4 — `SessionLogWriter` + `credential.recordSessions` branching.** *Resolved at Slice 4 plan-lock — resolutions captured in the Slice 4 amendments summary above. Questions preserved here as a record of the verification discipline working.*

- Does `SecureEnclave.P256.KeyAgreement.PrivateKey` exist alongside `SecureEnclave.P256.Signing.PrivateKey`? **Yes** (iOS 13+/macOS 10.15+), with `init(accessControl:)` and `init(dataRepresentation:)` mirroring the signing-key surface, and `sharedSecretFromKeyAgreement(with:)` producing a `SharedSecret`. The wrapping path is fully CryptoKit-native; the `SecKeyCreateEncryptedData` reference was retired.
- How does `NSFileProtectionComplete` map to macOS? **It doesn't, as a per-file primitive.** `FileProtectionType` compiles on macOS but only `.none` carries real semantics outside the iOS family; macOS at-rest protection is FileVault (whole-volume). §6 amended to document the asymmetry openly rather than manufacture macOS-side ceremony.
- Where does `~/Library/Application Support/Pulse/Sessions/` resolve on iOS? **It doesn't resolve cleanly inside App Sandbox.** Path resolution moved to `FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, ...)` which lands platform-correctly on macOS non-sandboxed (`~/Library/Application Support/...`), macOS sandboxed (`~/Library/Containers/<bundle-id>/Data/Library/Application Support/...`), and iOS (`<container>/Library/Application Support/...`) without further branching.
- Does `CryptoKit.AES.GCM` handle the per-record encryption shape? **Yes.** `seal(_:using:nonce:)` takes a `SymmetricKey` + fresh `AES.GCM.Nonce()` (12-byte random) per record; `SealedBox` exposes `.nonce`, `.ciphertext`, `.tag`, and `.combined`. The `prev = SHA256(prevSealedBox.combined)` hash chain lives in the *plaintext* envelope before sealing.
- Are JSONL records, AES-GCM ciphertext, and the hash-chain prev field naturally serialisable as a single `Codable` envelope? **Yes**, with one guardrail: chain validation operates on raw on-disk `SealedBox.combined` bytes, never on a re-encoded envelope, to avoid future `JSONEncoder` updates silently invalidating historical logs.

Also discovered during plan-lock (not in the pre-slice question list but worth noting for the verification-discipline record): `SSHClient.connect(...)` had no `deviceID` parameter, and `Device.id` was `Int64` not UUID — caught by a five-minute SwiftData-model grep before code started, propagated as a third §6 amendment.

**Slice 5 — SwiftTerm integration + operator-facing terminal + host-key mismatch UI.** Verify before locking:

- SwiftTerm's bytes-in API surface — does it take `ArraySlice<UInt8>` (matching `SSHSession.setOutputHandler`'s shape), `Data`, or `[UInt8]`? `SSHSession`'s API was shaped on the assumption that `[UInt8]`-shaped consumption works without copying; confirm or note the adapter.
- `NSViewRepresentable` / `UIViewRepresentable` wrapping cleanliness — is there a known-good integration pattern for SwiftTerm in SwiftUI, or do we own that work? The omega "brain dead simple" lens says use SwiftTerm's documented pattern if one exists.
- Pinned tag stability — what's the current SwiftTerm release cadence, and which tag is the slice targeting? ADR §10 calls for explicit-review tag bumps; first-time pinning is the same concern.
- Does SwiftTerm carry features for the v1 verification artefact in row 4 of the verification table: 256-colour rendering, `top`, `vim`, `Ctrl+C` propagation, resize-via-`tput`? If any of these is missing, the verification table needs revising (or SwiftTerm needs replacing, which is a much larger conversation).
- Host-key mismatch UI sheet — what's the operator action surface? Accept / reject / forget? Where does the trust update land in `KnownHost`? Per ADR §5 the trust UI distinguishes the three modes by colour; the mismatch sheet needs to surface the same visual contract.

**Slice 6 (or wherever the Web companion lands) — `WebPage` + custom URL scheme handler.** Verify before locking:

- `WebPage.Configuration.urlSchemeHandlers["pulse-tunnel"]` — does this surface exist on iOS 26 / macOS 26 and accept the dictionary shape §8 sketches? These are new SDKs; surfaces may have shifted from beta to release.
- Custom `URLSchemeHandler` byte-streaming — does the handler support PulseTransport's `Channel`-returning shape, or does it require a different response-delivery pattern? The seam needs to bridge two different async models (WebKit's URLSchemeHandler callback vs SwiftNIO's EventLoopFuture/Channel).
- Toolbar binding to `page.title` / `page.estimatedProgress` — `@Observable` propagation in iOS 26 / macOS 26, KVO bridge, or manual `@Published`?
- Navigation decider blocks unrelated origins — per the verification table row 9. Confirm the WebKit API for navigation decision callbacks; the surface has shifted across recent macOS releases.

**Slice 7 — `HostTrust.trustedCA` import UI + per-site enforcement policy.** Verify before locking:

- CA bundle import format — what does the operator paste or import? Single `~/.ssh/ca.pub` line? OpenSSH `cert-authority` line in known_hosts format? PEM bundle? Multiple CA public keys in one file? The Slice 3 evaluation path consumes `caFingerprintSHA256` + `principalPattern`; the UI needs to produce both from whatever format operators have in hand.
- Principal pattern syntax scope — Slice 3's `SSHHostKeyDelegate.matches(host:anyOf:pattern:)` supports literal equality and trailing-`*` wildcard only. If Slice 7's UI accepts richer OpenSSH patterns (`!host` negation, comma-separated lists, the full `Match` block grammar), the matcher needs extending. Decide scope before the UI work locks; mismatch between UI and matcher capability is the failure mode to avoid.
- Per-site enforcement policy storage — `requireCertificateVerification: Bool` lives where? Per-`Site` model field? Per-tenant `Configuration`? Both? §5 says "per-site / per-tenant" without committing to a storage location; pick before adding the field.

**Future portable additions — encrypted PEM import (no current slice number).** When this opens, verify:

- Is bcrypt-pbkdf reachable via any Apple-shipped SDK (CryptoKit, CommonCrypto, or other)? Current answer is no, which is why the deferral exists. Re-check at the time; the deferral is gated on Apple shipping a usable primitive, not on internal scoping.
- Is PBKDF2 reachable via CryptoKit on current Apple platforms, or still only via CommonCrypto? CommonCrypto is system-shipped (not third-party), so PBKDF2 is acceptable per §10 if the Swift surface is usable; confirm the import path and call ergonomics.
- Are AES-CTR / AES-CBC available via CryptoKit, or do they still require CommonCrypto? CryptoKit's AES surface is GCM-only as of writing; encrypted PKCS#8 needs CBC (or sometimes CTR), encrypted OpenSSH new-format needs CTR.

## Review

This document is the contract. Changes require a new ADR or an amendment with explicit rationale. Implementation PRs touching SSH, Web, transport, credentials, or session logging must reference this ADR in their description.
