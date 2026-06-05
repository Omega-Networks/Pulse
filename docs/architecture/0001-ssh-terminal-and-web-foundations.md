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
- Per-session override field on the connect form. As-built (Slice 7): shipped as the inline `SSHConnectForm` in `Pulse/Views/Terminal/`, not a separate `SSHConnectSheet`. See the Slice 7 amendments summary.

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

A per-site / per-tenant policy `requireCertificateVerification: Bool` is reserved for v2 and lands with `trustedCA` enforcement (FreeIPA enrolment). When `true`, non-cert-attested connections will be refused without an explicit override that is logged. It is not implemented in v1; the `pinned` TOFU path is the v1 trust model.

The UI distinguishes the trust modes at a glance: CA-attested (green), pinned (amber), unverified (red). No exceptions to this visual contract.

### 6. Session recording: opt-in, encrypted, tamper-evident

Per-credential `recordSessions: Bool` toggle. Off by default. On for credentials used for break-glass / production-change work.

When on:

- Raw byte streams in both directions are recorded.
- Each session writes two files under `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)` with subpath `Pulse/Sessions/dev-<Device.id>/<timestamp>_<sessionUUID>.{pulselog,meta}`. Resolution is platform-correct without a literal tilde: macOS non-sandboxed `~/Library/Application Support/Pulse/Sessions/...`; macOS sandboxed `~/Library/Containers/<bundle-id>/Data/Library/Application Support/Pulse/Sessions/...`; iOS `<container>/Library/Application Support/Pulse/Sessions/...`. `Device.id` is the SwiftData `@Attribute(.unique)` `Int64` already in use across the model layer (the NetBox primary key); no fresh UUID is minted. When `deviceID` is unavailable (ad-hoc connections from debug surfaces, devices without a NetBox row), the path becomes `Pulse/Sessions/unassigned/<timestamp>_<sessionUUID>.{pulselog,meta}`. `SSHClient.connect(...)` accepts a required `deviceID: Int64?` parameter (no default); ad-hoc call sites pass `nil` deliberately and visibly.
- `.pulselog` is JSONL. Each record is encrypted with `AES.GCM` (CryptoKit) using a per-session 256-bit symmetric key. Records carry a `prev` field holding the SHA-256 of the previous record's `AES.GCM.SealedBox.combined` (nonce || ciphertext || tag) — a hash chain that detects insertion, deletion, or reordering. The chain hash is always computed from the raw on-disk bytes, never from a re-encoded `Codable` envelope; the pure-function surface in `SessionLogRecord.swift` exposes `chainHash(of combined: Data) -> String` operating on raw bytes, and no `SessionLogRecord`-typed re-encode helper exists (a Foundation patch that changes `JSONEncoder` key ordering, escaping, or number formatting would otherwise silently invalidate every historical log).
- The session key is wrapped via ECDH on a Secure-Enclave-resident `SecureEnclave.P256.KeyAgreement.PrivateKey` (the "log wrapping key") against an ephemeral `P256.KeyAgreement.PrivateKey` generated per session, feeding `sharedSecretFromKeyAgreement(with:)` into `HKDF<SHA256>.deriveKey(...)` to produce a 256-bit AES key, then `AES.GCM.seal(...)` over the 32-byte session-key material. The wrapped blob in the file header is the ephemeral public key (`x963Representation`, 65 bytes) concatenated with the `AES.GCM.SealedBox.combined`. Unwrapping reads the header, runs the same ECDH against the SE key (biometric prompt fires here), derives the same KEK, and opens the sealed box. CryptoKit-native end to end; no `Security.framework` cryptographic primitives. The wrapping key is one per device (not per credential, not per session), stored at service `<Bundle.main.bundleIdentifier>.ssh.logwrap`, mirroring the SSH-credential storage shape.
- File protection: iOS sets `FileProtectionType.complete` on the session-log directory as defence-in-depth. macOS has no per-file protection class equivalent — the `FileProtectionType` symbols compile on macOS but only `.none` carries real semantics outside the iOS family. macOS at-rest protection is FileVault (whole-volume). The actual confidentiality guarantee on both platforms is the SE-wrapped per-session symmetric key: `.pulselog` ciphertext is unreadable without biometric on the device that recorded it, FileVault or no FileVault. This iOS-vs-macOS asymmetry is documented openly rather than papered over with manufactured macOS-side ceremony that doesn't add real protection.
- `.meta` sidecar holds searchable, unencrypted metadata: `device_id: Int64?` (nil for unassigned), `credential_id: UUID`, username, host, port, opened/closed timestamps, duration, exit cause (from the seven-case `ExitCause` enum), record count, chain-head hash (hex SHA-256 of the final record's `SealedBox.combined`), and a relative `pulselog_path`. Lets the session browser list and search without prompting biometric on every refresh.
- Retention is configurable per-tenant. Default 1 year. Auto-purge runs at launch via `SessionLogRetention.purgeAtLaunch(maxAge:)`.
- **Mid-session recording-failure semantics: terminal stop, no gap records.** A `.pulselog` is either complete-and-chain-validated end to end, or it ended early and `.meta` carries the truth. On the first failure inside the writer (encryption failure, seal-then-write fault, queue overflow per the back-pressure rule below), the writer transitions to a terminal `.recordingStopped` state, emits `session.recording.failed` with the specific reason exactly once, and finalises `.meta` with `exit_cause: "recording_failed_midstream"`. Subsequent records are silently dropped. The underlying SSH session keeps flowing bytes through the tap and on to the consumer (SwiftTerm, debug menu) uninterrupted — recording failure never propagates into the byte pump. There are no "valid chain with holes" and no sentinel gap records: chain-continues-with-discontinuous-seq creates a recording that replays seamlessly with no operator-visible indication that bytes are missing, which is the worst framing for a tamper-evident log.
- **Back-pressure bound.** The recording tap dispatches into the writer actor via fire-and-forget `Task { await writer.record(...) }`. The actor's internal pending-record queue is bounded at **1024 records or 4 MiB total pending plaintext bytes**, whichever is reached first. On overflow the writer emits `session.recording.failed` with `reason: "back_pressure_overflow"` and transitions to the same `.recordingStopped` terminal state. The EventLoop is never blocked and the session byte pump never observes the overflow.
- **No plaintext log is ever written to disk.** This is enforced by routing all session-byte writes through a single `SessionLogWriter` whose only output method takes a ciphertext record. The recording tap (`SSHSessionRecordingTap`, a `ChannelDuplexHandler`) lives in `SSHClient`'s channel pipeline before `SSHSessionDataBridge`; `SSHSession` stays consumer-agnostic (the structural gate `grep -n "SessionLogWriter\|RecordingTap" Pulse/SSH/SSHSession.swift` returns empty).
- **Exit-handler multicast (Slice 5).** `SSHSession.addExitHandler` is a multicast registration: each `signalExit` invokes every registered handler exactly once in registration order. `SSHClient.connect` registers the `session.close` audit emitter (see §7); `SSHTerminalView.runConnectionLifecycle` registers the continuation-resume handler. Future consumers (recording-status indicator, metrics, compliance taps) attach via the same seam. A handler registered after `signalExit` has already latched the session is invoked synchronously with the recorded cause — the late-registration immediate-fire contract closes a latent deadlock where a fast handshake-then-drop sequence between the two registration sites would otherwise strand the second registrant. *Alternative considered:* relocate `session.close` directly into `SSHClient.close()` so no exit-handler closure is needed. Smaller patch, but the multicast seam is load-bearing for the recording-status and metrics consumers in upcoming slices; the relocate would have to be undone. Multicast was chosen for that reason.
- **PTY geometry two-pump (Slice 5).** `SSHTerminalView.runConnectionLifecycle` allocates the PTY at request time with the geometry it reads from `PulseTerminalSurface.currentTerminalGeometry()` (falling back to the SSH protocol default 80x24 if the view has not yet been laid out), then re-reads the geometry once more after `requestShell` and sends an explicit `window-change` if the two reads differ. This is the canonical pattern in SwiftTermApp's reference at `TerminalApp/iOSTerminal/UIKitSshTerminalView.swift` lines 362-379 (initial size) + lines 310-315 (`sendInitialResize`). A `Task.yield()` between `status = .connected` and the first read gives SwiftUI's first layout pass an opportunity to complete; the yield is not a synchronisation primitive (if layout defers further, pump 1 falls back to 80x24 and pump 2 catches up to reality) but it materially raises the probability that the initial allocation is at the right size. *Why two pumps not one:* bash's readline state for an in-progress input line does not fully reset on SIGWINCH — it updates `COLUMNS` and reflows, but cursor-position memory for the current line stays in the old geometry. Allocating at the wrong size and relying on the post-resize SIGWINCH to fix it corrupts the line-editor across the first prompt; allocating at the right size from the start avoids the corruption. *Alternative considered:* `awaitFirstSize(timeout: 2.seconds)` — wait synchronously for SwiftTerm to report a real size before the PTY request. Rejected: deterministic 2-second connect delay on iconified or off-screen windows. The two-pump synchronous-read-with-fallback pattern matches SwiftTerm's own reference and has no blocking step.

### 7. Audit metadata is always on

Independent of the recording toggle, every session emits structured `os_log` events under the project's `pulse` subsystem with categories beginning `ssh` (plus `hostkey.coordinator` for the UI-level coordinator's contract-violation faults — see Slice 5 amendments). The current category set is `ssh.auth`, `ssh.certificates`, `ssh.credentials`, `ssh.recording`, `ssh.secureenclave`, `ssh.session` (which carries both session-lifecycle and host-key events), `ssh.debug` for the `#if DEBUG`-gated DebugSSHMenu surface, and `hostkey.coordinator` for `HostKeyMismatchCoordinator` faults. Operators filter with `log show --predicate 'subsystem == "pulse" AND (category BEGINSWITH "ssh" OR category == "hostkey.coordinator")'`.

**Naming convention.** Audit-event names are dot-separated identifiers. The event name is the first whitespace-delimited token on the log line. Sub-events use a further dot suffix (`event.subevent`). SIEM rules must match the leading token with a whitespace boundary, not a substring — a substring match on `host.mismatch.accepted` would otherwise false-match `host.mismatch.accepted.commit_failed`, conflating operator intent with storage failure.

Events emitted:

