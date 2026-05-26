//
//  SSHCredentialTier+Extensions.swift
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
//  extend it for research, and industry can integrate it for resilience, all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation

extension SSHCredentialTier {

    /// Compact label for tight surfaces like picker rows. Used by the
    /// debug SSH menu's credential picker, where the row already shows
    /// the credential's full name and only needs a short tier tag.
    var label: String {
        switch self {
        case .secureEnclave: return "SE"
        case .portable: return "Legacy"
        }
    }

    /// Full display name for prominent surfaces like the Settings tier
    /// badge. The picker uses `label`; the badge uses `displayName`.
    /// Both are derived from the same source of truth so a future rename
    /// only edits one switch.
    var displayName: String {
        switch self {
        case .secureEnclave: return "Secure Enclave"
        case .portable: return "Legacy"
        }
    }
}
