//
//  ZabbixAuthMode.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  Licensed under the GNU Affero General Public License version 3.
//  See <https://www.gnu.org/licenses/>.
//

import Foundation

/// How Pulse authenticates to Zabbix JSON-RPC.
///
/// Default is `apiToken` (`Authorization: Bearer`). Zabbix 7.2+ rejects the
/// JSON-RPC `auth` property (ZBXNEXT-9452). `legacy` keeps 6.0-6.2 working.
enum ZabbixAuthMode: String, Sendable, CaseIterable {
    /// API token in `Authorization: Bearer`. No `auth` in the body. No `user.login`.
    case apiToken
    /// Session or token in the JSON-RPC `auth` property after `user.login`.
    case legacy

    static let `default`: ZabbixAuthMode = .apiToken

    /// Upgrade path when Settings has never written `zabbixAuthMode`.
    /// A stored API user means the old username+password install; keep body auth
    /// until the operator picks Bearer. Empty user is a new Bearer setup.
    static func resolved(storedRawValue: String?, hasUsername: Bool) -> ZabbixAuthMode {
        if let storedRawValue, let mode = ZabbixAuthMode(rawValue: storedRawValue) {
            return mode
        }
        return hasUsername ? .legacy : .apiToken
    }
}