- `session.open`, `session.close` — once each per attempt; `session.close` carries `durationMs` and an `exitCause` from the seven-case `ExitCause` enum.
- `auth.success`, `auth.failure` — `auth.failure` emits at most once per connection attempt. The first key-load or offer-exhaustion failure latches; subsequent retries from the NIOSSH user-auth loop return `nil` immediately without re-emitting. This keeps a single failed connection from flooding the audit log.
- `host.pinned`, `host.mismatch`, `host.ca-accepted`, `host.ca-rejected`.
- `host.mismatch.accepted` (warning) — operator chose Accept in the mismatch sheet. Emitted **before** the trust-store commit so the intent is recorded whether or not the commit succeeds.
- `host.mismatch.accepted.commit_failed` (error) — emitted only when `store.replacePin` fails after the intent was recorded. SIEM rules keyed on `host.mismatch.accepted` (leading-token match) record the intent without false-matching this failure line.
- `host.mismatch.forgotten` (warning) and `host.mismatch.forgotten.commit_failed` (error) — symmetric pair for the Forget path.
- `host.mismatch.rejected` (warning) — operator chose Reject, or the decision resolved via the coordinator's reject-reason vocabulary (see below).
- `hostkey.coordinator.concurrent_decide` (fault, category `hostkey.coordinator`) — `HostKeyMismatchCoordinator` received a second `decide` call while one was in flight. The contract is one coordinator per terminal view; the violation degrades the second decision to `.reject(reason: "concurrent_decide")` and continues. The fault-level emission lands in Console.app and any SIEM ingesting `os_log` without taking the app down.
- `cert.offered`, `cert.accepted`, `cert.rejected`, `cert.expired` — `cert.offered` emits when the auth delegate decides to present a stored certificate; `cert.accepted` confirms the server accepted it after session-open. Two separate events because the audit log needs to distinguish delegate-side intent from server-side outcome.
- `credential.created`, `credential.imported`, `credential.deleted`. Emitted by `CredentialAudit` under `ssh.credentials` with `credentialID` and `tier`. `credential.imported` is distinct from `credential.created` because importing external PEM key material is a separate security-relevant action from generating a non-exportable Secure Enclave key. `credential.rotated` is deferred: v1 has no key-rotation flow (the only way to replace a key is delete then create), so the event is reintroduced by the slice that adds rotation rather than shipped as a token that fires from nowhere.
- `credential.recording.enabled`, `credential.recording.disabled` — operator toggled the per-credential `recordSessions` flag.
- `session.recording.opened`, `session.recording.closed` — recording lifecycle, fires only when `credential.recordSessions == true`. `closed` carries `recordCount`, `chainHeadHash`, `durationMs`.
- `session.recording.failed` — recording stopped mid-session. `reason` is one of `seal_failure`, `write_failure`, `encode_failure`, `back_pressure_overflow` (matching `SessionRecordingAudit.FailureReason.auditReason`; a wrap failure at recording open is logged as a pre-recording open failure, not a `session.recording.failed`). The session continues; the recording does not.
- `session.recording.replayUnwrapped` — operator-driven replay; biometric succeeded. Fires regardless of subsequent chain validation outcome because the fact of operator access to a recorded log is security-relevant independent of file integrity.
- `session.recording.replayChainBroken` — chain validation failed during replay. Distinct from `replayUnwrapped` so any future SIEM rule can fire cleanly on tamper-after-access. Carries `brokenAtSeq`.
- `session.recording.purged`, `session.recording.purgeFailed` — launch-time retention purge outcome.

Metadata fields: `deviceID`, `credentialID`, `username`, `host`, `port`, `openedAt`, `closedAt`, `exitCause`. Session contents and key material are never included. This signal is captured by `log show` and falls into sysdiagnose by default — it is recoverable even when the device is examined offline.

**Reject-reason vocabulary.** `HostKeyMismatchDecision.reject(reason:)` carries a controlled vocabulary so operations can distinguish operator intent from system-driven outcomes:

- `nil` — operator clicked Reject in the mismatch sheet.
- `"decision_timeout"` — the 90-second decision timer fired before the operator acted. Operator walked away from the sheet.
- `"cancelled"` — the parent task was cancelled (window closed, navigation popped) while the sheet was up. Operator closed the window mid-decision.
- `"concurrent_decide"` — the coordinator received a second `decide` call while one was in flight (contract violation; degraded outcome).

### 8. Transport abstraction is the single tunnel seam

```swift
protocol PulseTransport {
    func connect(to host: String, port: Int, on eventLoop: EventLoop) -> EventLoopFuture<Channel>
}
```

- v1 default: `DirectTransport` using `NIOTSConnectionBootstrap`.
- Future tunnel: `TunnelTransport` returning a `Channel` whose I/O is forwarded through the in-app tunnel.
- SSH consumes `PulseTransport` in v1. As-built, the v1.5 Web window loads directly through `WebPage` and does **not** consume `PulseTransport`; the Web side doing so via `WebPage.Configuration.urlSchemeHandlers["pulse-tunnel"]` (a handler resolving requests through `PulseTransport`) is the deferred W3 tunnelled path, not the shipped window.
- Every `PulseTransport` implementation sets a finite connect timeout. The v1 default in `DirectTransport` is 10 seconds. Future implementations may surface a config knob but must never default to an unbounded wait; hanging operator UI is a failure mode the seam exists to prevent. `NIOTSConnectionBootstrap`'s default behaviour is an infinite wait, so the timeout is set explicitly via `.connectTimeout(...)`.
- Transports must support dual-stack addresses (IPv4 and IPv6). `NIOTSConnectionBootstrap` satisfies this via Happy Eyeballs through Network.framework. Loopback verification covers both stacks (`127.0.0.1` and `::1`) so an IPv6 regression trips a test rather than surfacing in the field.
- **EventLoopGroup ownership.** v1 transports use `NIOTSEventLoopGroup` exclusively because Pulse runs only on Apple platforms; NIOTransportServices is the right group type for any Network.framework consumer. `SSHClient` constructs the group inside `connect()`. A future `TunnelTransport` will use the same group type for the same reason — there is no abstraction over the group type because there is no second consumer to abstract for. If Pulse ever grows a non-Apple build target this assumption needs revisiting.
- **`Channel` Sendable boundary.** NIOCore's `Channel` is not `Sendable` under Swift 6 strict-concurrency rules but every channel method dispatches internally to its `EventLoop`. The pattern used across `SSHClient` and `SSHSession`: store the channel as `nonisolated(unsafe)` on the actor, route work through `EventLoopFuture` chains, return only `Sendable` snapshots (the session, byte slices, errors) across the actor boundary. `SSHSession`'s output and exit handlers live in an `NIOLockedValueBox` so the inbound EventLoop thread can deliver bytes synchronously without paying for an actor hop per chunk: the hot path tolerates the lock but not the cooperative-pool latency at terminal-responsiveness scales. `SessionLogWriter` and the operator-facing SwiftTerm consumer inherit this discipline.
- The protocol stays small. If it grows beyond `connect`, the abstraction has failed and should be reviewed.

### 9. UI surface — two windows, one Settings pane

- `WindowGroup("SSH Terminal", for: Device.ID.self)` and `WindowGroup("Device Web", for: Device.ID.self)`, mirroring the existing `WindowGroup("Site View", for: Site.ID.self)` in `PulseApp.swift`. As-built: the SSH terminal scene ships id-addressed (`WindowGroup("SSH Terminal", id: "ssh-terminal", for: Device.ID.self)` in `SSHTerminalWindow.swift`, wired via `SSHTerminalScene` in `PulseApp.swift`) to avoid the `Device.ID` / `Site.ID` collision on `Int64`. See the Slice 8a routing-disambiguation note (and the Slice 8b amendments summary for the nominal-struct hardening that turned the routing into a compile-time guarantee). As-built (Slice W2b): the Device Web window ships the same way, `WindowGroup("Device Web", id: "device-web", for: Device.ID.self)` in `DeviceWebWindow.swift` wired via `DeviceWebScene`, rendering a device's web UI with `WebView` / `WebPage`. See the Web companion Slice W2a and W2b amendments.
- Entry points: `DeviceRow.contextMenu` and `DeviceView` popover. Open SSH Terminal is disabled when `device.primaryIP == nil`; Open Web UI is shown only when `WebServiceResolver.primaryTarget(for:)` resolves a NetBox-declared web service.
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

**SwiftTerm bump checklist.** When upgrading the pinned SwiftTerm version, the diff review must confirm two invariants the operator-facing byte pump depends on:

- `TerminalView.feed(byteArray: ArraySlice<UInt8>)` remains the public API at the equivalent of `Sources/SwiftTerm/Apple/AppleTerminalView.swift:1910`. `PulseTerminalAdapter.drainPendingFeed` calls this method; it must continue to wrap `Terminal.feed(buffer:)` (the engine) with display-scheduling.
- `feedFinish()` continues to call `queuePendingDisplay()`. The view's `feed(byteArray:)` is the only path that schedules an AppKit/UIKit `setNeedsDisplay` cycle for inbound bytes. A SwiftTerm restructure that drops `queuePendingDisplay()` from `feedFinish()` (or renames either method without a behavioural replacement) would silently re-introduce a "left-click required to render terminal output" symptom: the engine would accumulate bytes correctly, the grid model would stay current, but the platform view would never get marked dirty and would render only when something else (a click, a resize, a keystroke) triggered a redraw.

If either invariant breaks, the bump is blocked until the equivalent display-scheduling contract is restored, either by SwiftTerm or by an explicit Pulse-side `setNeedsDisplay` poke that respects SwiftTerm's `suspendDisplayUpdates()` coalescing.

## What ships when

