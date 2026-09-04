//
//  PulsePaywallView.swift
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
#if canImport(StoreKit)
import StoreKit
#endif

struct PulsePaywallView: View {
    @Environment(EntitlementStore.self) private var entitlements
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    var message: String
    var onDismiss: () -> Void

    @State private var payAnnually = true
    @State private var productsByID: [String: StoreProduct] = [:]
    @State private var loadError: String?
    @State private var isPurchasing = false
    @State private var selectedTier: SubscriptionTier? = .growth
    #if os(iOS)
    @State private var carouselHeight: CGFloat = 0
    #endif

    private var usesCarousel: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: usesCarousel ? 10 : 16) {
            header

            annualToggle

            if usesCarousel {
                #if os(iOS)
                productCarousel
                #endif
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(SubscriptionTier.purchaseTiers, id: \.self) { tier in
                        tierCard(tier)
                    }
                }
            }

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !usesCarousel {
                Divider()
            }

            footer
        }
        .padding(usesCarousel ? 16 : 20)
        .padding(.top, usesCarousel ? 4 : 0)
        .modifier(PaywallSheetChrome(compact: usesCarousel))
        .task { await loadProducts() }
        .onAppear { selectStartingTier() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subscribe to resume")
                .font(.title2.weight(.semibold))
                #if os(iOS)
                .foregroundStyle(Color.accentColor)
                #endif
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(usesCarousel ? 3 : 2)
        }
    }

    #if os(iOS)
    private var productCarousel: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(SubscriptionTier.purchaseTiers, id: \.self) { tier in
                        tierCard(tier)
                            .containerRelativeFrame(.horizontal) { width, _ in
                                width * 0.64
                            }
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: PaywallCardHeightKey.self,
                                        value: geo.size.height
                                    )
                                }
                            }
                            .id(tier)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selectedTier)
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 48, for: .scrollContent)
            .frame(height: carouselHeight > 0 ? carouselHeight : nil)
            .onPreferenceChange(PaywallCardHeightKey.self) { carouselHeight = $0 }

            HStack(spacing: 7) {
                ForEach(SubscriptionTier.purchaseTiers, id: \.self) { tier in
                    Circle()
                        .fill(tier == selectedTier ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.28)) {
                                selectedTier = tier
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Plan \(selectedTier?.displayName ?? "")")
        }
    }
    #endif

    @ViewBuilder
    private var footer: some View {
        if usesCarousel {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    legalLinks
                    Spacer(minLength: 8)
                    restoreAndManageButtons
                    closeButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    legalLinks
                    HStack {
                        restoreAndManageButtons
                        Spacer(minLength: 8)
                        closeButton
                    }
                }
            }
            .font(.subheadline)
        } else {
            HStack(alignment: .center, spacing: 12) {
                legalLinks
                    .font(.caption)
                Spacer(minLength: 12)
                restoreAndManageButtons
                closeButton
            }
        }
    }

    @ViewBuilder
    private var legalLinks: some View {
        if let privacyURL = PulseDistribution.privacyURL() {
            Link("Privacy Policy", destination: privacyURL)
        }
        if let termsURL = PulseDistribution.termsURL() {
            Link("Terms of Use", destination: termsURL)
        }
    }

    private var restoreAndManageButtons: some View {
        HStack(spacing: 16) {
            Button("Restore Purchases") {
                Task { @MainActor in
                    await entitlements.restore()
                }
            }
            Button("Unsubscribe") {
                Task { @MainActor in
                    await entitlements.openManageSubscriptions()
                }
            }
        }
        .disabled(isPurchasing)
        #if os(iOS)
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        #else
        .buttonStyle(.borderless)
        #endif
    }

    private var closeButton: some View {
        #if os(iOS)
        Button("Close", action: onDismiss)
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        #else
        Button("Close", role: .cancel, action: onDismiss)
            .keyboardShortcut(.cancelAction)
        #endif
    }

    private func selectStartingTier() {
        if SubscriptionTier.purchaseTiers.contains(entitlements.tier) {
            selectedTier = entitlements.tier
        }
    }

    private var annualToggle: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                periodSwitch
                Spacer(minLength: 8)
                annualSavingsCaption
            }
            VStack(alignment: .leading, spacing: 6) {
                periodSwitch
                HStack {
                    Spacer(minLength: 0)
                    annualSavingsCaption
                }
            }
        }
    }

    private var periodSwitch: some View {
        HStack(spacing: 8) {
            Text("Monthly")
                .font(.callout)
                .foregroundStyle(payAnnually ? .secondary : .primary)
            Toggle("Pay annually", isOn: annualBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Self.savingsColor)
            Text("Annually")
                .font(.callout)
                .foregroundStyle(payAnnually ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var annualSavingsCaption: some View {
        Group {
            if let percent = displayedSavingsPercent {
                Text("Pay annually, save up to \(percent)%")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Self.savingsColor)
                    .contentTransition(.numericText())
                    .opacity(payAnnually ? 0.45 : 1)
            }
        }
        .multilineTextAlignment(.trailing)
    }

    private var annualBinding: Binding<Bool> {
        Binding(
            get: { payAnnually },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.28)) {
                    payAnnually = newValue
                }
            }
        )
    }

    private var displayedSavingsPercent: Int? {
        let percents = SubscriptionTier.purchaseTiers.compactMap { savingsPercent(for: $0) }
        return percents.max()
    }

    private func tierCard(_ tier: SubscriptionTier) -> some View {
        let offered = product(for: tier, annual: payAnnually)
        let current = entitlements.isCurrent(tier: tier, annual: payAnnually)
        let switchPeriod = entitlements.isOtherPeriod(of: tier, annual: payAnnually)
        return VStack(alignment: .leading, spacing: 6) {
            Text(tier.displayName)
                .font(.headline)
            Text(tier.seatCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            priceBlock(for: tier)
            Button {
                guard let offered else { return }
                Task { await buy(offered) }
            } label: {
                Text(planButtonTitle(current: current, switchPeriod: switchPeriod))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .contentTransition(.opacity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle)
            .controlSize(.regular)
            .disabled(current || offered == nil || isPurchasing)
            .frame(maxWidth: .infinity)
            .padding(.top, usesCarousel ? 10 : 8)
        }
        .padding(usesCarousel ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardFill(tier, current: current, switchPeriod: switchPeriod))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    cardBorder(current: current, switchPeriod: switchPeriod),
                    lineWidth: current || switchPeriod ? 1.5 : 1
                )
        )
        .animation(.easeInOut(duration: 0.28), value: payAnnually)
    }

    private func priceBlock(for tier: SubscriptionTier) -> some View {
        let offered = product(for: tier, annual: true)
        let monthly = product(for: tier, annual: false)
        let percent = savingsPercent(for: tier) ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            Text("Save \(payAnnually ? percent : 0)%")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Self.savingsColor)
                .opacity(payAnnually ? 1 : 0)
                .contentTransition(.numericText())
                .accessibilityHidden(!payAnnually)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let monthly {
                    Text(payAnnually ? monthly.formatted(monthly.price * 12) : monthly.displayPrice)
                        .font(payAnnually ? .caption : .title3.weight(.semibold))
                        .foregroundStyle(payAnnually ? Color.secondary : Color.primary)
                        .modifier(DrawnStrikethrough(isOn: payAnnually))
                        .contentTransition(.numericText())
                }
                Text(offered?.displayPrice ?? " ")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Self.savingsColor)
                    .opacity(payAnnually ? 1 : 0)
                    .accessibilityHidden(!payAnnually)
                    .contentTransition(.numericText())
            }
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            Text(payAnnually ? "per year" : "per month")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .frame(minHeight: Self.priceBlockMinHeight, alignment: .topLeading)
    }

    private func planButtonTitle(current: Bool, switchPeriod: Bool) -> String {
        if current { return "Current" }
        if switchPeriod {
            return payAnnually ? "Switch to annual" : "Switch to monthly"
        }
        return "Subscribe"
    }

    private func cardFill(_ tier: SubscriptionTier, current: Bool, switchPeriod: Bool = false) -> Color {
        if current { return Color.accentColor.opacity(0.16) }
        if switchPeriod { return Color.accentColor.opacity(0.10) }
        switch tier {
        case .growth: return Color.blue.opacity(0.08)
        case .pro: return Color.indigo.opacity(0.10)
        case .unlimited: return Color.teal.opacity(0.10)
        case .free: return Color.secondary.opacity(0.06)
        }
    }

    private func cardBorder(current: Bool, switchPeriod: Bool) -> Color {
        if current { return Color.accentColor }
        if switchPeriod { return Color.accentColor.opacity(0.72) }
        return Color.accentColor.opacity(0.22)
    }

    private static let savingsColor = Color(red: 0.12, green: 0.52, blue: 0.34)
    /// Caption + title3 + caption, so monthly and annual cards are
    /// the same height and the sheet does not jump on the toggle.
    private static let priceBlockMinHeight: CGFloat = 58

    private func product(for tier: SubscriptionTier, annual: Bool) -> StoreProduct? {
        productsByID[PulseDistribution.productID(tier.suffix(annual: annual))]
    }

    private func savingsPercent(for tier: SubscriptionTier) -> Int? {
        guard let monthly = product(for: tier, annual: false)?.price,
              let annual = product(for: tier, annual: true)?.price else {
            return nil
        }
        return SubscriptionPricing.annualSavingsPercent(monthly: monthly, annual: annual)
    }

    private func loadProducts() async {
        #if canImport(StoreKit)
        do {
            let loaded = try await Product.products(for: SubscriptionTier.storeProductIDs)
            var mapped: [String: StoreProduct] = [:]
            for item in loaded {
                mapped[item.id] = StoreProduct(item)
            }
            productsByID = mapped
            if mapped.isEmpty {
                loadError = "No StoreKit products. In Xcode, set the Pulse scheme StoreKit Configuration to Products.storekit and run again."
            } else {
                loadError = nil
            }
        } catch {
            loadError = error.localizedDescription
        }
        #endif
    }

    private func buy(_ product: StoreProduct) async {
        #if canImport(StoreKit)
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            if try await entitlements.purchase(product.storeKit) {
                onDismiss()
            }
        } catch {
            loadError = error.localizedDescription
        }
        #endif
    }
}

