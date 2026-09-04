//
//  NetBoxAuthorization.swift
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

/// Fail-closed Authorization header. Empty token must not produce a request.
enum NetBoxAuthorization {
    static func headerValue(for token: String) throws -> String {
        guard !token.isEmpty else { throw NetBoxSyncError.missingToken }
        if token.hasPrefix("nbt_") {
            return "Bearer \(token)"
        }
        return "Token \(token)"
    }
}

/// Settings URL must be `https` with a host. `http://` is rejected here even
/// when ATS would allow it on the local network. Userinfo (`user:pass@` or
/// `token@`) is rejected — the API token is a separate Settings field.
enum NetBoxServerURL {
    static func parse(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NetBoxSyncError.missingServerURL }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty
        else {
            throw invalid(raw)
        }
        guard scheme == "https" else {
            throw invalid(raw)
        }
        if url.user != nil || url.password != nil {
            throw invalid(raw)
        }
        return url
    }

    /// Associated value / operator copy. Userinfo is stripped so a pasted
    /// `https://secret@host` cannot land in the status bar.
    static func redacted(_ raw: String) -> String {
        guard var components = URLComponents(string: raw),
              components.user != nil || components.password != nil else {
            return raw
        }
        components.user = nil
        components.password = nil
        return components.string ?? raw
    }

    /// Log line: scheme/host/port/path only. Never userinfo, query, or fragment.
    static func logDescription(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = url.path
        return components.string ?? url.host ?? "netbox"
    }

    static func invalid(_ raw: String) -> NetBoxSyncError {
        .invalidServerURL(redacted(raw))
    }
}
