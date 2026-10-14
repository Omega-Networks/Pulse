//
//  ToolbarStatus.swift
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
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import SwiftUI
import SwiftData

struct ToolbarStatus: View {
    @Query private var syncProvider: [SyncProvider]
    @Query private var sites: [Site]
    private var statusManager = RequestStatusManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(sites.count) Sites")
                .font(.caption)
            if case .syncing(let message) = statusManager.currentStatus[.netbox] {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct NetBoxSyncIndicator: View {
    private var statusManager = RequestStatusManager.shared

    var body: some View {
        if case .syncing(let message) = statusManager.currentStatus[.netbox] {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Toolbar warning for operator notices (a NetBox model the token cannot
/// read, a Zabbix failure). Hidden when the list is empty. Hover uses the
/// same `.help` as the other toolbar buttons; click opens the detail.
struct ZabbixToolbarWarning: View {
    @Environment(\.modelContext) private var modelContext
    private var noticeCenter = OperatorNoticeCenter.shared
    @State private var showingDetail = false
    @State private var isRetrying = false

    var body: some View {
        if !active.isEmpty {
            Button {
                showingDetail = true
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .help(summary)
            .accessibilityLabel(summary)
            .popover(isPresented: $showingDetail, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(active) { notice in
                        Text(notice.message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hasZabbixNotice {
                        Button(isRetrying ? "Checking…" : "Retry") {
                            retry()
                        }
                        .disabled(isRetrying)
                    }
                }
                .padding(12)
                .frame(width: 280, alignment: .leading)
            }
        }
    }

    private var active: [OperatorNotice] {
        noticeCenter.notices
    }

    private var summary: String {
        active.map(\.message).joined(separator: "\n")
    }

    private var hasZabbixNotice: Bool {
        active.contains { $0.source == .zabbix }
    }

    private func retry() {
        isRetrying = true
        let container = modelContext.container
        Task {
            await SiteDataService(modelContainer: container).getProblems()
            await MainActor.run {
                isRetrying = false
                if !hasZabbixNotice {
                    showingDetail = false
                }
            }
        }
    }
}
