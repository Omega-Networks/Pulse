//
//  ZabbixTransport.swift
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

/// The write path's HTTP call. The problem GET stays on `URLSession` inside
/// `SiteDataService`. Tests pass a fake here and do not open a socket.
protocol ZabbixTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Data
}

struct URLSessionZabbixTransport: ZabbixTransport {
    func send(_ request: URLRequest) async throws -> Data {
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            throw ZabbixError.fromTransport(error)
        }
    }
}
