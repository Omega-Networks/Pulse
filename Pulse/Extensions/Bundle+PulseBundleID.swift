//
//  Bundle+PulseBundleID.swift
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
import OSLog

/// Resolved Pulse bundle identifier with a loud fallback path. Used
/// by Keychain service-name construction so a misconfigured test or
/// CI environment surfaces the gap rather than silently routing
/// through the production literal.
///
/// **Production path.** `Bundle.main.bundleIdentifier` resolves to
/// the app's signed bundle ID (`nz.net.omega.pulse` in shipping
/// builds, or whatever `BUNDLE_IDENTIFIER` is set to in
/// `Development.xcconfig`). Returns it verbatim.
///
/// **Fallback path.** `Bundle.main.bundleIdentifier` is `nil` only
/// when the running binary is not bundled (test harnesses,
/// command-line tools, certain CI shapes). In that case:
///
/// - Logger.fault on the `pulse` subsystem / `bundle.config`
///   category so the gap appears in unified logs and any SIEM
///   ingesting `os_log` faults.
/// - In DEBUG, `assertionFailure` so the test fails loudly rather
///   than silently using the production literal (which would mask
///   Keychain-isolation regressions during test runs).
/// - In Release, fall back to the production literal because the
///   alternative — failing closed — would lose access to the
///   operator's Keychain entries. Resilience over strictness on
///   the user-facing path.
///
/// `callSite` is captured automatically from `#function` so the
/// fault message identifies which caller triggered the fallback;
/// the bundle ID itself does not carry that context.
func pulseBundleID(callSite: StaticString = #function) -> String {
    if let id = Bundle.main.bundleIdentifier {
        return id
    }
    let logger = Logger(subsystem: "pulse", category: "bundle.config")
    logger.fault("Bundle.main.bundleIdentifier was nil at \(String(describing: callSite), privacy: .public); falling back to production literal — this indicates a misconfigured test or CI environment.")
    #if DEBUG
    assertionFailure("pulseBundleID() invoked outside a bundled context. If this fires in a test, configure Bundle.main or inject the bundle ID explicitly.")
    #endif
    return "nz.net.omega.pulse"
}
