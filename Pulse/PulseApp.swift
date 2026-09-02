//
//  PulseApp.swift
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
import SwiftData
import UserNotifications
import TipKit
import OSLog
#if os(macOS)
import AppKit
#endif

/**
 Manages the state and progress of application initialization.
 
 This class tracks various stages of the application's startup process,
 including progress updates, welcome messages, and animation states.
 */
@MainActor
class InitializationState: ObservableObject {
    @Published var progress: Double = 0
    @Published var currentStep = "Preparing..."
    @Published var showWelcome = false
    @Published var contentViewReady = false
    @Published var startExitAnimation = false
    @Published var isConfigured = false
    /// Sixteen NetBox stages plus TipKit. Matches the last
    /// `updateProgress` step inside `verifyContainer`.
    let totalSteps = 16.0
    
    /**
      Updates the initialization progress and step description.
      
      - Parameters:
         - step: The current step number
         - description: Description of the current step
      */
    func updateProgress(_ step: Int, _ description: String) {
        currentStep = description
        progress = Double(step)
    }
}

/**
Main entry point for the Pulse application.

This struct handles the initialisation of core services and manages the application's lifecycle,
including SwiftData configuration, TipKit setup, and view state management.
*/
@main
struct PulseApp: App {
    private let logger = Logger(subsystem: "pulse", category: "app")
    @StateObject private var initState = InitializationState()
    let tipManager = TipManager.shared
    @State private var showContentView = false
    @State private var sharedLocations = SharedLocations()

    let notificationHandler = NotificationHandler()
    let modelContainer: ModelContainer
    let netBoxSyncEngine: NetBoxSyncEngine
    let rolePresentationStore = RolePresentationStore()
    let entitlementStore: EntitlementStore
    let licenseSeatStore = LicenseSeatStore()
    @State private var clusteringService: ClusteringService?
    @State private var monitorService: PowerSenseMonitorService?

    init() {
        do {
            modelContainer = try ModelContainer(
                for: TenantGroup.self,
                Tenant.self,
                Region.self,
                DeviceRole.self,
                DeviceType.self,
                SiteLocation.self,
                RackRole.self,
                Rack.self,
                SiteGroup.self,
                Site.self,
                Device.self,
                Interface.self,
                Cable.self,
                DeviceBay.self,
                FrontPort.self,
                Service.self,
                WebHostTrust.self,
                Event.self,
                SyncProvider.self,
                PowerSenseDevice.self,
                PowerSenseEvent.self,
                SSHCredential.self,
                KnownHost.self
            )

            // Load-bearing: engine write gates read this store, not
            // UserDefaults. Capture the class before assigning stored
            // properties — App.init cannot close over self.entitlementStore
            // until every `let` is set. A missed injection fail-closes
            // at Free/50 and splits the UI (live StoreKit) from writes.
            let entitlements = EntitlementStore()
            entitlements.startAtLaunch()
            entitlementStore = entitlements
            netBoxSyncEngine = NetBoxSyncEngine(
                modelContainer: modelContainer,
                subscriptionTier: { entitlements.tier }
            )

            // PowerSense services stay nil until Settings enables them.
            // ClusteringService used to prefetch every PowerSense device
            // here, which loaded the integration even when it was off.
        } catch {
            fatalError("Failed to initialize modelContainer: \(error)")
        }

        // Session-log retention. Walks <ApplicationSupport>/Pulse/Sessions/
        // and unlinks .pulselog + .meta pairs older than the default
        // 365-day window per ADR §6. Detached Task — never on the launch
        // critical path; a stuck purge cannot delay first paint, and
        // failures are reported via session.recording.purgeFailed under
        // the ssh.recording os_log category.
        SessionLogRetention.purgeAtLaunch()
    }

    /**
     Initializes the application's core components.
     
     Sets up the SwiftData model container with all required model types.
     Throws a fatal error if initialization fails.
     */
    var body: some Scene {
        WindowGroup(id: PulseMenuBarActivation.mainWindowID) {
            Group {
                if showContentView {
                    ContentView()
                        .environment(sharedLocations)
                        .environment(clusteringService)
                        .environment(monitorService)
                        .environment(\.netBoxSyncEngine, netBoxSyncEngine)
                        .modelContainer(modelContainer)
                        .task {
                            await initializePowerSense()
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .powerSenseConfigurationDidChange)) { _ in
                            Task { await initializePowerSense() }
                        }
                } else {
                    LoadingView(state: initState)
                }
            }
            .pulseBilling(
                entitlements: entitlementStore,
                seats: licenseSeatStore,
                roles: rolePresentationStore
            )
            .background {
                SeatReconcilerHost(
                    entitlements: entitlementStore,
                    seats: licenseSeatStore,
                    roles: rolePresentationStore,
                    container: modelContainer
                )
            }
            .task {
                await verifyContainer()
            }
            .frame(alignment: .center)
        }
        
