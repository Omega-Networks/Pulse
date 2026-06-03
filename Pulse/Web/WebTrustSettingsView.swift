//
//  WebTrustSettingsView.swift
//  Pulse
//
//  Copyright © 2025-present Omega Networks Limited.
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

import SwiftData
import SwiftUI

// MARK: - Web trust settings

/// Operator surface for reviewing and editing device-web TLS trust decisions:
/// the certificates Pulse has pinned (trusted) and any hosts the operator has
/// explicitly blocked. Lives beside the SSH credentials tab in Settings.
///
/// Reads are a live `@Query`: the web trust table is operator-curated (a handful
/// of appliances), not device-scale, so a sorted fetch is the right tool and the
/// list stays reactive as the navigation decider pins and re-pins underneath.
/// Edits mutate the view's model context directly so the list updates at once,
/// and each edit emits a `web.trust.*` audit event (and only after the write
/// commits), exactly as the navigation decider does, so the audit trail never
/// overstates what persisted.
struct WebTrustSettingsView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\WebHostTrust.host), SortDescriptor(\WebHostTrust.port)])
    private var records: [WebHostTrust]

    var body: some View {
        Group {
            if records.isEmpty {
                emptyState
            } else {
                trustList
            }
        }
    }

    // MARK: - Sub-views

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Trusted Sites Yet", systemImage: "lock.shield")
        } description: {
            Text("When you trust a device's web certificate, it appears here. You can forget a certificate to be prompted again, or block a host to refuse it.")
                .textSelection(.enabled)
        }
    }

    private var trustList: some View {
        Form {
            Section {
                ForEach(records) { record in
                    WebTrustRow(
                        record: record,
                        onForget: { forget(record) },
                        onBlock: { block(record) },
                        onUnblock: { unblock(record) }
                    )
                }
            } header: {
                Text("Trusted and blocked device-web hosts")
            } footer: {
                Text("Forget removes a pinned certificate, so the next visit prompts you again. Block refuses the host until you unblock it. Trust is stored only on this device.")
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Edit actions

    /// The recorded reason for an operator-initiated block, surfaced in the audit
    /// trail and (later) any mismatch UI.
    private static let operatorBlockReason = "blocked by operator"

    private func forget(_ record: WebHostTrust) {
        let (host, port) = (record.host, record.port)
        modelContext.delete(record)
        guard persist(host: host, port: port) else { return }
        WebAudit.forgotten(host: host, port: port)
    }

    private func block(_ record: WebHostTrust) {
        let (host, port) = (record.host, record.port)
        record.trust = .explicitlyDistrusted(reason: Self.operatorBlockReason, recordedAt: .now)
        guard persist(host: host, port: port) else { return }
        WebAudit.distrusted(host: host, port: port, reason: Self.operatorBlockReason)
    }

    /// Unblocking drops the row entirely, so the next visit is a fresh first
    /// sight rather than a silent re-trust. The same removal the operator gets
    /// from Forget, named for the blocked case.
    private func unblock(_ record: WebHostTrust) {
        forget(record)
    }

    /// Commit the pending change. On failure, emit `store_error` and report
    /// failure so the caller skips the success audit: the table must never claim
    /// an edit that did not persist (mirrors the decider's commit-failed rule).
    private func persist(host: String, port: Int) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            WebAudit.storeError(host: host, port: port)
            return false
        }
    }
}

// MARK: - Row

/// One trust record: the endpoint, its status, the pinned fingerprint, and an
/// edit menu whose actions depend on whether the host is trusted or blocked.
private struct WebTrustRow: View {

    let record: WebHostTrust
    let onForget: () -> Void
    let onBlock: () -> Void
    let onUnblock: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(record.host):\(String(record.port))")
                    .font(.headline)
                    .textSelection(.enabled)

                if let fingerprint = pinnedFingerprint {
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("First seen \(record.firstSeenAt.formatted(date: .abbreviated, time: .shortened)), last verified \(record.lastVerifiedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                statusBadge
                editMenu
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch record.trust {
        case .pinned, .trustedCA:
            badge("Trusted", color: .green, icon: "checkmark.shield.fill")
        case .explicitlyDistrusted:
            badge("Blocked", color: .red, icon: "hand.raised.fill")
        }
    }

    private func badge(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }

    private var editMenu: some View {
        Menu {
            switch record.trust {
            case .pinned, .trustedCA:
                Button(role: .destructive, action: onForget) {
                    Label("Forget Certificate", systemImage: "trash")
                }
                Button(action: onBlock) {
                    Label("Block Host", systemImage: "hand.raised")
                }
            case .explicitlyDistrusted:
                Button(action: onUnblock) {
                    Label("Unblock Host", systemImage: "hand.raised.slash")
                }
            }
        } label: {
            Label("Edit", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The pinned (or CA) fingerprint to display; nil for a blocked host, which
    /// carries a reason rather than a fingerprint.
    private var pinnedFingerprint: String? {
        switch record.trust {
        case let .pinned(fingerprint, _): return fingerprint
        case let .trustedCA(fingerprint, _): return fingerprint
        case .explicitlyDistrusted: return nil
        }
    }
}