/// Thin wrapper so the view can hold price without StoreKit in previews/tests.
struct StoreProduct: Identifiable {
    var id: String
    var displayPrice: String
    var price: Decimal
    #if canImport(StoreKit)
    var storeKit: Product

    init(_ product: Product) {
        id = product.id
        displayPrice = product.displayPrice
        price = product.price
        storeKit = product
    }

    func formatted(_ amount: Decimal) -> String {
        storeKit.priceFormatStyle.format(amount)
    }
    #endif
}

/// The only operator-facing explanation of what counts toward a seat.
struct SeatLicenseInfoButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(Self.copy)
        .accessibilityLabel(Self.copy)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(Self.copy)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 280, alignment: .leading)
                .presentationCompactAdaptation(.popover)
        }
    }

    static let copy = "Site graph, Device list, and In rack count toward license usage."
}

/// SwiftUI `.strikethrough` only toggles the line on or off. This draws
/// it across the glyphs with the same animation as the period switch.
///
/// Place from the text box height, not first-baseline + magic offset.
/// That offset was tuned for caption and sat on the cap-line once the
/// price also laid out as title3. Geometric `.center` is too low
/// because the line box includes descender slack.
private struct DrawnStrikethrough: ViewModifier {
    var isOn: Bool
    var color: Color = .secondary

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geo in
                let y = geo.size.height * Self.digitMidline
                Capsule()
                    .fill(color)
                    .frame(width: isOn ? geo.size.width : 0, height: 1.15, alignment: .leading)
                    .position(x: geo.size.width / 2, y: y)
            }
            .allowsHitTesting(false)
        }
    }

    /// Lining-figure midline inside a SwiftUI text box.
    private static let digitMidline: CGFloat = 0.40
}

