//
//  Service.swift
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

import OSLog
import SwiftData
import SwiftUI

// MARK: - Core Data

/// Managed object subclass for the NetBox Application Service entity.

@Model
final class Service {
    @Attribute(.unique) var id: Int64
    var name: String?
    var display: String?
    var url: String?
    var serviceDescription: String?

    /// NetBox `port_mappings`, such as `tcp/22`. A 4.3 to 4.6 payload
    /// with only `protocol` and `ports` is stored in the same shape.
    var portMappings: [String] = []
    var ipAddresses: [String] = []

    // MARK: - Parent linkage (migration-proof)
    //
    // A NetBox service is attached to a parent that is either a `dcim.device`
    // or a `virtualization.virtualmachine`. The generic parent fields stay
    // so a service whose parent is missing locally still keeps its name.
    // The typed relationship is wired for whichever parent is in the store.

    /// NetBox `parent_object_type`, e.g. `"dcim.device"` or
    /// `"virtualization.virtualmachine"`. Drives which typed relationship is
    /// wired at sync time.
    var parentObjectType: String?
    /// NetBox `parent_object_id` (the parent device or VM id).
    var parentObjectId: Int64 = 0
    /// Parent display name, carried so a service whose parent is not in
    /// the store still has a name.
    var parentName: String?

    // MARK: Service Model Relationships

    /// Wired when `parentObjectType == "dcim.device"`. Inverse on
    /// `Device.services`.
    var device: Device?

    /// Wired when `parentObjectType == "virtualization.virtualmachine"`.
    /// Inverse on `VirtualMachine.services`.
    var virtualMachine: VirtualMachine?

    init(id: Int64) {
        self.id = id
    }

    // MARK: - Computed Properties

    /// Ports declared for one transport, lowest first as stored.
    /// `tcp` matches `tcp/22` and ignores `udp/161`.
    func ports(for transport: String) -> [Int] {
        let wanted = transport.lowercased()
        return portMappings.compactMap { mapping in
            let parts = mapping.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == wanted else { return nil }
            return Int(parts[1])
        }
    }

    /// The bare IP address of the first associated IP, with any trailing CIDR
    /// prefix stripped. Mirrors `Device.primaryIPAddress`: NetBox's IPAM stores
    /// addresses in CIDR form (e.g. `192.0.2.10/24`), but the web companion
    /// and other network call sites need the bare address, not the CIDR string.
    /// The split is on the first `/` only; no IP address text contains a literal
    /// `/` for any other reason. Returns nil when there are no addresses.
    var primaryIPAddress: String? {
        guard let first = ipAddresses.first else { return nil }
        if let slash = first.firstIndex(of: "/") {
            return String(first[..<slash])
        }
        return first
    }
}

// MARK: - Identifiable

/// Matches `Device` / `Site`: `id` is already `@Attribute(.unique) Int64` (the
/// NetBox primary key), so the empty extension just marks that the model
/// participates in identity-based SwiftUI APIs.
extension Service: Identifiable {}

