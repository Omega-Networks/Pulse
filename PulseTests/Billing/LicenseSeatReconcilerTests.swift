//
//  LicenseSeatReconcilerTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  Under the terms of the GNU Affero General Public License version 3 as published by the
//  Free Software Foundation, this program is free software: communities can deploy it for
//  sovereignty, academia can extend it for research, and industry can integrate it for resilience.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import XCTest
@testable import Pulse

final class LicenseSeatReconcilerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let older = Date(timeIntervalSince1970: 1_600_000_000)
    private let newest = Date(timeIntervalSince1970: 1_800_000_000)

    private var presentation: RolePresentation {
        RolePresentation.omegaDefault()
    }

    private func snap(
        id: Int64,
        role: Int64? = 1,
        created: Date? = nil,
        grant: Date? = nil
    ) -> SeatSnapshot {
        SeatSnapshot(id: id, roleID: role, created: created, seatGrantedAt: grant)
    }

    func testFillersAreNotEligible() {
        let devices = [
            snap(id: 1, role: 6, created: older),
            snap(id: 2, role: 1, created: older),
        ]
        let result = LicenseSeatReconciler.reconcile(
            devices: devices, presentation: presentation, cap: 50, now: now
        )
        XCTAssertEqual(result.effectiveIDs, [2])
        XCTAssertNil(result.grant(for: 1))
        XCTAssertEqual(result.grant(for: 2), now)
    }

    func testMissingRoleCountsAsOperatorDevice() {
        let devices = [snap(id: 9, role: nil, created: older)]
        let result = LicenseSeatReconciler.reconcile(
            devices: devices, presentation: presentation, cap: 50, now: now
        )
        XCTAssertEqual(result.effectiveIDs, [9])
    }

    func testIdenticalInputsSeatAnIdenticalSet() {
        let devices = (1...5).map { snap(id: $0, created: older.addingTimeInterval(TimeInterval($0))) }
        let first = LicenseSeatReconciler.reconcile(
            devices: devices, presentation: presentation, cap: 3, now: now
        )
        let after: [SeatSnapshot] = devices.map { row in
            var next = row
            next.seatGrantedAt = first.grant(for: row.id)
            return next
        }
        let second = LicenseSeatReconciler.reconcile(
            devices: after, presentation: presentation, cap: 3, now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(first.effectiveIDs, second.effectiveIDs)
        XCTAssertEqual(first.effectiveIDs, [1, 2, 3])
    }

    func testShrinkKeepsOldestGrantsAndDoesNotEraseNewer() {
        let devices = [
            snap(id: 1, created: older, grant: older),
            snap(id: 2, created: older, grant: now),
            snap(id: 3, created: older, grant: newest),
        ]
        let result = LicenseSeatReconciler.reconcile(
            devices: devices, presentation: presentation, cap: 2, now: newest
        )
        XCTAssertEqual(result.effectiveIDs, [1, 2])
        XCTAssertEqual(result.grant(for: 3), newest)
        XCTAssertFalse(LicenseSeatReconciler.allowsActions(
            deviceID: 3, devices: devices, presentation: presentation, cap: 2
        ))
    }

    func testHardwareCanBeMovedWithoutASeat() {
        let devices = [
            snap(id: 1, role: 6, created: older),
            snap(id: 2, role: 1, created: older, grant: older),
        ]
        XCTAssertTrue(LicenseSeatReconciler.allowsRackEdit(
            deviceID: 1, roleID: 6, devices: devices, presentation: presentation, cap: 1
        ))
        XCTAssertTrue(LicenseSeatReconciler.allowsRackEdit(
            deviceID: 2, roleID: 1, devices: devices, presentation: presentation, cap: 1
        ))
        XCTAssertFalse(LicenseSeatReconciler.allowsRackEdit(
            deviceID: 99, roleID: 1, devices: devices, presentation: presentation, cap: 1
        ))
        XCTAssertTrue(LicenseSeatReconciler.allowsActions(
            deviceID: 1, devices: devices, presentation: presentation, cap: 1
        ))
    }

    func testLinkWithOneHardwareEnd() {
        let devices = [
            snap(id: 1, role: 6, created: older),
            snap(id: 2, role: 1, created: older, grant: older),
            snap(id: 3, role: 1, created: older),
        ]
        XCTAssertTrue(LicenseSeatReconciler.allowsLink(
            a: 1, b: 2, devices: devices, presentation: presentation, cap: 1
        ))
        XCTAssertFalse(LicenseSeatReconciler.allowsLink(
            a: 1, b: 3, devices: devices, presentation: presentation, cap: 1
        ))
        XCTAssertTrue(LicenseSeatReconciler.allowsLink(
            a: 1, b: 7, devices: devices + [snap(id: 7, role: 18, created: older)],
            presentation: presentation, cap: 1
        ))
    }

    func testHardwareGrantDoesNotShadowASlot() {
        let devices = [
            snap(id: 1, role: 6, created: older, grant: older),
            snap(id: 2, role: 1, created: older, grant: nil),
        ]
        let result = LicenseSeatReconciler.reconcile(
            devices: devices, presentation: presentation, cap: 1, now: now
        )
        XCTAssertEqual(result.effectiveIDs, [2])
        XCTAssertNil(result.grant(for: 1))
    }

    func testFillUsesOldestCreatedThenID() {
        let devices = [
            snap(id: 3, created: now),
            snap(id: 1, created: older),
            snap(id: 2, created: older),
        ]
        let result = LicenseSeatReconciler.reconcile(
            devices: devices, presentation: presentation, cap: 2, now: newest
        )
        XCTAssertEqual(result.effectiveIDs, [1, 2])
    }

    func testUnlimitedSeatsEveryEligibleDevice() {
        let devices = (1...5).map { snap(id: $0, created: older) }
        let result = LicenseSeatReconciler.reconcile(
            devices: devices, presentation: presentation, cap: nil, now: now
        )
        XCTAssertEqual(result.effectiveIDs.count, 5)
    }

    func testLinkRequiresBothEndsSeated() {
        let devices = [
            snap(id: 1, created: older, grant: older),
            snap(id: 2, created: older, grant: now),
            snap(id: 3, created: older, grant: newest),
        ]
        XCTAssertTrue(LicenseSeatReconciler.allowsLink(
            a: 1, b: 2, devices: devices, presentation: presentation, cap: 2
        ))
        XCTAssertFalse(LicenseSeatReconciler.allowsLink(
            a: 1, b: 3, devices: devices, presentation: presentation, cap: 2
        ))
    }

    func testCanAdmitEligibleRespectsCap() {
        let devices = [
            snap(id: 1, created: older, grant: older),
            snap(id: 2, created: older, grant: now),
        ]
        XCTAssertFalse(LicenseSeatReconciler.canAdmitEligible(
            additional: 1, devices: devices, presentation: presentation, cap: 2
        ))
        XCTAssertTrue(LicenseSeatReconciler.canAdmitEligible(
            additional: 1, devices: devices, presentation: presentation, cap: 3
        ))
    }

    func testPeriodIsParsedFromProductID() {
        XCTAssertEqual(SubscriptionTier.period(from: "org.example.pulse.plus.annual"), .annual)
        XCTAssertEqual(SubscriptionTier.period(from: "org.example.pulse.pro.monthly"), .monthly)
        XCTAssertNil(SubscriptionTier.period(from: "org.example.pulse.plus"))
    }

    func testAnnualSavingsPercentIsComputedFromMonthly() {
        XCTAssertEqual(
            SubscriptionPricing.annualSavingsPercent(monthly: 9.99, annual: 99),
            17
        )
        XCTAssertEqual(
            SubscriptionPricing.annualSavingsPercent(monthly: 4.99, annual: 49.99),
            17
        )
        XCTAssertEqual(
            SubscriptionPricing.annualSavingsPercent(monthly: 24.99, annual: 249.99),
            17
        )
        XCTAssertEqual(
            SubscriptionPricing.annualSavingsPercent(monthly: 14.99, annual: 149.99),
            17
        )
        XCTAssertNil(SubscriptionPricing.annualSavingsPercent(monthly: 10, annual: 120))
        XCTAssertNil(SubscriptionPricing.annualSavingsPercent(monthly: 10, annual: 130))
    }

    func testTierCapsMatchPricingTable() {
        XCTAssertEqual(SubscriptionTier.free.maxSeats, 50)
        XCTAssertEqual(SubscriptionTier.growth.maxSeats, 250)
        XCTAssertEqual(SubscriptionTier.pro.maxSeats, 1_500)
        XCTAssertNil(SubscriptionTier.unlimited.maxSeats)
    }

    func testProductIDsMatchBundleSuffix() {
        XCTAssertEqual(SubscriptionTier.storeProductIDs.count, 6)
        XCTAssertTrue(SubscriptionTier.storeProductIDs.allSatisfy { id in
            SubscriptionTier.from(productID: id) != nil
        })
        XCTAssertEqual(SubscriptionTier.from(productID: "com.example.pulse.growth.monthly"), .growth)
        XCTAssertEqual(SubscriptionTier.from(productID: "com.example.pulse.plus.monthly"), .growth)
        XCTAssertEqual(SubscriptionTier.from(productID: "nz.net.example.pulse.pro.annual"), .pro)
        XCTAssertEqual(
            SubscriptionTier.from(productID: PulseDistribution.productID("unlimited.monthly", bundleID: "org.fork.pulse")),
            .unlimited
        )
        XCTAssertNil(SubscriptionTier.from(productID: "com.example.pulse.unknown.monthly"))
    }

    func testMarketingHostIsDerivedFromBundleID() {
        XCTAssertEqual(
            PulseDistribution.hostDerivedFromBundleID("nz.net.example.pulse"),
            "example.net.nz"
        )
        XCTAssertEqual(
            PulseDistribution.hostDerivedFromBundleID("com.yourorg.pulse"),
            "yourorg.com"
        )
        XCTAssertEqual(
            PulseDistribution.marketingHost(
                bundleID: "com.yourorg.pulse",
                info: ["PulseMarketingHost": "docs.example.org"]
            ),
            "docs.example.org"
        )
        XCTAssertEqual(
            PulseDistribution.privacyURL(bundleID: "com.yourorg.pulse")?.absoluteString,
            "https://yourorg.com/pulse/privacy"
        )
        XCTAssertEqual(
            PulseDistribution.privacyURL(bundleID: "nz.net.example.pulse")?.absoluteString,
            "https://example.net.nz/pulse/privacy"
        )
        XCTAssertEqual(
            PulseDistribution.termsURL(bundleID: "nz.net.example.pulse")?.absoluteString,
            "https://example.net.nz/pulse/terms"
        )
    }

    func testUpgradeAppliesImmediatelyAndDowngradeStaysPending() {
        let upgrade = EntitlementResolution.resolve(
            entitled: .growth,
            entitledPeriod: .monthly,
            autoRenew: .pro,
            autoRenewPeriod: .monthly
        )
        XCTAssertEqual(upgrade.tier, .pro)
        XCTAssertNil(upgrade.pending)
        XCTAssertEqual(upgrade.period, .monthly)

        let unlimited = EntitlementResolution.resolve(
            entitled: .pro,
            entitledPeriod: .annual,
            autoRenew: .unlimited,
            autoRenewPeriod: .annual
        )
        XCTAssertEqual(unlimited.tier, .unlimited)
        XCTAssertNil(unlimited.pending)

        let downgrade = EntitlementResolution.resolve(
            entitled: .unlimited,
            entitledPeriod: .monthly,
            autoRenew: .growth,
            autoRenewPeriod: .monthly
        )
        XCTAssertEqual(downgrade.tier, .unlimited)
        XCTAssertEqual(downgrade.pending, .growth)
        XCTAssertEqual(downgrade.period, .monthly)

        let unchanged = EntitlementResolution.resolve(
            entitled: .growth,
            entitledPeriod: .annual,
            autoRenew: .growth,
            autoRenewPeriod: .annual
        )
        XCTAssertEqual(unchanged.tier, .growth)
        XCTAssertNil(unchanged.pending)
    }

    func testRestoreReenablesSurvivingGrantsThenFills() {
        let devices = [
            snap(id: 1, created: older, grant: older),
            snap(id: 2, created: older, grant: now),
            snap(id: 3, created: older, grant: newest),
            snap(id: 4, created: older.addingTimeInterval(-10)),
        ]
        let shrunk = LicenseSeatReconciler.reconcile(
            devices: devices, presentation: presentation, cap: 2, now: newest
        )
        XCTAssertEqual(shrunk.effectiveIDs, [1, 2])
        XCTAssertEqual(shrunk.grant(for: 3), newest)
        XCTAssertNil(shrunk.grant(for: 4))

        let afterShrink: [SeatSnapshot] = devices.map { row in
            var next = row
            if let boxed = shrunk.grants[row.id] {
                next.seatGrantedAt = boxed
            }
            return next
        }
        let later = newest.addingTimeInterval(60)
        let restored = LicenseSeatReconciler.reconcile(
            devices: afterShrink, presentation: presentation, cap: 4, now: later
        )
        XCTAssertEqual(restored.effectiveIDs, [1, 2, 3, 4])
        XCTAssertEqual(restored.grant(for: 3), newest)
        XCTAssertEqual(restored.grant(for: 4), later)
    }

    func testApplyPastCapLeavesNewDevicesUnseated() {
        let devices = [
            snap(id: 1, created: older, grant: older),
            snap(id: 2, created: older, grant: now),
            snap(id: 99, created: newest),
        ]
        let result = LicenseSeatReconciler.reconcile(
            devices: devices, presentation: presentation, cap: 2, now: newest
        )
        XCTAssertEqual(result.effectiveIDs, [1, 2])
        XCTAssertNil(result.grant(for: 99))
    }

    func testEligibilityAddingAtCapIsRefusedAndHardwareChangeIsAllowed() {
        let devices = [
            snap(id: 1, created: older, grant: older),
            snap(id: 2, created: older, grant: now),
        ]
        XCTAssertFalse(LicenseSeatReconciler.canAdmitEligible(
            additional: 1, devices: devices, presentation: presentation, cap: 2
        ))
        XCTAssertTrue(LicenseSeatReconciler.canAdmitEligible(
            additional: 0, devices: devices, presentation: presentation, cap: 2
        ))
    }
}
