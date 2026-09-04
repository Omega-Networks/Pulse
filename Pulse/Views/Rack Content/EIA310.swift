//
//  EIA310.swift
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

import CoreGraphics

/// EIA-310-D / IEC 60297-3-100 19-inch rack geometry.
///
/// 1 RU is 1.75 in. A 19 in panel (blank, patch, shelf) spans the
/// mounting flanges. Typical equipment chassis is 17.75 in between
/// the rails. Each ear/flange is 0.625 in.
enum EIA310 {
    static let ruInches: CGFloat = 1.75
    static let panelWidthInches: CGFloat = 19
    static let chassisWidthInches: CGFloat = 17.75
    static let earInches: CGFloat = (panelWidthInches - chassisWidthInches) / 2

    /// Hole offsets from the top of a RU (0.25, 0.875, 1.50 in).
    static let holeOffsetsInches: [CGFloat] = [0.25, 0.875, 1.50]

    /// Pixels per inch so one RU is a usable on-screen height.
    static let pointsPerInch: CGFloat = 16

    static var ruHeight: CGFloat { ruInches * pointsPerInch }
    static var panelWidth: CGFloat { panelWidthInches * pointsPerInch }
    static var chassisWidth: CGFloat { chassisWidthInches * pointsPerInch }
    static var earWidth: CGFloat { earInches * pointsPerInch }

    static func unitHeight(pointsPerInch: CGFloat) -> CGFloat {
        ruInches * pointsPerInch
    }

    static func panelWidth(pointsPerInch: CGFloat) -> CGFloat {
        panelWidthInches * pointsPerInch
    }

    static func chassisWidth(pointsPerInch: CGFloat) -> CGFloat {
        chassisWidthInches * pointsPerInch
    }

    static func earWidth(pointsPerInch: CGFloat) -> CGFloat {
        earInches * pointsPerInch
    }

    static func height(units: CGFloat, pointsPerInch: CGFloat = pointsPerInch) -> CGFloat {
        unitHeight(pointsPerInch: pointsPerInch) * units
    }

    /// Lowest U under `y` (y = 0 at the top of the elevation).
    static func position(
        y: CGFloat,
        rackHeight: Int,
        pointsPerInch: CGFloat,
        uHeight: Float
    ) -> Float {
        let ru = unitHeight(pointsPerInch: pointsPerInch)
        guard ru > 0, rackHeight > 0 else { return 1 }
        let fromTop = max(0, y / ru)
        let step: Float = (uHeight.truncatingRemainder(dividingBy: 1) == 0) ? 1 : 0.5
        // Floor the distance from the top first so the whole RU
        // (not only its upper half) maps to that U. Using
        // rackHeight - fromTop then flooring slipped one unit down.
        let snapped = Float(rackHeight) - (Float(fromTop) / step).rounded(.down) * step
        return max(1, min(Float(rackHeight), snapped))
    }

    /// Y from the top of the elevation to the top of a device.
    /// NetBox `position` is the lowest occupied U.
    static func yOffset(
        position: Float,
        uHeight: Float,
        rackHeight: Int,
        pointsPerInch: CGFloat
    ) -> CGFloat {
        let ru = unitHeight(pointsPerInch: pointsPerInch)
        return CGFloat(Float(rackHeight) - position - max(0.5, uHeight) + 1) * ru
    }
}