        #if os(macOS)


        // Default `.menu` style. `.window` on an empty extra is what
        // produced the blank click; the previous `square.fill` is the
        // tile in the menu bar.
        MenuBarExtra {
            PulseStatusMenu(modelContainer: modelContainer)
        } label: {
            PulseStatusMenuLabel()
        }

        // Per-Site Site View, keyed on the nominal `SiteWindowTarget`
        // value type (per ADR 0001 §9, the window model). `Site.ID` and `Device.ID` both resolve
        // to `Int64`, so keying on the raw id let device-targeted
        // openWindow calls mis-route here by registration order; the
        // distinct target type makes that a compile error. The
        // `id: "site-view"` string is retained as a state-restoration
        // anchor. See the doc-comment on `SSHTerminalScene` for the
        // full rationale.
        WindowGroup("Site View", id: "site-view", for: SiteWindowTarget.self) { $target in
            if showContentView {
                if let target {
                    SiteView(siteId: target.siteID)
                        .environment(\.netBoxSyncEngine, netBoxSyncEngine)
                        .pulseBilling(
                            entitlements: entitlementStore,
                            seats: licenseSeatStore,
                            roles: rolePresentationStore
                        )
                        .modelContainer(modelContainer)
                }
            }
        }
        #if DEBUG
        // Debug verification surface. The Debug menu lives on the Site
        // View scene because Site View is the macOS-only main window
        // (matches the host scope of the WindowGroup we attach to here);
        // the command itself is `#if DEBUG` so Release builds carry
        // neither the menu entry nor the DebugSSHMenu symbol. The
        // operator-facing terminal lives elsewhere, not here.
        .commands {
            DebugSSHCommands()
        }
        #endif

        Settings {
            SettingsView()
                .environment(\.netBoxSyncEngine, netBoxSyncEngine)
                .environment(clusteringService)
                .environment(monitorService)
                .pulseBilling(
                    entitlements: entitlementStore,
                    seats: licenseSeatStore,
                    roles: rolePresentationStore
                )
                .modelContainer(modelContainer)
        }

        WindowGroup("New Site", id: "new-site") {
            if showContentView {
                AddSiteWindow()
                    .environment(sharedLocations)
                    .environment(\.netBoxSyncEngine, netBoxSyncEngine)
                    .modelContainer(modelContainer)
            }
        }

        // Operator-facing SSH terminal. Routed per-`Device.ID`, which
        // gives single-window-per-device behaviour via SwiftUI's
        // per-value `WindowGroup` activation semantics. See
        // `SSHTerminalScene` for the wrapping rationale.
        SSHTerminalScene(
            modelContainer: modelContainer,
            entitlements: entitlementStore,
            seats: licenseSeatStore,
            roles: rolePresentationStore
        )

        // Operator-facing Device Web window, routed per its own
        // `DeviceWebWindowTarget` (distinct from the SSH terminal's
        // `DeviceWindowTarget`, so the two device scenes don't share one
        // `WindowGroup(for:)` type). See `DeviceWebScene` for the rationale.
        DeviceWebScene(
            modelContainer: modelContainer,
            entitlements: entitlementStore,
            seats: licenseSeatStore,
            roles: rolePresentationStore
        )

        #if DEBUG
        WindowGroup("Debug SSH", id: DebugSSHWindow.windowID) {
            DebugSSHWindow()
                .modelContainer(modelContainer)
        }
        #endif

        // PowerSense window - disabled for spatial clustering testing
        // WindowGroup("PowerSense", id: "PowerSense") {
        //     if showContentView {
        //         PowerSenseDashboardView(modelContext: modelContainer.mainContext)
        //             .modelContainer(modelContainer)
        //     }
        // }