### v1 (this feature)
- Secure Enclave key generation + signing (ECDSA P-256).
- PEM import for legacy credentials, unencrypted only: ECDSA P-256/384/521 (traditional, PKCS#8, OpenSSH new-format) and Ed25519 (OpenSSH new-format).
- SSH certificate authentication (`NIOSSHCertifiedPublicKey`).
- Polymorphic `HostTrust` (pinned case implemented; `trustedCA` schema reserved).
- Audit metadata via `os_log`.
- Encrypted session recording behind per-credential toggle.
- Session browser with biometric-gated playback.
- SSH terminal window.
- `PulseTransport` seam with `DirectTransport` implementation.

### v1.5 (Web companion)
- In-app `WebView` / `WebPage` device UI. **As-built (W1 + W2a + W2b):** the Device Web window ships, with the URL derived from NetBox Application Services (source of truth), per-host operator-acknowledged TLS trust for self-signed appliance certificates, a navigation decider for origin containment, and toolbar bindings (`page.title`, `page.estimatedProgress`). See the Web companion Slice W1 / W2a / W2b amendments.
- **Deferred to W3:** the `pulse-tunnel://` scheme handler resolving through `PulseTransport`. The as-built window loads directly; the tunnelled path is gated on the transport work. The `PulseTransport` seam shipped in v1.

### v2
- FreeIPA enrolment UI and trusted-CA import (including `requireCertificateVerification` enforcement).
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
2. **The only payload `SessionLogWriter` writes to disk is a sealed `EncryptedRecord`** (`SessionLogCrypto.seal` produces it; the writer's `appendLine` is the sole disk sink). Plaintext bytes have no path to disk.
3. **`SSHCredential` has no `username` property.** Reviewers cannot accidentally re-introduce the per-credential username binding.
4. **`HostTrust` is polymorphic from day one.** Adding `trustedCA` enforcement later does not require a schema migration that could be skipped or fail silently.
5. **`PulseTransport` is the single dependency for outbound SSH bytes.** Direct use of `NIOTSConnectionBootstrap` for SSH device traffic is grep-checkable and reviewed. As-built, the v1.5 Web window loads through WebKit's own networking (with per-host operator-acknowledged TLS trust), not `PulseTransport`; routing Web bytes through the seam is the deferred W3 path.

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
| 9 | Web companion | Device with a NetBox-declared web service renders in `WebView`; toolbar binds to `page.title` / `page.estimatedProgress`. A self-signed certificate raises the per-host trust prompt (accept pins, reject cancels). Navigation decider keeps in-app navigation same-origin and routes foreign origins to the system browser. The `pulse-tunnel://` scheme-handler path is deferred to W3. |
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
- SE credentials created under the previous `kSecClassKey + kSecAttrTokenIDSecureEnclave` storage model (before the CryptoKit migration) are unreachable from current builds. The orphaned entries remain in the data-protection keychain consuming trivial space; they cannot be used (the `SecAccessControl` is bound to the previous build's process) and Pulse no longer enumerates them. Operators on dev machines can clear them via Keychain Access by searching for `nz.omega.pulse.ssh.`; otherwise they're harmless. See `docs/credentials.md` Troubleshooting.

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
- **Byte-pump outbound-type correction (post-implementation).** `SSHSessionDataBridge.OutboundIn` was declared `ByteBuffer` but `SSHSession.write` emits `SSHChannelData` directly via `childChannel.writeAndFlush(...)`. The bridge's `write(context:data:promise:)` rewrapped a (never-actually-flowing) `ByteBuffer` into `SSHChannelData`, keeping the declaration internally consistent on paper while never matching the runtime payload. The mismatch would have surfaced as a `unwrapOutboundIn` force-cast crash the moment any caller drove `SSHSession.write` end-to-end. Dormant during the recording slice because the debug menu uses `triggerUserOutboundEvent` for `exec`; the operator-facing terminal's keystroke path is the first real caller. Bridge now declares `OutboundIn = SSHChannelData` and forwards `context.write(data, promise: promise)` as a pure pass-through. Regression guard test on an `EmbeddedChannel` lives in `SSHClientTests.testBridgeForwardsOutboundSSHChannelDataWithoutCrash`. Caught during the structural-gate audit of the byte-pump shape and fixed pre-emptively.

Three implementation guardrails worth surfacing because they're easy to lose silently:

- The chain hash is always computed from the raw on-disk `SealedBox.combined` bytes, never from a re-encoded `Codable` envelope. Any path that round-trips through `JSONDecoder` then `JSONEncoder` to compute the next `prev` is a future-`JSONEncoder`-update timebomb (a Foundation patch changing key ordering, escaping, or number formatting would silently invalidate every historical log).
- The recording tap lives in `SSHClient`'s channel pipeline as a `ChannelDuplexHandler` before `SSHSessionDataBridge`. `SSHSession` stays consumer-agnostic — widening `SSHSession.setOutputHandler` to a multiplexer would push consumer-fan-out concern into a foundational class where the next slice (compliance audit, replay, metrics) would force it further. The structural gate `grep -n "SessionLogWriter\|RecordingTap" Pulse/SSH/SSHSession.swift` returns empty.
- The recording writer's actor uses a single-drain-task queue rather than fire-and-forget `Task`s per record. Swift's concurrency runtime does not guarantee that two independently-spawned `Task { await actor.method(...) }` calls enter the actor in spawn order. Each `Task` races independently for actor entry. For ordered ingest from an EventLoop the queue-and-drain pattern (push into a `NIOLockedValueBox`-backed queue under the nonisolated entry point; kick a single drain `Task` if none is running; the drain pops FIFO under the actor's isolation) gives strict ordering without an `AsyncStream`-shaped channel dependency. Any future actor consuming an ordered stream from an EventLoop should reach for this pattern. Discovery cost was an intermittent test flake mid-implementation; the precedent is documented here to skip that round next time.

## Slice 5 amendments summary

Slice 5 (SwiftTerm integration, operator-facing SSH terminal, host-key mismatch UI) introduced the multicast exit-handler seam in `SSHSession` and the audit-event additions for the host-key mismatch flow. Five structural changes:

- **§6 exit-handler multicast** — `SSHSession.setExitHandler` (single-slot) replaced by `SSHSession.addExitHandler` (multicast). The single-slot version had a silent regression hazard: any second registration overwrote the first, and during Slice 5 the lifecycle wrapper's continuation-resume handler silently clobbered the `session.close` audit emitter registered by `SSHClient.connect`. The multicast version invokes every registered handler exactly once in registration order; a handler registered after `signalExit` has already latched is invoked synchronously with the recorded cause (the late-registration immediate-fire contract closes a latent deadlock where a fast handshake-then-drop sequence between the two registration sites would otherwise strand the second registrant). Alternative considered: relocate `session.close` directly into `SSHClient.close()`. Multicast was chosen because the seam is load-bearing for the recording-status indicator, metrics, and compliance taps in upcoming slices.
- **§7 audit-event naming convention** — pinned: event names are the first whitespace-delimited token on the log line; sub-events use a further dot suffix (`event.subevent`); SIEM rules match leading-token-with-whitespace-boundary, not substring. This is the convention the existing event set already follows (`session.close`, `host.pinned`, etc.); Slice 5 formalises it because the new `host.mismatch.accepted.commit_failed` sub-event would have false-matched any substring rule on `host.mismatch.accepted` and conflated operator intent with storage failure.
- **§7 new audit events for the mismatch flow** — `host.mismatch.accepted` (operator intent recorded before commit), `host.mismatch.accepted.commit_failed` (emitted only when the trust-store write throws), symmetric `host.mismatch.forgotten` and `host.mismatch.forgotten.commit_failed`, and `hostkey.coordinator.concurrent_decide` (fault-level emission when the coordinator receives a second `decide` call while one is in flight). The audit-before-commit ordering means the operator's intent is always recorded regardless of whether the storage commit succeeds.
- **§7 reject-reason vocabulary** — `decision_timeout` (operator walked away from the sheet), `cancelled` (parent task cancelled, sheet still up), `concurrent_decide` (contract-violation degrade). The distinct vocabulary lets operations distinguish "closed the window" from "walked away" from "system misconfiguration" rather than collapsing all three into a single rejected outcome.
- **`HostKeyMismatchCoordinator` contract violation** — concurrent `decide` calls degrade gracefully via `logger.fault` plus a graceful `.reject(reason: "concurrent_decide")` return. No `assertionFailure`, no trap: debug and release behave identically, and `os_log .fault` lands the violation in Console.app and any SIEM ingesting `os_log` without taking the app down. This is the "no single points of failure" principle applied to a UI coordinator.

Two byte-pump corrections worth surfacing because they are silent regressions that only show under lab load:

- The SwiftTerm `feed(_:)` path was originally `Task { @MainActor in view.feed(buffer:) }` per chunk. This (a) starved the run loop on bursty server output and (b) relied on a FIFO ordering guarantee Swift's concurrency runtime does not promise for unstructured `Task` dispatches. Slice 5 reshapes `feed(_:)` to a single-flight coalesce: bytes are appended to a pending buffer under the lock, exactly one MainActor drain hop is scheduled per burst, and subsequent appends piggy-back. The pattern mirrors `SessionLogWriter.drainQueue` and is the same shape that closed the slice-4 actor-ordering issue. The lesson: when an EventLoop-side hot path needs to deliver into a main-actor consumer, the single-flight queue-and-drain pattern is the right primitive; per-event `Task` dispatch is a latent ordering hazard.
- The mismatch sheet's `.sheet(item:)` attachment was missing `.interactiveDismissDisabled()`. iOS swipe-down and macOS unintended dismissal would silently drop the operator into the 90-second decision timeout. The decision sheet now requires one of the three explicit buttons or a parent-task cancellation (which surfaces as `.reject(reason: "cancelled")` immediately rather than holding for the timeout).

Implementation guardrails carried forward from Slice 5:

- The `host.mismatch.accepted` and `host.mismatch.forgotten` warning emissions are always positioned **before** the trust-store mutation, so the intent is in the audit record whether or not the commit succeeds. The failure-path emission is a distinct sub-event so a SIEM rule keyed on the intent can fire cleanly without false-matching the failure record.
- The `HostKeyMismatchCoordinator`'s `ResumeBox` supports late-attach: the cancellation handler in `withTaskCancellationHandler` can fire before the `withCheckedContinuation` body has finished setting up the continuation, and the resume decision is parked in `deferredDecision` for the attach to deliver. Without this, a tight race between view dismissal and continuation setup would lose the resume entirely.
- Test observability for `PulseTerminalSurface.feed(_:)` coalesce is exposed via `pendingByteCount`, `isDrainHopScheduled`, and `consumePendingBytes()`. These are visible to `@testable import Pulse` only; production code does not call them. Pattern matches the resize-handler observability already in the surface (the test sets `resizeHandler` to capture forwarded sizes).

## Slice 6 amendments summary

Slice 6 (operator-facing terminal UX polish: bell handler, scroll-to-bottom-on-input, font-size adjust, recording-status indicator) lands four operator-visible behaviours on top of the Slice 5 SwiftTerm surface. None of the four introduces a new audit event or a new SSH-layer seam; the recording indicator binds to existing session-lifecycle events through the multicast exit-handler seam established in Slice 5. Four structural notes worth recording so future maintainers do not re-derive the trade-offs:

- **§6 recording-status indicator via the multicast seam** — `SSHTerminalView` registers a third `SSHSession.addExitHandler` callback in `runConnectionLifecycle` (alongside the audit emitter from `SSHClient.connect` and the lifecycle-wrapper's continuation-resume handler). The third handler flips a view-level `isRecording` flag off on `signalExit`; the indicator shows iff the active credential's `recordSessions` flag is true *and* `status == .connected` — the conjunction guard collapses the one-render-pass window between `signalExit` firing the indicator-off task and the lifecycle setting `status = .disconnected(...)` where both states would otherwise coexist. The registration is factored into a `SSHTerminalView.registerRecordingLifecycle(register:onChange:)` static helper that takes a function-typed registrar so the bool-flip contract is testable against a stub registrar without standing up an `EmbeddedChannel`-backed `SSHSession`. *Alternative considered:* widen `SSHSession.setOutputHandler` to a multiplexer or add a recording-status callback channel. Rejected to preserve the byte pump's consumer-agnostic posture (structural gate `grep -n "SessionLogWriter\|RecordingTap" Pulse/SSH/SSHSession.swift` still returns empty). *Known limitation:* mid-session recording failure transitions `SessionLogWriter` to `.recordingStopped` but the view-level indicator stays on (audit log carries the truth via `session.recording.failed`). Tightening this would require widening the consumer API; the trade-off was accepted for v1.
- **§9 bell handler seam** — `PulseTerminalSurface` grew a `bellHandler: (@Sendable () -> Void)?` slot and a `fireBell()` method shaped like the existing `sendHandler` / `resizeHandler` lock-backed pair. `PulseTerminalAdapter.Coordinator.bell(source:)` (the previously-defaulted `TerminalViewDelegate` method) now calls `surface.fireBell()`. The operator view's wiring closure reads `pulse.terminal.bell.audible` and `pulse.terminal.bell.visual` from `UserDefaults` *at fire time* rather than capturing the `@AppStorage` values *at wiring time*, so an operator toggling either preference mid-session takes effect on the next bell without a reconnect. Audio and flash are both routed through a single `@MainActor` `TerminalBellController` (an `ObservableObject` reference) rather than the view struct's `@State` so the `@Sendable` closure can drive both axes without the awkward `@State` capture under Swift 6 strict concurrency. The controller gates the audible bell on a 250 ms sliding window (capping the audible rate at ~4 Hz so a server BEL loop produces a recognisable beep cadence rather than a continuous tone or a queue of `NSSound.beep()` calls); the visual flash coalesces naturally via the controller's cancel-and-reschedule, so no separate gate is needed there.
- **§9 scroll-to-bottom-on-input** — `PulseTerminalAdapter.Coordinator.send(source:data:)` checks `source.scrollPosition < 1.0` and calls `source.scroll(toPosition: 1.0)` before forwarding the keystroke to the surface's `forwardKeystrokes`. SwiftTerm 1.12.0 exposes both APIs publicly on `TerminalView` (`Apple/AppleTerminalView.swift:1790` and `:1818`); the delegate dispatch runs on the main thread so direct view access is safe. The per-keystroke comparison is cheap and the scroll call is a no-op when already at bottom, so the per-press cost is negligible.
- **§9 font-size global @AppStorage** — `PulseTerminalAdapter` reads `pulse.terminal.fontSize` (default 12 pt, clamped 9–24 pt) and applies it through SwiftTerm's `TerminalView.font` setter on every `updateNSView` / `updateUIView` invocation. SwiftUI re-invokes the update method on `UserDefaults`-key changes, so the macOS hidden-button keyboard shortcuts (Cmd-+, Cmd-=, Cmd--, Cmd-0) and the iOS `UIPinchGestureRecognizer` on the Coordinator both write through the same key and converge on the same apply path. Font preference is global rather than per-credential or per-device because it is a personal-environment setting (matches Terminal.app, iTerm, Ghostty). *Operator override without a Settings UI:* the v1 build ships without a settings pane for bell or font; operators can override via `defaults write nz.net.omega.pulse pulse.terminal.bell.audible -bool false` or similar. A future Settings → SSH "Terminal preferences" sub-pane will surface the toggles without migrating storage.

No audit-event additions. Bell / font / scroll are local UI; the recording indicator binds to existing session-lifecycle events (so §7's event catalogue at lines 125–143 needs no edit). Structural gates from Slice 5 remain clean; one Slice-6-specific gate (`grep -rn "fireBell\|bellHandler" Pulse/SSH` returning empty) confirms the bell wiring stays out of the SSH layer.

Two lab gates carried over from Slice 5 closed in this slice:

- **Host-key mismatch flow lab pass.** Procedure documented in `docs/credentials.md` under the existing Host-key mismatch section as a `**Lab procedure.**` block. Walks all three operator actions plus the 90-second decision timeout plus the cancellation path, confirming audit-event token names and reason fields match the contract.
- **Recording stack round-trip with SwiftTerm consumer.** Procedure documented in `docs/credentials.md` under the existing Session recording section as a `**Lab procedure.**` block. Confirms `.pulselog` + `.meta` on disk under the right path scheme, biometric-gated replay, and chain-break detection on tampered file.

## Slice 7 amendments summary

Slice 7 (pre-connect form) closes the §4 `SSHConnectSheet per-session override field` non-negotiable that the production path skipped. Until this slice, the device-row right-click → SSH flow auto-fired the lifecycle with `Device.defaultUsername ?? NSUserName()` and `Device.defaultCredentialID ?? nil`, both of which were `nil` for every device in production because no UI existed to write either field — the only write-path anywhere was `SSHCredentialsSettings.swift` nulling `defaultCredentialID` on credential delete. Operators saw a window that failed instantly with no recovery path. Four structural notes worth recording so future maintainers do not re-derive the trade-offs:

- **§4 `SSHConnectSheet` closes as an inline form.** `SSHConnectForm.swift` lives in `Pulse/Views/Terminal/` and renders inline inside `SSHTerminalView.terminalArea` at the `.idle` and `.failed` states. Sheet was considered and rejected: on macOS `.sheet` reads as modal escalation, but connection setup is not destructive (the device on the other side is untouched until bytes flow), so a modal would mis-signal the affordance. Inline composes with the existing `.idle` → `.connecting` → `.connected` state machine and gives `.failed` a natural retry path — the same form re-renders with an error banner above it. The form's `canConnect` static helper is the structural enforcement of "operator must think" before connecting (non-empty trimmed username, non-nil credential, non-empty primary IP); the test suite pins the boundary cases.
- **§6 connection-attempt nonce as the new lifecycle seam.** `SSHTerminalView` grew a `ConnectionAttempt` nested struct (`nonce: UUID`, `username: String`, `credentialID: UUID`) and a `.task(id: connectionAttempt)` modifier. `runConnectionLifecycle` changed from `() async` to `(attempt: ConnectionAttempt) async` — it now reads username and credential from the captured snapshot rather than from mutable view state. The nonce lets a repeated Connect-click with identical username + credential still re-fire the lifecycle (Hashable identity changes when the UUID changes). *Alternative considered:* drive the lifecycle from a plain `Bool` "connect-requested" flag flipped by the form. Rejected because the captured snapshot is the testable seam — Slice 8 and beyond can drive `runConnectionLifecycle` against synthesised attempts without standing up SwiftUI. The state-machine refactor also removed `selectedCredentialID` and `activeCredentialID` entirely: the form is now the single source of truth for pre-connect choices, which eliminates an entire class of state-divergence bug.
- **§9 auto-fire-on-appear gating preserves muscle memory without sacrificing the form.** `SSHTerminalView.autoFireAttempt` synthesises an attempt at view appear iff (a) device mode and both `Device.defaultUsername` and `Device.defaultCredentialID` are set *and* the credential exists in the local store, or (b) ad-hoc mode (the upstream debug surface already gathered the inputs). After `.failed`, the form always renders — no auto-fire on retry. The credential-exists guard is the defence-in-depth check against a stale `defaultCredentialID` pointer (the Slice 1-3 path that null-cleans on credential delete is the primary protection; this guard catches the race where the credential is deleted while the window is open). Username and credential storage write-paths for the device-defaults UI are deferred to Slice 8 — Slice 7 makes the form work; Slice 8 makes the form's choices stick.
- **§7 no new audit events.** The form is pre-connection lifecycle stage; no SSH-layer state is touched, no `ssh.*` events fire from form interaction. The lifecycle's existing `session.open` / `auth.success` / `host.pinned` etc. continue to fire once the operator clicks Connect — the audit trail starts at the same point it always did, but is now preceded by an explicit operator intent rather than an auto-fire-with-garbage-defaults race.

Two implementation guardrails worth surfacing for the next slice:

- **Form initialization runs in `.onAppear`, not `.task(id: connection)`.** The setup body is synchronous (`initializeFormFromDefaults` + `autoFireAttempt` are both pure) and `.onAppear` keeps the structural gate `grep -rn "\.task(id: connection)" Pulse/Views/Terminal` empty. The `connection` identity is set at view init and does not change for the view's lifetime (`WindowGroup` per-`Device.ID` semantics), so the re-fire-on-id-change semantics of `.task(id:)` were never needed for the setup path.
- **`autoFireAttempt` takes raw fields, not a `Device`.** Signature is `(connection:, deviceDefaultUsername:, deviceDefaultCredentialID:, knownCredentialIDs:)`. Testable without standing up a SwiftData container or constructing a `Device`. The call site at `.onAppear` does the field extraction (`device?.defaultUsername`, `device?.defaultCredentialID`, `Set(credentials.map { $0.id })`); the helper is pure and SwiftUI-free.

## Slice 8 amendments summary

Slice 8 (device-defaults persistence) closes the gap Slice 7 explicitly deferred: until this slice, no code path anywhere in Pulse wrote `Device.defaultUsername` or `Device.defaultCredentialID`, so every device-row connect rendered the form on every open and the auto-fire path was effectively dead in production. Slice 8 adds an explicit-opt-in checkbox to the connect form, a post-`.connected` persistence site, and a symmetric "Clear saved defaults" gesture. Five structural notes worth recording so future maintainers do not re-derive the trade-offs:

- **§4 `ConnectionAttempt` grows `saveAsDefault: Bool`.** Captured into the attempt at Connect-click via the form's `@Binding`; auto-fire-on-appear synthesises attempts with `saveAsDefault: false` unconditionally. The field participates in `Hashable` identity for **structural-property correctness** rather than because production code paths would otherwise miss a re-fire — `submitConnectionAttempt` mints a fresh `UUID` nonce per click, which already invalidates identity. The type-level statement is "two attempts differing only by persistence intent are distinct attempts"; the test `testConnectionAttemptIdentityIncludesSaveAsDefault` pins this. The framing matters because the obvious-but-incorrect reading ("the nonce already handles re-fire, so why include the bool?") would have pointed at a redundant field; the corrected framing is that the type's identity should reflect the operator's full intent, of which persistence is part.
- **§4 persistence site is post-`.connected`, not post-Connect-click.** `runConnectionLifecycle` reaches the write site **after** `status = .connected`, so all `.failed` branches above it return without persisting. This is the structural mechanism by which "failed attempts persist nothing" holds regardless of what the operator ticked on the form. The corresponding test (`testApplyDeviceDefaultsIfRequestedSkipsWriteWhenOptedOut`) pins the helper's contract on `saveAsDefault: false`; the call-site structural pin is a grep gate that the call line is preceded within two lines by `status = .connected`. Two pure `@MainActor` static helpers (`applyDeviceDefaultsIfRequested(attempt:, device:)` and `clearDeviceDefaults(device:)`) hold the contracts for direct unit-test exposure against a synthetic `Device(id:)`, without standing up a SwiftData container or driving the real SSH lifecycle.
- **§4 explicit-opt-in posture over silent-persist-on-every-success.** Considered and rejected: writing the defaults on every successful connect with no checkbox. Rejected because shared/jumphost credentials in multi-operator teams would silently stomp another operator's defaults on autopilot. The one extra click per "make this the default" is the right trade against that failure mode. The form's checkbox renders only in device mode; ad-hoc connections never persist (no Device row to persist to), and the form structurally hides the checkbox in that path so the affordance composes cleanly with the existing ad-hoc surface in Debug.
- **§4 save-failure-is-non-fatal — deliberate decision.** A `modelContext.save()` failure on the persistence path logs at category `ssh.session` and continues. The operator's session is not interrupted, the audit log carries the error for SIEM ingestion and post-hoc diagnosis, and the operator may (silently) re-tick on the next open expecting the previous save to have stuck. The trade-off is recorded here rather than re-derived: surfacing the save error to a sheet would interrupt a working terminal over a metadata-persistence concern, which inverts the priority of "operator's session" over "defaults are perfect". A future slice may add a non-blocking surface (banner reset, status-bar hint) if operators surface the gap; the v1 posture is audit-log-only and is the correct trade.
- **§4 symmetry at the credential-delete cleanup (resolved).** The credential-delete cleanup nils both `Device.defaultCredentialID` and `Device.defaultUsername` in the same transaction, matching the symmetry contract held by `SSHTerminalView.clearDeviceDefaults`. Slice 8 originally shipped the cleanup niling only `defaultCredentialID`, leaving `defaultUsername` set; a device in that half-cleared state still fell back to the form on next open (the auto-fire gate requires both fields), so it was recoverable, and the form's "Clear saved defaults" button was the operator's escape hatch. A follow-up nilled both fields at the cleanup site, closing the asymmetry; the in-line comments at the cleanup site and the `clearDeviceDefaults` doc-comment now describe the both-fields contract.

Two structural gates carried forward into Slice 8 verification:

- `grep -rn "saveAsDefault: true" Pulse/Views/Terminal/SSHTerminalView.swift` — only `submitConnectionAttempt` (the form-driven path). `autoFireAttempt` and any future synthesised attempts must opt out, pinning the no-silent-persistence contract.
- Persistence-call-site pin: an awk over `Pulse/Views/Terminal/SSHTerminalView.swift` confirming the `status = .connected` assignment (the line, not a doc-comment mention) precedes the `applyDeviceDefaultsIfRequested(attempt:` call line. The intervening lines may carry a doc-comment block describing the non-fatal-save decision; the structural property is "assignment before call", not "assignment immediately before call":

  ```bash
  awk '/^        status = \.connected$/{a=NR} \
       /^            if Self\.applyDeviceDefaultsIfRequested\(attempt:/{b=NR} \
       END{exit (a && b && a<b) ? 0 : 1}' \
    Pulse/Views/Terminal/SSHTerminalView.swift
  ```

Explicit deletions from Slice 8 scope (recorded so a future slice does not re-derive them):

- Settings → Devices → … → SSH editor pane. The form checkbox is sufficient; a dedicated editor pane would duplicate the persistence path.
- Debug-only defaults seeder. Obsolete the day this slice lands.
- "Currently saved as default" status chip on the form. The form only renders when defaults are absent or the previous connection failed; a chip would be misleading.
- Operator-facing surfacing of save() failure beyond the audit log. Deferred per the non-fatal decision above.
- Screen-recording prevention (queued separately).
- The cosmetic `recording-badge && status == .connected` gating. Cosmetic; the existing conjunction guard is sufficient.

## Slice 8a routing-disambiguation note

Slice 8a (proper terminal window) surfaced a routing collision worth recording so future scenes do not re-derive the trap: `Device.ID` and `Site.ID` both resolve to `Int64` (the default `Identifiable.ID` for `@Model` classes whose `id: Int64`), and SwiftUI's `WindowGroup(for:)` keys on the Swift type rather than the textual declaration. Two `WindowGroup(for: Int64.self)` registrations collide, and `openWindow(value: someInt64)` matches by **registration order**, not by intent — Site View registered before SSHTerminalScene in `PulseApp.body`, so device-targeted `openWindow(value: device.id)` calls from `DeviceRow` silently mis-routed into Site View with the device's id as a stale "siteId" that resolved to no Site row. The window rendered Site View's chrome around an empty content slot; the title bar fell back to "Unknown".

The fix is symmetric: every `WindowGroup(for: Int64.self)` scene gets an explicit `id:`, and every `openWindow` call site passes the matching `id:`. SwiftUI's `openWindow(id:value:)` targets the named scene exactly, regardless of value-type collisions. SSHTerminalScene gets `id: "ssh-terminal"`; the Site View scene in `PulseApp.swift` gets `id: "site-view"`. Three call sites updated: `DeviceRow.swift`, `SiteGraphView.swift`, `AnnotationView.swift`.

Asymmetric (only SSH gets an id) was considered and rejected: it trades a routing-order bug for a registration-order fragility, where any future scene addition silently re-routes the un-id'd calls. The cost of the symmetric fix is three extra single-line edits; the benefit is that registration order in `PulseApp.body` becomes irrelevant to correctness.

**Window chrome contract (macOS).** `SSHTerminalScene` chains `.windowResizability(.contentSize)` (the existing `.frame(minWidth: 720, minHeight: 420)` on `SSHTerminalView` becomes the enforced window minimum; 720x420 is deliberately oversized vs the 80x24 cell grid at default font to give the recording-state toolbar item breathing room) and `.windowToolbarStyle(.unifiedCompact(showsTitle: true))` (title sits inline with toolbar items, matching Terminal.app and iTerm). Both modifiers are macOS-only; iOS scene wiring (deferred) inherits the `.toolbar` declaration on the view body.

**Operator-facing window contract** (pinned here because the toolbar copy is part of the contract):

| `ConnectionStatus` | Status pill copy | Toolbar primary action |
|---|---|---|
| `.idle` | (pill hidden) | (button hidden) |
| `.connecting` | Connecting | (button hidden) |
| `.connected` | Connected | Disconnect |
| `.disconnected` | Disconnected | Reconnect |
| `.failed` | Failed | Reconnect |

Each toolbar item carries an explicit `ToolbarItem(id:)` (`status-pill`, `recording-badge`, `primary-action`) so SwiftUI's toolbar diffing animates the label changes (Disconnect → Reconnect on disconnect) rather than reflowing surrounding items. The toolbar Reconnect button and the in-view Close button at `.disconnected` are **deliberate complements**: toolbar offers session restart against the captured form values via `submitConnectionAttempt` (which mints a fresh nonce; the previous lifecycle's `defer { client.close() }` already nil'd `sshClient`, so the new attempt builds a fresh client cleanly), in-view offers window-close. Removing either is a behavioural regression.

The recording badge moves out of the in-view status bar into the window toolbar where session-state indicators conventionally live (matches Terminal.app, iTerm). The in-view status bar shrinks to the device name plus the long-form status description ("Connecting to 192.0.2.1:22…") that the space-constrained toolbar pill cannot carry; the colored status dot lives in the toolbar pill, not the in-view bar.

**Structural gates** (positive shape, fail loudly when a new call site forgets the id):

```bash
grep -rn 'openWindow.*device\.id' Pulse | grep -v 'id: "ssh-terminal"'
grep -rn 'openWindow.*site\.id\|openWindow.*siteId' Pulse | grep -v 'id: "site-view"'
```

Both must return empty (modulo doc-comment text).

## Slice 8b amendments summary

Slice 8b closes the structural follow-up reserved by Slice 8a. `Device.ID` and `Site.ID` both resolve to `Int64`, so the two id-addressed `WindowGroup`s were distinguished only by their `id:` strings: a runtime discipline a future scene could silently break. This slice keys each scene on a distinct nominal value type so a misroute is a compile error. It hardens working code; Slice 8a already removed the live mis-route, so there is no behavioural bug here to fix. Three structural notes worth recording so future maintainers do not re-derive the trade-offs:

- **§9 nominal window-routing value types.** `DeviceWindowTarget { let deviceID: Device.ID }` and `SiteWindowTarget { let siteID: Site.ID }` (both `Hashable & Codable`) replace the raw `Int64` `WindowGroup(for:)` value types. `WindowGroup(for:)` requires `Hashable & Codable`, which the structs satisfy exactly as `Int64` did; the win is that `openWindow(value: someDeviceTarget)` against the Site View scene no longer type-checks. Both structs live in `SSHTerminalWindow.swift` rather than their own files: they are routing envelopes for the app's two id-addressed scenes, not domain types, and co-locating avoids two new `.pbxproj` registrations for ten lines of code. *Alternative considered:* keep the Slice 8a `id:`-string discipline. Rejected because it is a review-time gate, not a compiler-enforced one; the nominal types make the next scene addition fail loudly at build time.
- **§9 `id:` strings retained.** The `id: "ssh-terminal"` / `id: "site-view"` arguments stay even though the distinct value types now carry the routing guarantee. They remain the SwiftUI state-restoration identity and a second line of defence against a future `Int64`-keyed scene. Removing them would churn restoration storage for no structural gain.
- **One-time state-restoration reset.** Changing the `WindowGroup` value type from `Int64` to the target structs means SwiftUI's persisted window state from a prior build no longer decodes; restored terminal and Site View windows are discarded once on the first launch after the upgrade and reopen fresh thereafter. This is operator-visible, so it is also called out in the release notes, not only here. The `Codable` round-trip is pinned by `testDeviceWindowTargetCodableRoundTrip` / `testSiteWindowTargetCodableRoundTrip` in `SSHConnectFormTests` so a future change that breaks the conformance, which would silently drop every restored window, trips a test instead.

Structural gates (the Slice 8a `openWindow.*device\.id` call-site greps are superseded; the value type, not the call-site id, is now the guarantee). The first grep was deliberately chosen to fire: it returns the three real registrations before this slice and empty after, where the obvious `WindowGroup(for: Int64` grep would have matched only doc comments and passed vacuously both ways.

```bash
# No scene keys a WindowGroup on the raw model id; all three key on a target struct.
grep -rEn 'WindowGroup\(".*for: (Device|Site)\.ID\.self\) \{' Pulse --include="*.swift"                       # empty
grep -rEn 'WindowGroup\(".*for: (DeviceWindowTarget|SiteWindowTarget)\.self\) \{' Pulse --include="*.swift"   # 3
# No openWindow call site passes a raw id (anchored to leading whitespace so doc comments cannot false-match).
grep -rEn '^[[:space:]]*openWindow\(.*value: (device\.id|site\.id|siteId)' Pulse --include="*.swift"           # empty
```

The §4 and §9 §-body "as-built" pointers added in the docs-currency pass reconcile here: §9 points to the Slice 8a note for the id-addressed step and to this section for the nominal-struct hardening.

## Slice 8c note — chrome trim, decomposition, click-to-update fix

Slice 8c lands three changes on top of the Slice 8a window:

**Click-to-update root cause.** Slice 8a's `.windowToolbarStyle(.unifiedCompact(showsTitle: true))` reintroduced a regression originally fixed by commit `cbf1797` (which switched `PulseTerminalAdapter.drainPendingFeed` from SwiftTerm's engine-level `Terminal.feed(buffer:)` to the view-level `TerminalView.feed(byteArray:)` so `feedFinish() → queuePendingDisplay()` schedules an AppKit redraw cycle). Symptom: server output stops repainting until the operator clicks in the window. Diagnosis: `PulseTerminalAdapter.swift:192` still has the load-bearing view-level call; both production and debug entry paths instantiate the same `SSHTerminalView` with identical lifecycle wiring; the debug scene carries no `.windowToolbarStyle` modifier and does not exhibit the symptom. The unified-compact style interferes with `setNeedsDisplay` propagation — likely a responder-chain or layer-tree interaction specific to that style. **Remediation**: switch to `.windowToolbarStyle(.unified(showsTitle: true))`, which preserves the inline-title chrome at slightly taller height without the rendering interference. **Diagnostic tooling**: three `#if DEBUG` `Logger` calls now sit at the render-path boundary on category `ssh.render` — `drainPendingFeed` (byte count + view-attachment state), `makeNSView`/`makeUIView` (fresh TerminalView construction), and `updateNSView`/`updateUIView` (reconciliation). Capture with `log stream --predicate 'subsystem == "pulse" AND category == "ssh.render"'`. Three signatures pick a future fix shape: drained-without-update (display-scheduling regression), repeated makeNSView (identity churn from `body` re-evaluation), or no-drain (MainActor hop deferred). Release builds compile the loggers out entirely.

**Chrome trim — `connectionEndpointStrip` replaces in-view `statusBar`.** Slice 8a's in-view status bar duplicated information surfaced by the toolbar (device name in the navigationTitle, status word in the status pill). Naive removal would have lost the operator-visible host string entirely — the toolbar promotes name and status word but not the resolved host. This slice **trims** rather than removes: a single-line monospaced caption `connectionEndpointStrip` shows `host:port` at `.connected` only, empty elsewhere. Closes two session-pinning threats the device-name-alone surface cannot:

- **Mistaken-target keystrokes.** Two terminals open to similarly-named devices (template-deployed NetBox sites produce names like `OMG-0001-01-SR01` and `OMG-0002-01-SR01`); operator Cmd-Tabs and types a destructive command into the wrong shell. The host string is the structural "where am I typing" check; the device name alone is not sufficient under naming-collision conditions.
- **Mid-session re-IP.** A NetBox sync mutates `Device.primaryIP` while the session is connected; the endpoint strip shows the actual connected host (resolved at connect time), giving the operator visible evidence the row and the session have diverged.

The accessibility label spells out "Connected endpoint: \(host) port \(port)" so VoiceOver readers get the same signal.

**Decomposition per Omega Swift conventions.** Two structural moves:

- `TerminalBellController` (an `@MainActor ObservableObject`) and the `fireAudibleBell()` free function moved out of `SSHTerminalView.swift` into a new `Pulse/Views/Terminal/TerminalBellController.swift`. One-type-per-file per the `omega-swift-agent` skill's guidance; the controller's lifecycle is independent and it's referenced from one place (the view's `@StateObject`).
- The inline `.toolbar { ... }` block on `body` moved into a named `@ToolbarContentBuilder private var sshTerminalToolbar: some ToolbarContent`. `body` shrinks to a clean composition; the toolbar's three explicit `ToolbarItem(id:)` declarations are now grouped under one named seam rather than scattered across the body's modifier chain.

`runConnectionLifecycle` and the `ConnectionStatus` / `ConnectionAttempt` / `Connection` nested types stayed in place: the lifecycle's `@State` capture footprint is too wide for clean extraction, and the nested enums are tightly typed view-contract surfaces that gain nothing from breaking out. A future slice may introduce an `SSHTerminalConnectionViewModel: ObservableObject` to own the lifecycle and unlock both extraction and independent testability.

**New test seams.** `SSHTerminalView.statusPillCopy(for: ConnectionStatus) -> String` and `SSHTerminalView.primaryActionShape(for: ConnectionStatus) -> PrimaryActionShape?` extracted as `static func`s. Both are pure mappings over the connection status; both are pinned by unit tests in `SSHConnectFormTests` (under the new "Toolbar contract" MARK section) covering all five `ConnectionStatus` cases. Matches the test-seam pattern established by `autoFireAttempt` (Slice 7) and `applyDeviceDefaultsIfRequested` / `clearDeviceDefaults` (Slice 8). `PrimaryActionShape` is a new local enum (`.disconnect`, `.reconnect`) consumed by `primaryActionButton`'s switch.

**Reconnect-button form re-render — flagged for follow-up.** The `Reconnect` toolbar button calls `submitConnectionAttempt()` directly, re-using the captured form values from the prior attempt. If the operator added a credential during the disconnect interval, the picker would have surfaced it only on a form re-render — but Reconnect bypasses the form. Probably correct (operator memory holds the previous selection), but worth a follow-up if operators report confusion.

## Web companion Slice W1 amendments summary

Slice W1 (`feat/web-companion-service-sync`) builds the data foundation the v1.5 Web companion needs, and nothing else: it syncs NetBox Application Services (`GET /api/ipam/services/`) into a new `Service` `@Model`, with no UI. It converts none of the §9 "Device Web" sketch into as-built (that is Slice W2, when the `WebView` window ships); it consumes none of the §8 `PulseTransport` / `pulse-tunnel://` seam (the deferred tunnelled path). The structural decisions worth recording so a future maintainer does not re-derive them:

- **§9 connection targets come from Application Services, not `Device.primaryIP`.** The Web companion derives what to connect to from a device's NetBox services (protocol, ports, IPs), not a hardcoded URL or the device's bare primary IP. W1 lands only the data; the "which service is web" rule, scheme/port selection, and URL derivation belong to W2 and are deliberately absent from the data layer so the foundation makes no UI assumption. `Service.primaryIPAddress` (the CIDR-stripping helper, mirroring `Device.primaryIPAddress`) is the one forward affordance left for W2's URL builder.

- **`Service` parent linkage is migration-proof by construction.** A NetBox service is parented to either a `dcim.device` or a `virtualization.virtualmachine`, and Pulse has no VM `@Model`. Rather than drop VM-parented services, the schema stores the parent generically (`parentObjectType` / `parentObjectId` / `parentName`) and wires a real `device` relationship only when `parentObjectType == "dcim.device"`. VM-parented services persist at full fidelity with `device == nil`: retained, not dropped. When a `VirtualMachine` model later arrives, adding a `virtualMachine` relationship alongside is an additive SwiftData change that needs no `VersionedSchema` / `MigrationPlan`, and the generic fields mean no backfill. This is the do-it-properly-from-the-beginning schema decision; the documented gap is that VM parents carry no typed relationship until the VM model lands.

- **Decoder posture diverges from `DeviceProperties` on purpose.** `ServiceProperties.init(from:)` reads nested objects with `try?` throughout (never the `try!` that `DeviceProperties` uses, which would crash on an omitted nested field), and does not require `created` / `last_updated`: the services payload carries no timestamps, so requiring them as the device decoder does would reject every record. It throws `SwiftDataError.missingData` only for the fields without which a service cannot be wired or surfaced (`id`, `name`, `parent_object_type`, `parent_object_id`). `ports` is stored as `[Int]` and the CIDR addresses as `[String]`: SwiftData persists both directly as Codable attributes, so no child models are introduced for data only ever read as "the ports and IPs of this service".

- **`getServices()` runs after `getDevices()` and degrades gracefully.** Relationship wiring reads the `Device` table, so the sync sequence in `PulseApp.verifyContainer` places Services immediately after Devices (and bumps `InitializationState.totalSteps` to keep the progress bar filling to 100%). If a parent device has not synced yet, the service stores unlinked and re-links on the next sync, so an ordering error degrades rather than crashes. Stale-delete (existing ids minus server ids) mirrors `getDevices`; no sync-time protocol filter is applied, so UDP services (DNS, SNMP) are retained for whatever surface later needs them.

**Verification posture.** `ServicePropertiesDecodingTests` (XCTest) locks the decoder against the representative `/api/ipam/services/` payload (nested `protocol`, top-level `ports`, the `ipaddresses` array, the flat parent fields, the VM-retain invariant, and the `Wrapper<ServiceProperties>` page shape), entirely headless. The live round trip (`getServices()` fetching, upserting, stale-deleting, and wiring `device` relationships against a populated services endpoint, including pagination beyond 1000) needs a configured NetBox instance and is an integration check, not a headless one. W1 has no UI surface, so nothing in it requires a device.

## Web companion Slice W2a amendments summary

Slice W2a (`feat/web-companion-w2a-tls-trust`) builds the headless TLS-trust foundation the v1.5 Web companion needs: a per-host trust store, a pure trust evaluator, a certificate fingerprinter, the source-of-truth web-service resolver, and the operator trust-prompt sheet and coordinator. No `WebView` yet (that is Slice W2b). The decisions worth recording:

- **The §9 server-trust spike is resolved.** The shipping macOS 26 WebKit interface exposes `WebPage.NavigationDeciding.decideAuthenticationChallengeDisposition(for: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?)` plus `WebPage.serverTrust: SecTrust?` and `decidePolicy(for: NavigationAction...)`. This was the load-bearing unknown for the whole Web companion: it means a self-signed appliance certificate can be accepted per-host without disabling TLS globally. W2 is feasible as designed.

- **TLS trust reuses `HostTrust` in a separate `WebHostTrust` model.** The §5 polymorphic `HostTrust` enum is reused verbatim (a `.pinned` case carries the certificate SHA-256 fingerprint and key algorithm). The record lives in a new `WebHostTrust` `@Model` keyed on `(host, port)`, distinct from `KnownHost`, so a device's TLS-cert trust and its SSH host-key trust are independently forgettable and a port-22 SSH pin is never consulted for an HTTPS connection. Registered in the `ModelContainer` schema.

- **Standard validation first; TOFU only on failure.** The trust policy validates against the system trust store first: a certificate that chains to a trusted root loads silently with no prompt and no pin. Only on validation failure (self-signed, untrusted, expired, name mismatch) does the operator-acknowledged trust-on-first-use path engage: unknown host prompts on first sight (accept pins the certificate), a matching pin loads silently, a changed pin prompts with the stored-versus-presented comparison, and an explicit distrust is a hard reject that wins over system trust. The pure `WebHostTrustEvaluator.evaluate` holds this and is unit-tested branch by branch.

- **The web-service rule is NetBox as the source of truth.** `WebServiceResolver` derives the scheme from the NetBox service name (a TCP service whose name announces `HTTPS` opens `https`, `HTTP` opens `http`) and the port from that same service's declared `ports`. It does not guess a scheme from a hardcoded port map. A device whose web UI is missing here is a NetBox data-definition fix, not a Pulse heuristic, which keeps Pulse a faithful window onto the source of truth. Multiple web services order https-before-http then lowest-port; the W2b window adds an operator picker.

- **The trust prompt clones the SSH host-key flow.** `TLSTrustCoordinator` and `TLSTrustPromptSheet` mirror `HostKeyMismatchCoordinator` and `HostKeyMismatchSheet`: a lock-protected `ResumeBox` single-resume, a 90-second decision timeout (reject reason `decision_timeout`), the concurrent-decide degrade, external cancellation, and `defaultFocus = .reject` (a stray Return must never extend trust, pinned by a test). Deliberately duplicated rather than generified so the shipped SSH path is untouched; a later refactor may extract a shared trust-prompt component.

- **Audit and the window are deferred to W2b.** `WebAudit` (categories `web.trust` and `web.session`) and the navigation decider that emits it ship with the `WebView` window in W2b, where there is an emitter to exercise them. W2a's coordinator logs its own `web.trust.concurrent_decide` fault inline, mirroring the SSH coordinator.

**Verification posture.** W2a is fully headless: `xcodebuild build` (macOS + iOS) compiles the new model, the schema, the store, the evaluator, the inspector, the resolver, the coordinator, and the sheet; `WebTrustFoundationTests` and `TLSTrustCoordinatorTests` cover the resolver rule, the evaluator branches, the certificate fingerprint against an independently-computed SHA-256, store idempotency, the coordinator timeout and resume, and the sheet default-focus. There is no on-device gate in W2a; the page-renders, prompt-fires, and navigation-contained gates belong to W2b.

## Web companion Slice W2b amendments summary

Slice W2b (`feat/web-companion-w2b-window`) ships the on-device Device Web window that consumes the W2a trust foundation, converting the §9 sketch into as-built. The decisions worth recording:

- **The window and view mirror the SSH terminal.** `DeviceWebScene` (`WindowGroup("Device Web", id: "device-web", for: Device.ID.self)`) mirrors `SSHTerminalScene`, registered in `PulseApp.swift` after it, with the same string-`id:` routing discipline (the SSH and Site scenes also key on `Int64`; see the Slice 8a note). `DeviceWebView` mirrors `SSHTerminalView`: a `@Query` device-by-id, a `WebView(page)` driven by a `@State WebPage` built in `.task`, a toolbar bound to the page's `@Observable` `title` / `estimatedProgress` / `isLoading` / `backForwardList`, and a `WebLoadStatus` pure helper for the status label.

- **The navigation decider is a `@MainActor final class`.** `WebPage.NavigationDeciding`'s methods are `@MainActor mutating`, so a class satisfies the `mutating` requirement trivially and holds references to the trust coordinator and store for the window's lifetime (no value-type `Box` was needed). `decidePolicy(for action:)` allows same-origin navigation (scheme, host, port, via the pure `WebOrigin`) and hands a foreign origin to the system browser. `decideAuthenticationChallengeDisposition` validates the system trust store first (`SecTrustEvaluateWithError`), then routes a failure through the W2a `WebHostTrustEvaluator` + `TLSTrustCoordinator` + store, returning `(.useCredential, URLCredential(trust:))` only on operator accept.

- **The entry point reflects the source of truth.** Open Web UI is surfaced (in `DeviceRow` and `DeviceView`) only when `WebServiceResolver.primaryTarget(for:)` resolves a NetBox-declared web service, not merely when a primary IP exists. A device with no web service shows no affordance and a typed empty state in the window.

- **`WebAudit` is wired.** The decider emits `web.trust.{system,pinned,accepted,rejected,forgotten}` and `web.session.{opened,navigation_blocked}` under the `pulse` subsystem.

- **The deferred WebPage API surface was verified at build.** `WebView(page)` and the `_WebKit_SwiftUI` cross-import overlay; `WebPage.NavigationEvent` is `startedProvisionalNavigation` / `receivedServerRedirect` / `committed` / `finished` with load errors thrown from the `navigations` sequence; `WebPage.BackForwardList` exposes `backList` / `forwardList` / `currentItem` with `load(item:)` for back and forward; `URLCredential(trust:)` is the accept credential. All compiled clean on macOS and iOS.

- **Post-review hardening (audit fast-follow).** Four refinements landed after an external audit: (1) only `http`/`https` URLs with a host are handed to the system browser, so device-controlled content cannot launch an arbitrary scheme (`file:`, `ssh:`, app schemes) on the operator's Mac; (2) a store read error during challenge evaluation fails closed (cancel plus `web.trust.store_error`), never reading as "no record", so a distrusted host cannot be re-trusted through a transient SwiftData fault; (3) only the window's own origin may raise a trust prompt, so a subresource cannot prompt for a foreign certificate (prompt fatigue / social engineering); and (4) the pin-write decision, recorded deliberately: when the operator accepts but persisting the pin fails, the session proceeds on the one-time credential (the operator approved that exact certificate and the credential is scoped to it) while the audit emits `web.trust.commit_failed`, never `pinned`, so the trail cannot overstate what persisted. Re-prompting on every load over a transient write fault would be worse UX, and the one-time accept is already operator-authorised.

- **`.explicitlyDistrusted` now has a writer.** Settings > Web Trust (`WebTrustSettingsView`) lists pinned and blocked device-web hosts and lets an operator Block one, which records `.explicitlyDistrusted`; the evaluator already honoured it as a hard reject, so a blocked host refuses to load until Unblock/Forget removes the row. A declined first-sight prompt still persists nothing (it cancels that one attempt and re-prompts next visit); only Block records a standing refusal. The settings view reads via `@Query` (the trust table is operator-curated, not device-scale) and writes via the view's model context, emitting the success audit only after the save commits (`web.trust.distrusted` / `web.trust.forgotten`), mirroring the decider's commit-failed discipline.

- **ATS is relaxed for web content only, not the app's data plane.** Appliance web UIs are routinely self-signed, and a host reached by a *public* IP is not covered by `NSAllowsLocalNetworking`, so App Transport Security refused such a certificate with `NSURLErrorServerCertificateUntrusted` (-1202) even after the operator accepted it and the pin matched, observed on a public FortiGate at `:9443` whose certificate is otherwise valid (correct IP SAN, SHA-256 / RSA-4096, in date). The fix is `NSAllowsArbitraryLoadsInWebContent` in `Info.plist`, which scopes the relaxation to `WKWebView` content; the app's own NetBox / Zabbix `URLSession` traffic stays under full ATS. This loosens transport policy, not the trust decision: the server-trust challenge still fires, so the operator trust prompt (`TLSTrustCoordinator`) still gates every untrusted certificate. The local-vs-public distinction, not key size, was the actual differentiator, the RSA-4096 host was simply the public one.

**Verification posture.** Headless: `xcodebuild build` (macOS + iOS) compiles the scene, view, and decider; `DeviceWebTests` covers `WebOrigin` containment and the `WebLoadStatus` mapping. On-device only (left for the human pass, cannot be faked headless): a real device's web UI renders; a trusted certificate loads silently while a self-signed certificate prompts, accept pins and loads, and a changed certificate re-prompts; the navigation decider keeps in-app navigation contained and routes foreign origins to the system browser; the window opens the correct device with no misroute and window-state restoration behaves (a new scene value type may reset saved state once). Operator guide: `docs/web-companion.md`.

## Web companion Slice W2c amendments summary

Slice W2c investigated downloads and new-window / pop-up handling for the Web companion, found both blocked by missing seams in the shipping SwiftUI `WebPage` API, deferred both, and extracted the continuation primitive the trust coordinators duplicated. No new dependency, and no behavioural change to the window itself.

- **New windows / pop-ups are not interceptable on `WebPage`, so they are deferred too.** The plan assumed `WebPage.NavigationDeciding.decidePolicy(for:)` is called for a new-window action (`action.target == nil`) so it could be routed. On-device verification (a probe logging every action) disproved this: same-frame navigations reach the decider, but a `window.open` call does not reach `decidePolicy` at all (only the per-connection server-trust challenge fires, from the auth delegate). There is also no `createWebView` seam to host a new window. So `window.open` pop-ups (appliance consoles such as noVNC, and some "open in new tab" buttons) cannot be intercepted, redirected, or hosted; WebKit drops them internally. A faithful console additionally needs the live `window.open` handle that only a real child window provides, which `WebPage` cannot give. New windows therefore join downloads in the deferred bucket, tracked in [issue #39](https://github.com/Omega-Networks/Pulse/issues/39); the SSH terminal remains the supported interactive-console path. No `web.session.popup_*` events ship, and the decider's same-frame containment is unchanged.

- **`ResumeBox` is now one shared generic.** The single-resume `CheckedContinuation` wrapper was duplicated byte-for-byte in `TLSTrustCoordinator` and `HostKeyMismatchCoordinator` (the second copy was where a dismissible-sheet regression had entered). It is now one `ResumeBox<Decision>` in `Pulse/Concurrency/`, consumed by both; behaviour is unchanged and pinned by the existing coordinator suites. It was scoped as the precursor to a third copy for the deferred download prompt queue; the dedup stands on its own regardless.

- **Downloads are deferred: the SwiftUI `WebPage` download API has not shipped.** The download design routed through a `DownloadCoordinator` and `WebPage.downloads`. Verification against the installed SDK (Xcode 26.5, MacOSX26.5, the latest) found the handling API absent: `WebKit.swiftinterface` exposes only `NavigationAction.shouldPerformDownload` (detection), with no `DownloadCoordinator`, no `WebPage.downloads`, no `startDownload` / `resumeDownload`, no download case in `NavigationEvent`, and no SPI; `Configuration` and `NavigationResponse` carry no download hook; Apple's published "WebKit for SwiftUI" documentation lists no download symbol. The API exists in WebKit trunk but is unreleased, so a download (notably the `blob:` firmware case) cannot be received, placed, or observed on `WebPage` today. Per the plan's block-don't-guess gate, downloads are deferred until the native API ships (revisit after WWDC26, once xOS27 is stable) rather than pivoting the security-sensitive window to `WKWebView`. Tracked in [issue #39](https://github.com/Omega-Networks/Pulse/issues/39). When the API lands, implement the recorded design (per-download save dialog, per-window download center, a `web.download.*` audit family, the `com.apple.security.files.user-selected.read-write` entitlement). The `blob:` pop-up branch therefore blocks-and-audits today (`web.session.popup_blocked`) rather than converting to a download.

## Slice 8d note: connection lifecycle view-model extraction

Slice 8d closes the extraction the Slice 8c note deferred ("a future slice may introduce an `SSHTerminalConnectionViewModel` to own the lifecycle"). The spike disproved the stated obstacle: the lifecycle's `@State` footprint is narrow (`status`, `sshClient`, `isRecording`), not too wide to extract. A new `@MainActor @Observable final class SSHTerminalConnectionViewModel` owns those three plus `run` (the relocated `runConnectionLifecycle`); `SSHTerminalView` renders `vm.status` / `vm.isRecording` and keeps the form bindings, `@Query`, and `@StateObject` collaborators. Five structural notes worth recording so future maintainers do not re-derive the trade-offs:

- **Push-model injection, not stored collaborators.** `@Query` results, the `@StateObject`s (`surface`, `bellController`, `mismatchCoordinator`), and the `ModelContext` exist only on a `View`, so they cannot be the VM's stored property wrappers. They are passed per attempt through a `LifecycleContext` value; the VM holds only the observable lifecycle state. *Alternative considered:* have the VM own the collaborators. Rejected because it would duplicate ownership SwiftUI already holds and break the `@StateObject` lifetime contract.
- **The view's `.task(id:)` stays the driver.** `SSHTerminalView` keeps `.task(id: connectionAttempt) { await vm.run(...) }`; the VM never spawns its own driver `Task`. This preserves SwiftUI's auto-cancel-on-dismissal propagating into `run`'s `await` chain to the deferred `client.close()`. A VM-owned driver task would sever that cancellation contract. The inner `Task` in `run` (pty/shell setup) is a child of the view's task and stays.
- **`[weak self]` on the recording exit handler.** As a class rather than the prior struct, the VM introduces a retain cycle the struct never had: `client → session → exit-handler → VM → client`. The recording-indicator `onChange` handler captures `[weak self]`; without it the cycle only breaks on `close()`. This is exactly the path ADR Verification row 10 (no retain cycles) checks, so the slice's acceptance gate is a live deinit / Instruments pass, not unit tests.
- **`resolveConnection` pure seam is the real testability win.** The host/port/credential resolution and the three operator-facing guard branches (device missing, no primary IP, credential deleted while the window was open) lifted out of `run` into a `nonisolated static func resolveConnection(...) -> .ready | .failed`. Five tests in `SSHConnectFormTests` pin the branches against synthetic models with no network. The connect and handler-wiring glue stays concrete: stubbing the full `SSHClient` + `SSHSession` surface to test glue would be heavy abstraction over the subsystem's most delicate file for low value, and the glue is verified live (loopback + the deinit pass). Extraction therefore buys a genuine new-coverage seam plus separation, not a fully mockable lifecycle, and that scope is deliberate.
- **Relocated, not rewritten.** `ConnectionStatus` / `ConnectionAttempt` / `PrimaryActionShape`, `autoFireAttempt`, `statusPillCopy`, `primaryActionShape`, `registerRecordingLifecycle`, and `applyDeviceDefaultsIfRequested` / `clearDeviceDefaults` moved onto the VM unchanged; the pure mappings are `nonisolated` so they stay callable from synchronous test contexts as they were on the struct. The Slice 8c note's "New test seams" (`statusPillCopy` / `primaryActionShape`) now live on `SSHTerminalConnectionViewModel`, and their tests re-point accordingly. Behaviour-preserving: no operator-visible change, so no `docs/credentials.md` or release-note entry.

## Forward-looking implementation discipline

The SSH foundations implementation surfaced three structural cascades that were, in retrospect, knowable from public-API inspection before the plan was locked. The rolling pause-decide-resume discipline contained each cascade to one extra commit instead of multiple review rounds, but the cleaner cost reduction is earlier verification.

### API-surface verification before locking a slice plan

Every slice that depends on external API surfaces (Apple SDK, vendored package, system framework) should perform a short verification pass before code starts:

1. **Type existence.** For every external type the plan names, confirm the type exists at the pinned dependency version. Five-minute pass through the package source or Apple developer docs.
2. **Init / method / property reachability.** For every external API the plan calls, confirm the init or method exists in the public API and is reachable from Pulse code (not `internal` or `private`).
3. **Capability coverage.** Confirm the external type's documented capabilities cover what the plan requires (e.g., "Does CryptoKit's Curve25519 init from PEM?"). When the answer is uncertain, write a ~20-line spike before locking the plan rather than assuming.
4. **Dependency version confirmation.** Re-check `Package.resolved` if the slice depends on transitively-pulled deps; surfaces can move across minor versions.
5. **Cross-layer identifier consistency.** For any identifier the plan threads across layers (SwiftData model, network API, filesystem, on-disk envelope, audit fields), grep that the layers agree on the type. The recording stack surfaced `Device.id: Int64` mid-plan because the SwiftData model wasn't checked against the planned `<deviceUUID>` path scheme. A five-minute SwiftData-model grep before plan-lock would have caught the mismatch and saved an amendment cycle. Internal cross-layer consistency is as load-bearing as external-API reachability; the verification pass covers both.

Three cascades the SSH foundations implementation hit that this discipline would have caught at planning rather than implementation time:

- NIOSSH's `BackingKey` is `internal` — visible in the swift-nio-ssh source in five minutes.
- NIOSSH has no RSA private-key path — visible from `NIOSSHPrivateKey`'s init methods in the same five minutes.
- CryptoKit's `Curve25519.Signing.PrivateKey` has no PEM init — visible in Apple's Developer documentation.

The discipline is cheap and forces explicit confrontation with the v1 dependency surfaces before commitments are made. It complements the pause-decide-resume discipline; doesn't replace it.

### Transient context stays out of long-lived artefacts

Branch context (slice numbers, commit hashes, PR numbers, in-flight feature names) must not appear in production source code, test files, or operator-facing documentation. The failure modes are concrete:

- **Commit hashes don't survive rebase or squash-merge.** A docstring saying *"regression guard for the round-1 fix in commit `4dfe844`"* stops resolving the day the branch is squashed. The hash points at an object that no longer exists in the merged history.
- **Slice numbers don't survive the codebase outliving the plan.** Pulse organises the SSH and Web work into roughly seven slices; in two years no one reading the code will remember which slice was which. *"Slice 4 ships v=1"* tells the next maintainer nothing they can act on; *"Ships v=1"* says the same thing and remains true.
- **In-flight feature names confuse operators.** A UI label like *"Debug SSH (Slice 3 verification)"* ships the development workflow's vocabulary to the user. Feature-descriptive language (*"SSH connection test"*) describes the thing in terms the operator can act on.

The single exception is explicit historical-lineage sections in ADRs. The *"Slice N amendments summary"* sections in this document record when a contract changed and what changed; the slice numbers there are correct because they're dating decisions, not describing the code's current state. Operator-facing docs (`docs/credentials.md`) describe behaviour, not lineage.

Mechanical check before merge: a grep over `Pulse`, `PulseTests`, and operator-facing docs for `Slice\s*[0-9]`, commit-hash patterns, and `PR #` references should return empty. Intentional references live only in `docs/architecture/` historical sections. The recording-slice cleanup retroactively applied this discipline across the SSH module; subsequent slices should apply it incrementally rather than carrying transient context into long-lived artefacts.

### Test-sizing first-principles

Before adding a test, apply the delete-rather-than-optimise lens: would deleting this test make the code suite worse? If the test pins a non-obvious correctness property that would silently regress under refactor, it pays rent. If it asserts that the standard library or a vendored dependency behaves as documented, it does not.

Concrete categories that consistently fail the rent test:

- **Framework or SDK behaviour tests.** Asserting `JSONEncoder.outputFormatting = [.sortedKeys]` produces sorted keys, or that `SHA256.hash(of:)` is deterministic, tests Apple's contracts rather than Pulse's. Delete; if Apple breaks these contracts, higher-level tests will surface the failure.
- **Tautological string-format tests.** Asserting `keychainService == "\(bundleID).ssh.logwrap"` where the production code is `"\(bundleID).ssh.logwrap"` doesn't catch typos. Both sides edit together. Delete unless the format is a wire-compatible contract with an external system.
- **Test-harness self-tests.** Tests asserting the test observer captures events correctly, or that a mock store stores values. If the harness is broken, every downstream test that uses it fails visibly; a standalone harness test duplicates that signal.
- **Reductively-redundant edge cases.** An "empty input" test that's subsumed by a parameterised happy-path test's first arrangement. Fold into the happy path rather than carrying as a separate method.

What does pay rent:

- **Cryptographic round-trips.** Encrypt/decrypt, wrap/unwrap, hash-chain validation. The algebra is non-obvious and would regress silently.
- **Tamper detection.** Single-byte flip surfaces as a clean failure with no plaintext leaking past the break.
- **Bounded resources.** Back-pressure overflow, retention threshold, pool exhaustion. These are properties production deployment will hit; lab-verifying at the bound is cheaper than discovering at scale.
- **Concurrency invariants.** FIFO ordering across EventLoop-to-actor boundaries, idempotent close, single-flighted drains.
- **Wire-shape regression guards.** Audit-event field sets that SIEM rules depend on; on-disk envelope shapes that future readers parse.

The recording slice's worked example: 61 new tests landed; 16 (26%) deleted or folded during cleanup, all from the framework, tautology, and harness categories. The remaining 45 each pin a property that would not be obvious from reading the code. The cut was retroactive; the discipline is to apply it at test-authoring time so the retroactive pass shrinks toward zero over subsequent slices.

### Per-feature verification questions

These are the known-risk surfaces for upcoming features, captured while the foundational work's lessons are fresh. Each upcoming planning conversation should walk this list as the first step, plus whatever the API-surface pass surfaces fresh.

**`SessionLogWriter` + `credential.recordSessions` branching.** *Resolved at the recording-stack plan-lock; resolutions captured in the Slice 4 amendments summary above. Questions preserved here as a record of the verification discipline working.*

- Does `SecureEnclave.P256.KeyAgreement.PrivateKey` exist alongside `SecureEnclave.P256.Signing.PrivateKey`? **Yes** (iOS 13+/macOS 10.15+), with `init(accessControl:)` and `init(dataRepresentation:)` mirroring the signing-key surface, and `sharedSecretFromKeyAgreement(with:)` producing a `SharedSecret`. The wrapping path is fully CryptoKit-native; the `SecKeyCreateEncryptedData` reference was retired.
- How does `NSFileProtectionComplete` map to macOS? **It doesn't, as a per-file primitive.** `FileProtectionType` compiles on macOS but only `.none` carries real semantics outside the iOS family; macOS at-rest protection is FileVault (whole-volume). §6 amended to document the asymmetry openly rather than manufacture macOS-side ceremony.
- Where does `~/Library/Application Support/Pulse/Sessions/` resolve on iOS? **It doesn't resolve cleanly inside App Sandbox.** Path resolution moved to `FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, ...)` which lands platform-correctly on macOS non-sandboxed (`~/Library/Application Support/...`), macOS sandboxed (`~/Library/Containers/<bundle-id>/Data/Library/Application Support/...`), and iOS (`<container>/Library/Application Support/...`) without further branching.
- Does `CryptoKit.AES.GCM` handle the per-record encryption shape? **Yes.** `seal(_:using:nonce:)` takes a `SymmetricKey` + fresh `AES.GCM.Nonce()` (12-byte random) per record; `SealedBox` exposes `.nonce`, `.ciphertext`, `.tag`, and `.combined`. The `prev = SHA256(prevSealedBox.combined)` hash chain lives in the *plaintext* envelope before sealing.
- Are JSONL records, AES-GCM ciphertext, and the hash-chain prev field naturally serialisable as a single `Codable` envelope? **Yes**, with one guardrail: chain validation operates on raw on-disk `SealedBox.combined` bytes, never on a re-encoded envelope, to avoid future `JSONEncoder` updates silently invalidating historical logs.

Also discovered during plan-lock (not in the pre-recording question list but worth noting for the verification-discipline record): `SSHClient.connect(...)` had no `deviceID` parameter, and `Device.id` was `Int64` not UUID — caught by a five-minute SwiftData-model grep before code started, propagated as a third §6 amendment.

**SwiftTerm integration + operator-facing terminal + host-key mismatch UI.** Verify before locking:

- SwiftTerm's bytes-in API surface — does it take `ArraySlice<UInt8>` (matching `SSHSession.setOutputHandler`'s shape), `Data`, or `[UInt8]`? `SSHSession`'s API was shaped on the assumption that `[UInt8]`-shaped consumption works without copying; confirm or note the adapter.
- `NSViewRepresentable` / `UIViewRepresentable` wrapping cleanliness — is there a known-good integration pattern for SwiftTerm in SwiftUI, or do we own that work? The omega "brain dead simple" lens says use SwiftTerm's documented pattern if one exists.
- Pinned tag stability — what's the current SwiftTerm release cadence, and which tag is the slice targeting? ADR §10 calls for explicit-review tag bumps; first-time pinning is the same concern.
- Does SwiftTerm carry features for the v1 verification artefact in row 4 of the verification table: 256-colour rendering, `top`, `vim`, `Ctrl+C` propagation, resize-via-`tput`? If any of these is missing, the verification table needs revising (or SwiftTerm needs replacing, which is a much larger conversation).
- Host-key mismatch UI sheet — what's the operator action surface? Accept / reject / forget? Where does the trust update land in `KnownHost`? Per ADR §5 the trust UI distinguishes the three modes by colour; the mismatch sheet needs to surface the same visual contract.

**Web companion: `WebPage` + custom URL scheme handler.** Status: the toolbar bindings (`page.title` / `page.estimatedProgress`) and the navigation decider shipped as-built in W2b (see the W2b amendment); the `urlSchemeHandlers` and byte-streaming questions below remain genuinely open and are owned by W3, since the spike verified the auth-challenge API, not the scheme-handler surface. Verify before locking W3:

- `WebPage.Configuration.urlSchemeHandlers["pulse-tunnel"]` — does this surface exist on iOS 26 / macOS 26 and accept the dictionary shape §8 sketches? These are new SDKs; surfaces may have shifted from beta to release.
- Custom `URLSchemeHandler` byte-streaming — does the handler support PulseTransport's `Channel`-returning shape, or does it require a different response-delivery pattern? The seam needs to bridge two different async models (WebKit's URLSchemeHandler callback vs SwiftNIO's EventLoopFuture/Channel).
- Toolbar binding to `page.title` / `page.estimatedProgress` — `@Observable` propagation in iOS 26 / macOS 26, KVO bridge, or manual `@Published`?
- Navigation decider blocks unrelated origins — per the verification table row 9. Confirm the WebKit API for navigation decision callbacks; the surface has shifted across recent macOS releases.

**`HostTrust.trustedCA` import UI + per-site enforcement policy.** Verify before locking:

- CA bundle import format — what does the operator paste or import? Single `~/.ssh/ca.pub` line? OpenSSH `cert-authority` line in known_hosts format? PEM bundle? Multiple CA public keys in one file? The existing evaluation path consumes `caFingerprintSHA256` + `principalPattern`; the UI needs to produce both from whatever format operators have in hand.
- Principal pattern syntax scope — `SSHHostKeyDelegate.matches(host:anyOf:pattern:)` currently supports literal equality and trailing-`*` wildcard only. If the import UI accepts richer OpenSSH patterns (`!host` negation, comma-separated lists, the full `Match` block grammar), the matcher needs extending. Decide scope before the UI work locks; mismatch between UI and matcher capability is the failure mode to avoid.
- Per-site enforcement policy storage — `requireCertificateVerification: Bool` lives where? Per-`Site` model field? Per-tenant `Configuration`? Both? §5 says "per-site / per-tenant" without committing to a storage location; pick before adding the field.

**Future portable additions — encrypted PEM import (no current slice number).** When this opens, verify:

- Is bcrypt-pbkdf reachable via any Apple-shipped SDK (CryptoKit, CommonCrypto, or other)? Current answer is no, which is why the deferral exists. Re-check at the time; the deferral is gated on Apple shipping a usable primitive, not on internal scoping.
- Is PBKDF2 reachable via CryptoKit on current Apple platforms, or still only via CommonCrypto? CommonCrypto is system-shipped (not third-party), so PBKDF2 is acceptable per §10 if the Swift surface is usable; confirm the import path and call ergonomics.
- Are AES-CTR / AES-CBC available via CryptoKit, or do they still require CommonCrypto? CryptoKit's AES surface is GCM-only as of writing; encrypted PKCS#8 needs CBC (or sometimes CTR), encrypted OpenSSH new-format needs CTR.

## Review

This document is the contract. Changes require a new ADR or an amendment with explicit rationale. Implementation PRs touching SSH, Web, transport, credentials, or session logging must reference this ADR in their description.
