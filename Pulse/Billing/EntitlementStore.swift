//
//  EntitlementStore.swift
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
import Observation
#if canImport(StoreKit)
import StoreKit
#endif
#if os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// StoreKit 2 entitlements. Listener starts at launch, before UI.
@Observable
final class EntitlementStore: @unchecked Sendable {
    var tier: SubscriptionTier {
        didSet {
            guard previewTier == nil else { return }
            EntitlementStorage.save(tier: tier, period: billingPeriod, to: defaults)
        }
    }
    /// Monthly vs annual of the active product. Nil on Free.
    var billingPeriod: BillingPeriod? {
        didSet {
            guard previewTier == nil else { return }
            EntitlementStorage.save(tier: tier, period: billingPeriod, to: defaults)
        }
    }
    /// Next renewal or period end from StoreKit. Nil on Free.
    var periodEnd: Date?
    /// Lower (or other) tier Apple will apply at `periodEnd`. Nil if no change queued.
    var pendingTier: SubscriptionTier?
    /// Set in tests. When non-nil, StoreKit is not consulted.
    private let previewTier: SubscriptionTier?
    private let defaults: UserDefaults

    init(previewTier: SubscriptionTier? = nil, defaults: UserDefaults = .standard) {
        self.previewTier = previewTier
        self.defaults = defaults
        let stored = EntitlementStorage.load(from: defaults)
        self.tier = previewTier ?? stored.tier
        self.billingPeriod = previewTier == nil ? stored.period : nil
        self.periodEnd = nil
        self.pendingTier = nil
    }

    /// Settings line. StoreKit dates are absolute; format in the
    /// operator's current time zone (not UTC, not the storefront).
    var periodCaption: String? {
        guard tier != .free, let end = periodEnd else { return nil }
        let when = end.formatted(Self.localPeriodStyle)
        if let pendingTier {
            return "Changes to \(pendingTier.displayName) on \(when)"
        }
        return "Renews \(when)"
    }

    private static let localPeriodStyle = Date.FormatStyle(
        date: .abbreviated,
        time: .shortened,
        locale: .autoupdatingCurrent,
        calendar: .autoupdatingCurrent,
        timeZone: .autoupdatingCurrent
    )

    func isCurrent(tier: SubscriptionTier, annual: Bool) -> Bool {
        self.tier == tier && billingPeriod == (annual ? .annual : .monthly)
    }

    func isOtherPeriod(of tier: SubscriptionTier, annual: Bool) -> Bool {
        self.tier == tier && billingPeriod != nil && !isCurrent(tier: tier, annual: annual)
    }

    /// Call from `PulseApp.init` so updates run before first paint.
    func startAtLaunch() {
        if previewTier != nil { return }
        Task { await self.refresh() }
        Task { await self.finishUnfinished() }
        Task { await self.listenUpdates() }
        Task { await self.listenSubscriptionStatus() }
        Task { await self.listenActivation() }
    }

    func finishUnfinished() async {
        #if canImport(StoreKit)
        for await result in Transaction.unfinished {
            await handle(result)
        }
        #endif
    }

    func listenUpdates() async {
        #if canImport(StoreKit)
        for await result in Transaction.updates {
            await handle(result)
        }
        #endif
    }

    func listenSubscriptionStatus() async {
        #if canImport(StoreKit)
        for await _ in Product.SubscriptionInfo.Status.updates {
            await refresh()
        }
        #endif
    }

    /// StoreKit Testing and the macOS subscriptions page change the
    /// plan while Pulse is in the background. Refresh on become-active
    /// so an upgrade is not stuck until the next cold start.
    func listenActivation() async {
        #if os(macOS)
        let name = NSApplication.didBecomeActiveNotification
        #elseif os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #else
        return
        #endif
        for await _ in NotificationCenter.default.notifications(named: name) {
            await refresh()
        }
    }

