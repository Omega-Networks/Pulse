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

    struct DecodedList<Element: Sendable>: Sendable {
        var items: [Element]
        var skipped: Int
    }

    static func decodeElements<T: Decodable>(
        _ type: T.Type,
        from object: [String: Any]
    ) throws -> DecodedList<T> {
        guard let result = object["result"] as? [[String: Any]] else {
            throw ZabbixError.fromRPC(object)
        }
        let decoder = JSONDecoder()
        var items: [T] = []
        var skipped = 0
        items.reserveCapacity(result.count)
        for element in result {
            do {
                let data = try JSONSerialization.data(withJSONObject: element)
                items.append(try decoder.decode(T.self, from: data))
            } catch {
                skipped += 1
            }
        }
        return DecodedList(items: items, skipped: skipped)
    }

    static func urlRequest(
        endpoint: URL,
        method: String,
        params: [String: Any],
        applied: AppliedAuth,
        extraHeaders: [String: String]?,
        id: Int = 1
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = ZabbixServerURL.timeout
        request.setValue("application/json-rpc", forHTTPHeaderField: "Content-Type")
        if let bearer = applied.bearerHeader {
            request.setValue(bearer, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: requestBody(
                method: method, params: params, id: id, bodyAuth: applied.bodyAuth
            )
        )
        if let extraHeaders {
            for (key, value) in extraHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
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
