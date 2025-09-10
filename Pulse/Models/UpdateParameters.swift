//
//  UpdateParameters.swift
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
import SwiftUI

struct UpdateParameters: Sendable {
    let eventIds: [String]
    let action: String
    let message: String?
    let severity: String?
    let suppressUntil: String?
    
    init(eventIds: [String], action: String, message: String?, isChangeSeverity: Bool, selectedSeverity: Int, isSuppress: Bool, selectedSuppressUntil: Date) {
        self.eventIds = eventIds
        self.action = action
        self.message = message == "" ? nil : message
        self.severity = isChangeSeverity ? String(selectedSeverity) : nil
        self.suppressUntil = isSuppress ? String(Int(selectedSuppressUntil.timeIntervalSince1970)) : nil
    }
}