    func refresh() async {
        if let previewTier {
            await publish(tier: previewTier, period: nil, periodEnd: nil, pending: nil)
            return
        }
        #if canImport(StoreKit)
        var entitled = SubscriptionTier.free
        var entitledPeriod: BillingPeriod?
        var bestProductID: String?
        var bestExpiration: Date?
        for await result in Transaction.currentEntitlements {
            guard let next = Self.tier(from: result),
                  let productID = Self.productID(from: result),
                  let period = SubscriptionTier.period(from: productID),
                  case .verified(let transaction) = result else {
                continue
            }
            if next.rank >= entitled.rank {
                entitled = next
                entitledPeriod = period
                bestProductID = productID
                bestExpiration = transaction.expirationDate
            }
        }
        var autoRenew: SubscriptionTier?
        var autoRenewPeriod: BillingPeriod?
        var end = bestExpiration
        if let bestProductID,
           let product = try? await Product.products(for: [bestProductID]).first,
           let statuses = try? await product.subscription?.status {
            for status in statuses {
                guard case .verified(let info) = status.renewalInfo else { continue }
                if let nextID = info.autoRenewPreference {
                    autoRenew = SubscriptionTier.from(productID: nextID)
                    autoRenewPeriod = SubscriptionTier.period(from: nextID)
                }
                if let date = info.renewalDate {
                    end = date
                }
            }
        }
        let resolved = EntitlementResolution.resolve(
            entitled: entitled,
            entitledPeriod: entitledPeriod,
            autoRenew: autoRenew,
            autoRenewPeriod: autoRenewPeriod
        )
        await publish(
            tier: resolved.tier,
            period: resolved.period,
            periodEnd: resolved.tier == .free ? nil : end,
            pending: resolved.pending
        )
        #else
        await publish(tier: .free, period: nil, periodEnd: nil, pending: nil)
        #endif
    }

    @MainActor
    private func publish(
        tier: SubscriptionTier,
        period: BillingPeriod?,
        periodEnd: Date?,
        pending: SubscriptionTier?
    ) {
        self.periodEnd = periodEnd
        self.pendingTier = pending
        self.billingPeriod = period
        self.tier = tier
    }

    func restore() async {
        #if canImport(StoreKit)
        try? await AppStore.sync()
        #endif
        await refresh()
    }

    /// Opens Apple's subscription sheet. Apps cannot cancel a sub themselves.
    func openManageSubscriptions() async {
        #if canImport(StoreKit)
        #if os(iOS)
        let scene = await MainActor.run {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        }
        if let scene {
            try? await AppStore.showManageSubscriptions(in: scene)
        }
        #elseif os(macOS)
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            NSWorkspace.shared.open(url)
        }
        #endif
        #endif
        await refresh()
    }

    #if canImport(StoreKit)
    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            await handle(verification)
            await refresh()
            return true
        case .userCancelled, .pending:
            return false
        @unknown default:
            return false
        }
    }
    #endif

    #if canImport(StoreKit)
    private func handle(_ result: VerificationResult<Transaction>) async {
        await Self.finish(result)
        await refresh()
    }

    private static func productID(from result: VerificationResult<Transaction>) -> String? {
        guard case .verified(let transaction) = result else { return nil }
        if transaction.revocationDate != nil { return nil }
        // currentEntitlements already encodes Apple's billing-retry /
        // grace period. A past expirationDate here is not a lapse.
        if transaction.ownershipType == .familyShared {
            assertionFailure("Family Sharing is off on Pulse subscriptions")
            return nil
        }
        return transaction.productID
    }

    private static func tier(from result: VerificationResult<Transaction>) -> SubscriptionTier? {
        guard let productID = productID(from: result) else { return nil }
        return SubscriptionTier.from(productID: productID)
    }

    private static func finish(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .verified(let transaction):
            await transaction.finish()
        case .unverified:
            // Leave in Transaction.unfinished so the next cold start
            // can retry verification. Never grant, never consume.
            break
        }
    }
    #endif
}
