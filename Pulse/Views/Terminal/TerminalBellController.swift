//
//  TerminalBellController.swift
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
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Fires the platform-correct audible bell. macOS uses `NSSound.beep`
/// which respects the operator's Sound preferences (alert sound,
/// system volume) so the bell composes with macOS-wide audio settings.
/// iOS uses a warning haptic instead of audio because most ops happen
/// on devices in silent mode; the haptic is registered as "warning"
/// rather than "notification" so it does not also trigger the iOS
/// notification sound the latter would normally pair with.
@MainActor
func fireAudibleBell() {
    #if os(macOS)
    NSSound.beep()
    #else
    let generator = UINotificationFeedbackGenerator()
    generator.notificationOccurred(.warning)
    #endif
}

/// Drives both the audible bell rate-limit and the visual-bell flash
/// overlay for `SSHTerminalView.terminalArea`. Lives in a reference
/// type so the @Sendable bell closure captures the controller rather
/// than the View struct's @State; @State capture across @Sendable
/// closure boundaries is fragile in Swift 6 strict concurrency, and a
/// tiny @MainActor class is simpler than fighting the type system.
///
/// **Why both responsibilities here.** The visual flash gets natural
/// coalescing for free via `resetTask?.cancel()` — overlapping bells
/// hold the overlay at full opacity until the storm subsides, then
/// fade cleanly. The audible path needs its own gate because
/// `NSSound.beep()` and `UINotificationFeedbackGenerator` queue per
/// call with no built-in coalesce, so a server sending `\a` in a loop
/// would produce one beep per event — operator-disrupting at best,
/// weaponisable against an open-plan ops room at worst. The 250 ms
/// gate caps the audible rate at ~4 Hz, which is faster than a human
/// can distinguish individual beeps anyway but slow enough to remain
/// recognisable as a bell rather than a continuous tone.
///
/// File-scope (no `private`) so `@testable import Pulse` reaches the
/// type — the rate-limit gate is a property the slice exists to
/// deliver and tests pay rent on confirming it holds.
///
/// Lives in its own file per the Omega Swift convention of one type
/// per file for non-view types; previously sat at file scope inside
/// `SSHTerminalView.swift` alongside the view struct.
@MainActor
final class TerminalBellController: ObservableObject {

    /// Minimum gap between audible bell firings. Set on the type so
    /// tests can reference the same constant rather than hard-coding
    /// the duration, and any future tuning lands in one place.
    static let audibleBellGate: TimeInterval = 0.25

    @Published var isFlashing = false

    private var resetTask: Task<Void, Never>?

    /// Timestamp of the last audible bell that made it past the gate.
    /// `nil` until the first request. Bells within `audibleBellGate`
    /// of this value are dropped silently.
    private var lastAudibleAt: Date?

    /// Test seam. Counts every audible bell that actually fired
    /// through the gate (i.e. was *not* rate-limited). Tests assert
    /// the gate by triggering N bells inside the window and checking
    /// this value equals 1.
    private(set) var audibleBellFireCount: Int = 0

    /// Audible bell request. Drops the request silently when the
    /// previous audible fired within `audibleBellGate`. Otherwise
    /// records the time, increments the test-observable counter, and
    /// invokes the platform helper. The `now:` parameter is the
    /// inject-the-clock test seam; production callers leave it at the
    /// default.
    func requestAudibleBell(now: Date = Date()) {
        if let last = lastAudibleAt, now.timeIntervalSince(last) < Self.audibleBellGate {
            return
        }
        lastAudibleAt = now
        audibleBellFireCount += 1
        fireAudibleBell()
    }

    /// 120 ms visual flash beat. Long enough to register peripherally;
    /// short enough not to obscure terminal contents on a server
    /// emitting repeated bells (e.g. a runaway script). Repeated calls
    /// cancel the in-flight reset task so the overlay holds at full
    /// opacity until the bell storm subsides, then fades cleanly. No
    /// rate gate is needed here because the cancel-and-reschedule
    /// pattern coalesces visually for free.
    func trigger() {
        isFlashing = true
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.isFlashing = false
        }
    }
}