        #endif
    }
    
     /**
     Verifies the integrity and readiness of the SwiftData container.
     
     This method performs a step-by-step verification of all data models,
     updates the initialization progress, and manages the welcome animation sequence.
     
     Throws: Errors related to container verification are caught and logged.
     */
    private func verifyContainer() async {
        // Check configuration first
        let config = await Configuration.shared
        let hasValidConfig = await config.hasCompletedInitialSetup()
        
        if !hasValidConfig {
            // Show configuration needed message
            initState.currentStep = "Configuration Required"
            initState.showWelcome = true
            
            // Wait for user to see the message
            try? await Task.sleep(for: .seconds(2))
            
            // Skip to content view but with limited functionality
            withAnimation(.easeInOut(duration: 0.5)) {
                showContentView = true
            }
            return
        }
        
        // Drive the progress bar from the work that actually happens. Each
        // updateProgress call sets the label for the step that's about to run.
        // NetBoxSyncEngine is the single NetBox owner; boot and Sync Dashboard
        // share it so they cannot race.
        do {
            try await netBoxSyncEngine.sync { step, label in
                Task { @MainActor in
                    initState.updateProgress(step, label)
                }
            }

            initState.updateProgress(16, "Setting up Tips...")
            tipManager.configure()
            await SiteDataService(modelContainer: modelContainer).refreshSeverities()

            initState.updateProgress(16, "Ready")
        } catch {
            logger.error("NetBox sync failed: \(error.localizedDescription)")
            if let netboxError = error as? NetBoxSyncError {
                netboxError.publish()
            } else {
                await MainActor.run {
                    RequestStatusManager.shared.updateStatus(
                        .netbox,
                        .unknownError(error.localizedDescription)
                    )
                }
            }
            initState.currentStep = "Running in Offline Mode"
            initState.showWelcome = true
            try? await Task.sleep(for: .seconds(2))
        }

        try? await Task.sleep(for: .milliseconds(500))
        initState.showWelcome = true
        initState.currentStep = "Welcome to Pulse"
        try? await Task.sleep(for: .milliseconds(1500))
        initState.startExitAnimation = true
        try? await Task.sleep(for: .milliseconds(1100))
        withAnimation(.easeInOut(duration: 0.5)) {
            showContentView = true
        }
    }
    
    /**
     Attempts to configure TipKit and returns the result.
     
     Returns: A Result indicating success or failure of the TipKit configuration.
     */
    private func setupTips() -> Result<Void, Error> {
        do {
            ///Only uncomment this line for testing purposes
//            try Tips.resetDatastore()
            try Tips.configure()
            return .success(())
        } catch {
            print("Failed to configure TipKit: \(error)")
            return .failure(error)
        }
    }

    /**
     Start PowerSense only when Settings has it enabled and configured.
     Tear the services down otherwise so clustering and polling do not run.
     */
    private func initializePowerSense() async {
        let config = await Configuration.shared
        let isConfigured = await config.isPowerSenseConfigured()
        let isEnabled = await config.isPowerSenseEnabled()

        guard isConfigured && isEnabled else {
            if monitorService != nil || clusteringService != nil {
                logger.info("PowerSense disabled — stopping monitor and releasing clustering")
                monitorService?.stopMonitoring()
                await monitorService?.clearCachedResults()
                monitorService = nil
                clusteringService = nil
            } else {
                logger.info("Skipping PowerSense initialization: not configured/enabled")
            }
            return
        }

        do {
            if clusteringService == nil {
                clusteringService = try ClusteringService(modelContainer: modelContainer)
            }
            if monitorService == nil, let clustering = clusteringService {
                monitorService = PowerSenseMonitorService(
                    clusteringService: clustering,
                    modelContainer: modelContainer
                )
            }
            guard let service = monitorService else {
                logger.error("PowerSense monitor service not initialized")
                return
            }

            logger.info("Initializing PowerSense background processing...")
            if !service.isInitialized {
                try await service.initialize()
            }
            service.startMonitoring()
            logger.info("PowerSense background processing started successfully")
        } catch {
            logger.error("PowerSense initialization failed: \(error.localizedDescription)")
        }
    }
}

struct LoadingView: View {
    @ObservedObject var state: InitializationState
    @State private var logoScale: CGFloat = 1
    @State private var logoRotation: Double = 0
    @State private var textOpacity: Double = 1
    @State private var viewOpacity: Double = 1
    
