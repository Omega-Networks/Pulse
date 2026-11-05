//
//  ProblemGhostEditAction.swift
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

import SwiftUI

/// Opens the problem update sheet with a failed ghost's fields.
/// The failed ask stays until that sheet submits. The default does
/// nothing, so a surface without the sheet still compiles.
struct ProblemGhostEditAction: Sendable {
    var isInstalled: Bool
    var open: @MainActor @Sendable (ProblemUpdateGhost) -> Void

    init(isInstalled: Bool = true, open: @escaping @MainActor @Sendable (ProblemUpdateGhost) -> Void) {
        self.isInstalled = isInstalled
        self.open = open
    }

    static let inactive = ProblemGhostEditAction(isInstalled: false) { _ in }
}

private struct ProblemGhostEditActionKey: EnvironmentKey {
    static let defaultValue = ProblemGhostEditAction.inactive
}

extension EnvironmentValues {
    var problemGhostEdit: ProblemGhostEditAction {
        get { self[ProblemGhostEditActionKey.self] }
        set { self[ProblemGhostEditActionKey.self] = newValue }
    }
}
