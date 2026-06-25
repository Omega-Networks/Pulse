//
//  ExitCause.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Pulse
//  The Platform for Unified Leadership in Smart Environments.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  This program is free software: communities can deploy it for sovereignty, academia can
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation

/// Terminal state of an SSH session as observed by `SSHClient` / `SSHSession`.
///
/// Surfaced both to the `os_log` `session.close` emission (audit trail,
/// ADR §7) and to the byte pump's exit-handler closure (the
/// operator-facing SwiftTerm consumer uses this to drive the terminal's
/// exit display). Cases cover the failure-mode inventory the SSH
/// connect path enumerates, plus a clean client-initiated case for
/// normal teardown.
///
/// `Equatable` so tests can assert specific failure modes without reaching
/// through `String(describing:)`; `Sendable` so the exit-handler closure can
/// be invoked from any isolation context.
enum ExitCause: Equatable, Sendable, CustomStringConvertible {

    /// Client called `close()` on `SSHClient` or `SSHSession`. Normal teardown.
    case clientInitiated

    /// `PulseTransport.connect` didn't complete within its timeout window.
    /// The current `DirectTransport` default is 10 seconds (ADR §8).
    case transportTimeout

    /// TCP connection died after the SSH session had opened. The server may
    /// have been killed, the network may have transitioned, or the remote
    /// may have closed without a clean SSH shutdown.
    case transportDropped

    /// Server closed the channel cleanly with an explicit exit status.
    /// Status 0 is a normal exit; non-zero indicates the remote command
    /// returned an error.
    case remoteExit(Int32)

    /// The auth delegate exhausted its offer list (returned `nil`). The
    /// server rejected every credential / certificate combination on offer.
    case authExhausted

    /// The host-key delegate rejected the presented host key. The reason
    /// is the operator-readable description from `SSHHostKeyError`
    /// (`fingerprintMismatch`, `caValidationFailed`, `explicitlyDistrusted`).
    case hostKeyRejected(reason: String)

    /// Some other transport-level error closed the channel. Wraps the
    /// underlying error's description so the audit log doesn't lose it.
    case channelError(reason: String)

    var description: String {
        switch self {
        case .clientInitiated:
            return "client-initiated"
        case .transportTimeout:
            return "transport-timeout"
        case .transportDropped:
            return "transport-dropped"
        case .remoteExit(let status):
            return "remote-exit(\(status))"
        case .authExhausted:
            return "auth-exhausted"
        case .hostKeyRejected(let reason):
            return "host-key-rejected: \(reason)"
        case .channelError(let reason):
            return "channel-error: \(reason)"
        }
    }
}
