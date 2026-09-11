//
//  ZabbixJSONRPC.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Licensed under the GNU Affero General Public License version 3.
//  See <https://www.gnu.org/licenses/>.
//

import Foundation

/// Pure JSON-RPC 2.0 request/error helpers for Zabbix. No network.
enum ZabbixJSONRPC {
    struct AppliedAuth: Equatable, Sendable {
        /// Value for the JSON-RPC `auth` property. Nil omits the key.
        var bodyAuth: String?
        /// Full `Authorization` header value, e.g. `Bearer <token>`.
        var bearerHeader: String?
    }

    /// `user.login` and `apiinfo.version` must not carry credentials.
    static func methodNeedsAuth(_ method: String) -> Bool {
        method != "user.login" && method != "apiinfo.version"
    }

    static func appliedAuth(
        mode: ZabbixAuthMode,
        method: String,
        credential: String
    ) -> AppliedAuth {
        guard methodNeedsAuth(method), !credential.isEmpty else {
            return AppliedAuth(bodyAuth: nil, bearerHeader: nil)
        }
        switch mode {
        case .apiToken:
            return AppliedAuth(bodyAuth: nil, bearerHeader: "Bearer \(credential)")
        case .legacy:
            return AppliedAuth(bodyAuth: credential, bearerHeader: nil)
        }
    }

    static func requestBody(
        method: String,
        params: [String: Any],
        id: Int,
        bodyAuth: String?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
            "id": id
        ]
        if let bodyAuth {
            body["auth"] = bodyAuth
        }
        return body
    }

    /// Zabbix puts `error` as `{code, message, data}`, not a string.
    static func errorDescription(from object: [String: Any]) -> String {
        if let text = object["error"] as? String, !text.isEmpty {
            return text
        }
        guard let error = object["error"] as? [String: Any] else {
            return "Unknown error"
        }
        let message = error["message"] as? String ?? ""
        let data = error["data"] as? String ?? ""
        switch (message.isEmpty, data.isEmpty) {
        case (false, false): return "\(message) \(data)"
        case (false, true): return message
        case (true, false): return data
        case (true, true): return "Unknown error"
        }
    }

    static func looksLikeRejectedBodyAuth(_ description: String) -> Bool {
        let lower = description.lowercased()
        return lower.contains("unexpected parameter") && lower.contains("auth")
    }

    static func looksLikeUnauthorized(_ description: String) -> Bool {
        let lower = description.lowercased()
        return lower.contains("not authorized")
            || lower.contains("session terminated")
            || lower.contains("not authorised")
    }
}
