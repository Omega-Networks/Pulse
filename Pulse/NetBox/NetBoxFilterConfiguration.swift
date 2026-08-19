//
//  NetBoxFilterConfiguration.swift
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

/// Sync scope is the whole NetBox instance.
///
/// Pulse used to omit manufacturer 5 (Generic) and roles 29/30 from the
/// device / role / interface pull, then re-fetch filler roles 6/7/18/27
/// so the rack elevation had blanks and panels. That split is gone.
/// Every device, device type, and device role is stored. Fetch and
/// delete stay aligned (P1).
///
/// What the operator sees, and which devices will count toward a
/// future per-device license, is `RolePresentation` (Settings → Roles).
/// Do not add `manufacturer_id__n` or `role_id__n` query items here.
struct NetBoxFilterConfiguration: Sendable, Equatable, Hashable {
    static let `default` = NetBoxFilterConfiguration()
}