    var body: some View {
        VStack {
            Image("omega-swirl.symbols")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 120, height: 120)
                .scaleEffect(logoScale)
                .rotationEffect(.degrees(logoRotation))
            
            ZStack {
                // Progress View
                ProgressView(state.currentStep, value: state.progress, total: state.totalSteps)
                    .progressViewStyle(CircularProgressViewStyle())
                    .padding()
                    .frame(height: 69)
                    .opacity(state.showWelcome ? 0 : 1)
                    .scaleEffect(state.showWelcome ? 0.8 : 1)
                    .animation(.easeOut(duration: 0.3), value: state.showWelcome)
                
                // Welcome Message
                VStack(spacing: 2) {
                    Text(state.currentStep)
                        .font(.title2)
                        .fontWeight(.medium)
                    
                    if state.currentStep == "Configuration Required" {
                        Text("Please configure API credentials in Settings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if state.currentStep == "Running in Offline Mode" {
                        Text("API connection unavailable")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Your Smart City Companion")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 69)
                .opacity(state.showWelcome ? textOpacity : 0)
                .scaleEffect(state.showWelcome ? 1 : 1.2)
                .animation(.easeIn(duration: 0.4).delay(0.2), value: state.showWelcome)
            }
        }
        .frame(width: 250, height: 250)
        .background(.windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10)
        .opacity(viewOpacity)
        .onChange(of: state.startExitAnimation) { _, startExit in
            if startExit {
                withAnimation(.easeOut(duration: 0.3)) {
                    textOpacity = 0
                }
                
                withAnimation(.easeIn(duration: 0.8)) {
                    logoScale = 5
                    logoRotation = 540
                }
                
                withAnimation(.easeOut(duration: 0.3).delay(0.7)) {
                    viewOpacity = 0
                }
            }
        }
    }
    
    private var configurationWarningColor: Color {
        switch state.currentStep {
        case "Configuration Required", "Running in Offline Mode":
            return .orange
        default:
            return .primary
        }
    }
}

enum PulseMenuBarActivation {
    static let mainWindowID = "pulse-main"

    #if os(macOS)
    @MainActor
    static func revealMainWindow(openWindow: OpenWindowAction) {
        NSApp.activate()
        if let window = NSApp.windows.first(where: isReusableMainWindow) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        openWindow(id: mainWindowID)
    }

    @MainActor
    private static func isReusableMainWindow(_ window: NSWindow) -> Bool {
        guard window.canBecomeMain, window.level == .normal else { return false }
        let className = String(describing: type(of: window))
        if className.contains("StatusBar") || className.contains("StatusItem") {
            return false
        }
        switch window.title {
        case "Site View", "New Site", "Settings", "Debug SSH":
            return false
        default:
            return true
        }
    }
    #endif
}

#if os(macOS)
/// Menu-bar extra. Pulse swirl as a 16×16pt template (circular extras
/// match system weight at 16pt; the slot is 22pt, the bar is 24pt).
/// Do not use `omega-swirl.symbols` here — that SVG is the 3300×2200
/// SF Symbols sheet, not a status-item glyph.
struct PulseStatusMenuLabel: View {
    var body: some View {
        Image(nsImage: Self.templateIcon)
            .accessibilityLabel("Pulse")
    }

    private static let templateIcon: NSImage = {
        let base = NSImage(named: "MenuBarSwirl") ?? NSImage(size: NSSize(width: 16, height: 16))
        let image = base.copy() as? NSImage ?? base
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }()
}

struct PulseStatusMenu: View {
    let modelContainer: ModelContainer
    @Environment(\.openWindow) private var openWindow
    private var statusManager = RequestStatusManager.shared
    @State private var isRetryingZabbix = false

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    var body: some View {
        Button("Open Pulse") {
            PulseMenuBarActivation.revealMainWindow(openWindow: openWindow)
        }
        if let zabbixWarning {
            Divider()
            Section(zabbixWarning) {
                Button(isRetryingZabbix ? "Checking…" : "Retry Zabbix") {
                    retryZabbix()
                }
                .disabled(isRetryingZabbix)
            }
        }
        Divider()
        Button("Quit Pulse") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var zabbixWarning: String? {
        switch statusManager.currentStatus[.zabbix] {
        case .connectionError(let text),
             .authenticationFailure(_, let text),
             .dataError(_, let text),
             .unknownError(let text):
            return text
        default:
            return nil
        }
    }

    private func retryZabbix() {
        isRetryingZabbix = true
        Task {
            await SiteDataService(modelContainer: modelContainer).getProblems()
            await MainActor.run { isRetryingZabbix = false }
        }
    }
}
#endif

