//
//  ProviderModelActor.swift
//  PulseSync
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
import Dispatch
import OSLog

actor ProviderModelActor {
    @Published private(set) var isLoadingZabbixEvents = false
    @Published private(set) var isLoadingZabbixItems = false
    @Published private(set) var isLoadingZabbixHistories = false
    
    
    var enableMonitoring = false
    
    var modelContainer: ModelContainer
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }
    

    
    // MARK: - Helper functions
    
    func updateEvents(params: UpdateParameters, eventIds: [String]) async {
        let logger = Logger(subsystem: "zabbix", category: "eventUpdate")
        
        logger.debug("Running updateEvents with eventIds: \(eventIds)")
        do {
            try await updateHostEvents(params: params)
            
            // After successful update, refresh events for affected events
            logger.debug("Fetching updated events")
            let service = SiteDataService(modelContainer: modelContainer)
            await service.getProblems(using: eventIds)
            
        } catch {
            logger.error("Failed to update events: \(error.localizedDescription)")
        }
    }
}

