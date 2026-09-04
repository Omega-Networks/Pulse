//
//  SubscriptionTier.swift
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

/// Hard-coded caps. Prices live in App Store Connect.
enum SubscriptionTier: String, Sendable, Equatable, CaseIterable {
    case free
    case growth
    case pro
    case unlimited

    /// Nil means no cap.
    var maxSeats: Int? {
        switch self {
        case .free: return 50
        case .growth: return 250
        case .pro: return 1_500
        case .unlimited: return nil
        }
    }

    var displayName: String {
        switch self {
        case .free: return "Free"
        case .growth: return "Growth"
        case .pro: return "Pro"
        case .unlimited: return "Unlimited"
        }
    }

    /// Higher wins when more than one entitlement is active.
    var rank: Int {
        switch self {
        case .free: return 0
        case .growth: return 1
        case .pro: return 2
        case .unlimited: return 3
        }
    }

    /// Product IDs are `<bundleID>.<tier>.<period>`. Match by suffix so a
    /// fork's `BUNDLE_IDENTIFIER` does not need a code change.
    static let productSuffixes: [String: SubscriptionTier] = [
        "growth.monthly": .growth,
        "growth.annual": .growth,
        "pro.monthly": .pro,
        "pro.annual": .pro,
        "unlimited.monthly": .unlimited,
        "unlimited.annual": .unlimited,
    ]

    /// StoreKit files and receipts that still use the Plus product IDs.
    static let legacyProductSuffixes: [String: SubscriptionTier] = [
        "plus.monthly": .growth,
        "plus.annual": .growth,
    ]

    static let subscriptionGroupID = "pulse.device-capacity"

    /// Product IDs for `SubscriptionStoreView`. Local StoreKit testing
    /// and App Store Connect both resolve these; a group-ID lookup hits
    /// the live storefront and fails when the group is not in ASC.
    static var storeProductIDs: [String] {
        productSuffixes.keys
            .map { PulseDistribution.productID($0) }
            .sorted()
    }

    static func from(productID: String) -> SubscriptionTier? {
        for (suffix, tier) in productSuffixes where productID.hasSuffix(".\(suffix)") || productID == suffix {
            return tier
        }
        for (suffix, tier) in legacyProductSuffixes where productID.hasSuffix(".\(suffix)") || productID == suffix {
            return tier
        }
        return nil
    }

    static func highest(of tiers: [SubscriptionTier]) -> SubscriptionTier {
        tiers.max(by: { $0.rank < $1.rank }) ?? .free
    }

    /// Paid plans shown on the paywall, cheapest first.
    static let purchaseTiers: [SubscriptionTier] = [.growth, .pro, .unlimited]

    var seatCaption: String {
        if let maxSeats {
            return "\(maxSeats.formatted()) devices"
        }
        return "No device cap"
    }

    func suffix(annual: Bool) -> String {
        "\(rawValue).\(annual ? "annual" : "monthly")"
    }

    static func period(from productID: String) -> BillingPeriod? {
        if productID.hasSuffix(".annual") { return .annual }
        if productID.hasSuffix(".monthly") { return .monthly }
        return nil
    }

    func capReachedMessage() -> String {
        switch self {
        case .free:
            return "Free tier limit reached (50 devices). Upgrade to Growth for up to 250 devices, Pro for up to 1,500, or Unlimited."
        case .growth:
            return "Growth tier limit reached (250 devices). Upgrade to Pro for up to 1,500 devices, or Unlimited."
        case .pro:
            return "Pro tier limit reached (1,500 devices). Upgrade to Unlimited."
        case .unlimited:
            return "Unlimited has no device cap."
        }
    }

    func meterLabel(seated: Int) -> String {
        if let maxSeats {
            return "\(seated) of \(maxSeats) seated"
        }
        return "\(seated) seated (Unlimited)"
    }
}

enum BillingPeriod: String, Sendable, Equatable {
    case monthly
    case annual
}

/// Maps StoreKit current entitlement vs auto-renew preference to the
/// tier Pulse should use now. Upgrades apply immediately; downgrades
/// stay pending until the current period ends.
struct EntitlementResolution: Equatable, Sendable {
    var tier: SubscriptionTier
    var pending: SubscriptionTier?
    var period: BillingPeriod?

    static func resolve(
        entitled: SubscriptionTier,
        entitledPeriod: BillingPeriod?,
        autoRenew: SubscriptionTier?,
        autoRenewPeriod: BillingPeriod?
    ) -> EntitlementResolution {
        guard let autoRenew, autoRenew != entitled else {
            return EntitlementResolution(tier: entitled, pending: nil, period: entitledPeriod)
        }
        if autoRenew.rank > entitled.rank {
            return EntitlementResolution(
                tier: autoRenew,
                pending: nil,
                period: autoRenewPeriod ?? entitledPeriod
            )
        }
        return EntitlementResolution(tier: entitled, pending: autoRenew, period: entitledPeriod)
    }
}

enum SubscriptionPricing {
    /// Whole-percent saving of annual versus 12 × monthly. Nil if annual is not cheaper.
    static func annualSavingsPercent(monthly: Decimal, annual: Decimal) -> Int? {
        let yearOfMonthly = monthly * 12
        guard yearOfMonthly > 0, annual < yearOfMonthly else { return nil }
        var percent = ((yearOfMonthly - annual) / yearOfMonthly) * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &percent, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }
}

enum EntitlementStorage {
    static let key = "pulse.subscriptionTier"
    static let periodKey = "pulse.subscriptionPeriod"

    static func load(from defaults: UserDefaults = .standard) -> (tier: SubscriptionTier, period: BillingPeriod?) {
        let raw = defaults.string(forKey: key)
        let tier: SubscriptionTier
        if let raw, let parsed = SubscriptionTier(rawValue: raw) {
            tier = parsed
        } else if raw == "plus" {
            tier = .growth
        } else {
            tier = .free
        }
        let period = defaults.string(forKey: periodKey).flatMap(BillingPeriod.init(rawValue:))
        return (tier, tier == .free ? nil : period)
    }

    static func save(
        tier: SubscriptionTier,
        period: BillingPeriod?,
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(tier.rawValue, forKey: key)
        if let period, tier != .free {
            defaults.set(period.rawValue, forKey: periodKey)
        } else {
            defaults.removeObject(forKey: periodKey)
        }
    }
}

enum BillingError: Error, Equatable, LocalizedError, Sendable {
    case deviceNotSeated
    case linkRequiresBothSeats
    case tierCapReached(SubscriptionTier)
    case eligibilityChangeAtCap

    var errorDescription: String? {
        switch self {
        case .deviceNotSeated:
            return "Subscribe to resume."
        case .linkRequiresBothSeats:
            return "Subscribe to resume. Both ends of a cable must be seated."
        case .tierCapReached(let tier):
            return tier.capReachedMessage()
        case .eligibilityChangeAtCap:
            return SubscriptionTier.free.capReachedMessage()
        }
    }
}
