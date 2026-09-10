//
//  ZabbixServerURL.swift
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
//  By open sourcing Pulse, we create a circular economy where contributors can both
//  build upon and benefit from the platform, ensuring that value flows back to
//  communities rather than being extracted by external entities. This aligns with
//  our commitment to intergenerational prosperity through collaborative stewardship
//  of public infrastructure.
//
//  This program is free software: communities can deploy it for sovereignty, academia
//  can extend it for research, and industry can integrate it for resilience — all
//  under the terms of the GNU Affero General Public License version 3 as published
//  by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation

/// Settings URL must be `https` with a host and no userinfo. The JSON-RPC
/// script is appended to the path the operator typed. A host-only URL keeps
/// the historical `/zabbix/api_jsonrpc.php` default so existing Settings work.
enum ZabbixServerURL {
    static let timeout: TimeInterval = 30
    static let jsonRPCFile = "api_jsonrpc.php"

    static func parse(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZabbixError.invalidRequest }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty
        else {
            throw ZabbixError.invalidServerURL(raw)
        }
        guard scheme == "https" else {
            throw ZabbixError.invalidServerURL(raw)
        }
        if url.user != nil || url.password != nil {
            throw ZabbixError.invalidServerURL(raw)
        }
        return url
    }

    static func jsonRPCEndpoint(_ raw: String) throws -> URL {
        let base = try parse(raw)
        var path = base.path
        if path.hasSuffix("/\(jsonRPCFile)") || path.hasSuffix(jsonRPCFile) {
            return base
        }
        if path.isEmpty || path == "/" {
            path = "/zabbix/\(jsonRPCFile)"
        } else {
            if !path.hasSuffix("/") { path += "/" }
            path += jsonRPCFile
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ZabbixError.invalidServerURL(raw)
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else {
            throw ZabbixError.invalidServerURL(raw)
        }
        return endpoint
    }
}