private struct PaywallCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PaywallSheetChrome: ViewModifier {
    var compact: Bool
    #if os(iOS)
    @State private var fittedHeight: CGFloat = 0
    #endif

    func body(content: Content) -> some View {
        if compact {
            content
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                #if os(iOS)
                .modifier(FittedPhoneSheet(height: $fittedHeight))
                #endif
        } else {
            content
                .frame(width: 560)
                .fixedSize(horizontal: false, vertical: true)
                #if os(macOS)
                .presentationSizing(.fitted)
                #else
                .modifier(FittedPhoneSheet(height: $fittedHeight))
                #endif
        }
    }
}

#if os(iOS)
/// Hug the paywall instead of opening a full-height sheet.
private struct FittedPhoneSheet: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                guard abs(newHeight - height) > 1 else { return }
                height = newHeight
            }
            .presentationDetents(height > 0 ? [.height(height)] : [.medium])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.resizes)
    }
}
#endif

struct SubscriptionPaywallSheet: ViewModifier {
    @Environment(EntitlementStore.self) private var entitlements
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            PulsePaywallView(message: entitlements.tier.capReachedMessage()) {
                isPresented = false
            }
            .environment(entitlements)
        }
    }
}

struct SubscribeToResumeLabel: View {
    var body: some View {
        Text("Subscribe to resume")
            .foregroundStyle(.secondary)
    }
}
