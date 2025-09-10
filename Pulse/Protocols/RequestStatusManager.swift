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
}
