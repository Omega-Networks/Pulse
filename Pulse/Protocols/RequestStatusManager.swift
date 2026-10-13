//
//  RequestStatusManager.swift
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
import SwiftData

@Observable final class RequestStatusManager: @unchecked Sendable {
    static let shared = RequestStatusManager()
    private let queue = DispatchQueue(label: "com.pulse.requeststatus")
    
    enum RequestSource: Hashable {
        case netbox
        case zabbix
        
        var displayName: String {
            switch self {
            case .netbox: return "NetBox"
            case .zabbix: return "Zabbix"
            }
        }
    }
    
    enum RequestStatus: Equatable {
        case success(code: Int, message: String)
        case authenticationFailure(code: Int, message: String)
        case connectionError(String)
        case dataError(code: Int, message: String)
        case unknownError(String)
        case syncing(String)
    }
    
    @MainActor
    private(set) var currentStatus: [RequestSource: RequestStatus] = [:]
    
    nonisolated private init() {}
    
    @MainActor
    func updateStatus(_ source: RequestSource, _ status: RequestStatus) {
        currentStatus[source] = status
    }
    
    @MainActor
    func resetStatus() {
        currentStatus.removeAll()
    }

    /// Drop a `.syncing` marker without touching a terminal status.
    @MainActor
    func clearSyncing(_ source: RequestSource) {
        if case .syncing = currentStatus[source] {
            currentStatus[source] = nil
        }
    }

    @MainActor
    func clear(_ source: RequestSource) {
        currentStatus[source] = nil
    }
}

/// One operator-visible condition. A later log is a view of these values.
/// `id` is stable for the condition, so a repeat replaces the previous line.
struct OperatorNotice: Identifiable, Sendable, Equatable {
    enum Source: String, Sendable, Equatable {
        case netbox
        case zabbix
        case powersense
    }

    enum Severity: Sendable, Equatable {
        case warning
        case failure
    }

    var id: String
    var source: Source
    var severity: Severity
    var message: String
    var occurredAt: Date

    /// The same sentence the Zabbix toolbar already shows. Success and
    /// the in-flight marker are not notices.
    static func fromZabbix(_ status: RequestStatusManager.RequestStatus) -> OperatorNotice? {
        let message: String
        let severity: Severity
        switch status {
        case .connectionError(let text):
            message = text
            severity = .warning
        case .authenticationFailure(_, let text),
             .dataError(_, let text),
             .unknownError(let text):
            message = text
            severity = .failure
        case .success, .syncing:
            return nil
        }
        return OperatorNotice(
            id: "zabbix.status",
            source: .zabbix,
            severity: severity,
            message: message,
            occurredAt: Date()
        )
    }
}

/// In-memory notices. Producers post and clear. Views read `notices`.
@MainActor
@Observable
final class OperatorNoticeCenter {
    static let shared = OperatorNoticeCenter()

    private(set) var notices: [OperatorNotice] = []

    private init() {}

    func post(_ notice: OperatorNotice) {
        if let index = notices.firstIndex(where: { $0.id == notice.id }) {
            notices[index] = notice
        } else {
            notices.append(notice)
        }
    }

    func clear(id: String) {
        notices.removeAll { $0.id == id }
    }

    func clear(source: OperatorNotice.Source) {
        notices.removeAll { $0.source == source }
    }
}
