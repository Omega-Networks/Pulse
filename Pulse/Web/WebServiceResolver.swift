//
//  WebServiceResolver.swift
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

import Foundation

// MARK: - Web target

/// A resolved, openable web endpoint derived from a NetBox Application Service.
struct WebTarget: Equatable, Hashable {
    let url: URL
    /// The NetBox service name this target was derived from (for the picker and
    /// the audit trail).
    let serviceName: String
    /// `"https"` or `"http"`, derived from the NetBox service name.
    let scheme: String
    /// Bare IP (CIDR stripped) of the service's first address.
    let host: String
    /// The service's first declared port.
    let port: Int
}

// MARK: - Web service resolver

/// Decides which of a device's NetBox Application Services is its web UI, and
/// the URL to open, treating NetBox as the source of truth.
///
/// The rule is deliberately not a hardcoded port-to-scheme guess: it reflects
/// what the operator declared in NetBox. A TCP service whose name announces a
/// web scheme (a name containing `HTTPS` opens `https`, `HTTP` opens `http`) is
/// web-openable, and the URL is built from that same service's declared port and
/// IP address. If a device's web UI is missing here, the fix is to define the
/// service correctly in NetBox rather than to add a heuristic to Pulse. This
/// keeps Pulse a faithful window onto the source of truth. See ADR 0001 §9.
enum WebServiceResolver {

    /// All web-openable targets for a device, ordered by preference: `https`
    /// before `http`, then lowest port.
    static func webTargets(for device: Device) -> [WebTarget] {
        webTargets(from: device.services ?? [])
    }

    /// Resolution over a bare service list. Split out from the `Device` form so
    /// the rule is unit-testable without constructing a SwiftData `Device` and
    /// its relationship graph.
    static func webTargets(from services: [Service]) -> [WebTarget] {
        services
            .compactMap(target(from:))
            .sorted(by: preferenceOrder)
    }

    /// The single preferred web target for a device, or nil if none qualifies.
    /// This is the gate for the "Open Web UI" affordance and the default the
    /// window opens.
    static func primaryTarget(for device: Device) -> WebTarget? {
        webTargets(for: device).first
    }

    /// Builds a `WebTarget` from one service when NetBox declares it as web.
    /// Returns nil for non-TCP services, services whose name does not announce
    /// http/https, services without a declared port, or services without an IP.
    static func target(from service: Service) -> WebTarget? {
        guard service.protocolValue?.lowercased() == "tcp",
              let scheme = scheme(forServiceNamed: service.name),
              let port = service.ports.first,
              let host = service.primaryIPAddress, !host.isEmpty,
              let url = URL(string: "\(scheme)://\(host):\(port)/")
        else {
            return nil
        }
        return WebTarget(
            url: url,
            serviceName: service.name ?? scheme.uppercased(),
            scheme: scheme,
            host: host,
            port: port
        )
    }

    /// Maps a NetBox service name to a web scheme, or nil if the name does not
    /// announce one. `https` is checked before `http` because the former
    /// contains the latter as a substring.
    static func scheme(forServiceNamed name: String?) -> String? {
        guard let lowered = name?.lowercased() else { return nil }
        if lowered.contains("https") { return "https" }
        if lowered.contains("http") { return "http" }
        return nil
    }

    /// `https` sorts before `http`; within a scheme, the lowest port sorts
    /// first. Deterministic so `primaryTarget` is stable across syncs.
    private static func preferenceOrder(_ lhs: WebTarget, _ rhs: WebTarget) -> Bool {
        if lhs.scheme != rhs.scheme {
            return lhs.scheme == "https"
        }
        return lhs.port < rhs.port
    }
}
