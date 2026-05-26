//
//  SSHCredentialTier+Extensions.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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
