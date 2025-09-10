//
//  TipManager.swift
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
import TipKit


/**
 TipManager is responsible for managing and configuring TipKit tips throughout the application.
 
 This class follows the Singleton pattern to ensure consistent tip state across the app.
 It handles the configuration of TipKit and maintains references to all application tips.
 
 */
@MainActor
final class TipManager: ObservableObject {
    static let shared = TipManager()
    @Published private(set) var isConfigured = false
    
    // Create tips as published properties
    let credentialsTip = CredentialsTip()
    let fetchEventsTip = FetchEventsTip()
    
    private init() {}
    
    func configure() {
        guard !isConfigured else { return }
        do {
            try Tips.resetDatastore() // Reset first
            try Tips.configure()
            isConfigured = true
            print("TipKit configured successfully") // Add logging
        } catch {
            print("Failed to configure TipKit: \(error)")
        }
    }
}
