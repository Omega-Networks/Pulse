//
//  RolePresentation.swift
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
import Observation

/// Per-role operator surfaces. This is not a sync exclude — those
/// devices stay in SwiftData. Changing a toggle must not delete rows.
///
/// License is derived, never stored. A role counts if it appears on
/// the site graph, in the device list, or in the rack as a named
/// device. In-rack hardware (`treatAsFiller`) does not count, so
/// panels and blanks cannot be switched off independently of how
/// they are drawn.
struct RolePolicy: Codable, Equatable, Sendable, Hashable {
    var hideFromGraph: Bool
    var hideFromDeviceList: Bool
    var skipMonitoring: Bool
    var showInRack: Bool
    var treatAsFiller: Bool

    /// True when the role is shown as a device on the graph, the
    /// list, or the rack. Not a user toggle.
    var countsTowardLicense: Bool {
        !hideFromGraph || !hideFromDeviceList || (showInRack && !treatAsFiller)
    }

    static let operatorDevice = RolePolicy(
        hideFromGraph: false,
        hideFromDeviceList: false,
        skipMonitoring: false,
        showInRack: true,
        treatAsFiller: false
    )

    /// Patch panel, blank plate, cable management, shelf.
    static let rackHardware = RolePolicy(
        hideFromGraph: true,
        hideFromDeviceList: true,
        skipMonitoring: true,
        showInRack: true,
        treatAsFiller: true
    )
}

/// Persisted map of role id → policy. Missing ids use `operatorDevice`.
struct RolePresentation: Equatable, Sendable {
    var policies: [Int64: RolePolicy]

    init(policies: [Int64: RolePolicy]) {
        self.policies = policies
    }

    /// Omega filler roles (blank, cable management, patch panel, shelf).
    /// Presentation defaults only; sync stores every role.
    static let defaultFillerRoleIDs: Set<Int64> = [6, 7, 18, 27]

    static func omegaDefault(
        fillerRoleIDs: Set<Int64> = defaultFillerRoleIDs
    ) -> RolePresentation {
        var policies: [Int64: RolePolicy] = [:]
        for id in fillerRoleIDs {
            policies[id] = .rackHardware
        }
        return RolePresentation(policies: policies)
    }

    func policy(for roleID: Int64?) -> RolePolicy {
        guard let roleID else { return .operatorDevice }
        return policies[roleID] ?? .operatorDevice
    }

    func countsTowardLicense(roleID: Int64?) -> Bool {
        policy(for: roleID).countsTowardLicense
    }
}

extension RolePresentation: Codable {
    enum CodingKeys: String, CodingKey { case policies }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode([String: RolePolicy].self, forKey: .policies)
        var mapped: [Int64: RolePolicy] = [:]
        mapped.reserveCapacity(raw.count)
        for (key, value) in raw {
            guard let id = Int64(key) else { continue }
            mapped[id] = value
        }
        policies = mapped
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let raw = Dictionary(uniqueKeysWithValues: policies.map { (String($0.key), $0.value) })
        try container.encode(raw, forKey: .policies)
    }
}

enum RolePresentationStorage {
    static let key = "pulse.rolePresentation"

    static func load(from defaults: UserDefaults) -> RolePresentation {
        guard let data = defaults.data(forKey: key) else {
            return .omegaDefault()
        }
        do {
            return try JSONDecoder().decode(RolePresentation.self, from: data)
        } catch {
            return .omegaDefault()
        }
    }

    static func save(_ presentation: RolePresentation, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(presentation) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Observable store so Settings toggles refresh the graph and site list.
@Observable
final class RolePresentationStore {
    var presentation: RolePresentation
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.presentation = RolePresentationStorage.load(from: defaults)
    }

    func policy(for roleID: Int64?) -> RolePolicy {
        presentation.policy(for: roleID)
    }

    func setPolicy(_ policy: RolePolicy, for roleID: Int64) {
        presentation.policies[roleID] = policy
        RolePresentationStorage.save(presentation, to: defaults)
    }
}
