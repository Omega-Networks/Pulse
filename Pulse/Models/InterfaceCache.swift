//
//  InterfaceCache.swift
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

// MARK: - Session cache (removed in the P2 consumer/purge slices)

actor InterfaceCache {
    static let shared = InterfaceCache()
    private var cache: [Int64: [InterfaceVO]] = [:]
    private var allInterfaces: Set<Int64> = []

    private init() {}

    func getInterfaces(forDeviceId deviceId: Int64) -> [InterfaceVO] {
        return cache[deviceId] ?? []
    }

    func getInterface(withId id: Int64) -> InterfaceVO? {
        for interfaces in cache.values {
            if let interface = interfaces.first(where: { $0.id == id }) {
                return interface
            }
        }
        return nil
    }

    func setInterfaces(_ interfaces: [InterfaceVO], forDeviceId deviceId: Int64) {
        cache[deviceId] = interfaces
        interfaces.forEach { allInterfaces.insert($0.id) }

        Task { @MainActor in
            NotificationCenter.default.post(name: .interfacesDidUpdate, object: nil)
        }
    }
}

extension Notification.Name {
    static let interfacesDidUpdate = Notification.Name("interfacesDidUpdate")
}

