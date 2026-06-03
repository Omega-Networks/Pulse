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
    /// Nine NetBox / Zabbix sync calls plus TipKit configuration. Matches the
    /// number of `updateProgress` calls inside `verifyContainer` so the bar fills
    /// to 100% when the real work completes.
    let totalSteps = 10.0
    
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
    var clusteringService: ClusteringService?
    var monitorService: PowerSenseMonitorService?

    init() {
        do {
            modelContainer = try ModelContainer(
                for: TenantGroup.self,
                Tenant.self,
                Region.self,
                DeviceRole.self,
                DeviceType.self,
                Rack.self,
                SiteGroup.self,
                Site.self,
                Device.self,
                Service.self,
                Event.self,
                SyncProvider.self,
                PowerSenseDevice.self,
                PowerSenseEvent.self,
                SSHCredential.self,
                KnownHost.self
            )

            // Initialize clustering service with model container
            clusteringService = try ClusteringService(modelContainer: modelContainer)

            // Initialize PowerSense monitor service
            if let clustering = clusteringService {
                monitorService = PowerSenseMonitorService(
                    clusteringService: clustering,
                    modelContainer: modelContainer
                )
            }
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
        WindowGroup {
            Group {
                if showContentView {
                    ContentView()
                        .environment(sharedLocations)
                        .environment(clusteringService)
                        .environment(monitorService)
                        .modelContainer(modelContainer)
                        .task {
                            await initializePowerSense()
                        }
                } else {
                    LoadingView(state: initState)
                }
            }
            .task {
                await verifyContainer()
            }
            .frame(alignment: .center)
        }
        
        #if os(macOS)


        MenuBarExtra {
           // Empty for now
        } label: {
           ZStack {
               Image(systemName: "square.fill")
                   .foregroundColor(.white)
               
               Image("omega-swirl.symbols")
                   .foregroundColor(showContentView ? .blue : .red)
           }
           .frame(width: 24, height: 24)
        }
        .menuBarExtraStyle(.window)

        // Per-Site Site View. The `id: "site-view"` argument
        // disambiguates this scene from the SSH terminal scene at the
        // openWindow call sites: both scenes register
        // `WindowGroup(for: Int64.self)` (since Site.ID and Device.ID
        // both resolve to Int64 via @Model's default Identifiable
        // conformance), and without the explicit id the routing
        // matches by registration order, which silently mis-routes
        // device-targeted openWindow calls into this scene. See the
        // doc-comment on `SSHTerminalScene` for the full rationale.
        WindowGroup("Site View", id: "site-view", for: Site.ID.self) { $siteId in
            if showContentView {
                if let id = siteId {
                    SiteView(siteId: id)
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
                .modelContainer(modelContainer)
        }

        WindowGroup("New Site", id: "new-site") {
            if showContentView {
                AddSiteWindow()
                    .environment(sharedLocations)
                    .modelContainer(modelContainer)
            }
        }

        // Operator-facing SSH terminal. Routed per-`Device.ID`, which
        // gives single-window-per-device behaviour via SwiftUI's
        // per-value `WindowGroup` activation semantics. See
        // `SSHTerminalScene` for the wrapping rationale.
        SSHTerminalScene(modelContainer: modelContainer)

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
        // updateProgress call sets the label for the step that's about to run, so
        // the user sees "Synchronising X" while X is in flight, then advances when
        // it completes. ProviderModelActor isolates the SwiftData I/O to its own
        // executor; the main thread stays free, so no priority inversions.
        let modelActor = ProviderModelActor(modelContainer: modelContainer)

        do {
            initState.updateProgress(0, "Synchronising Device Roles...")
            try await modelActor.getDeviceRoles()

            initState.updateProgress(1, "Synchronising Device Types...")
            try await modelActor.getDeviceTypes()

            initState.updateProgress(2, "Synchronising Tenants...")
            try await modelActor.getTenants()

            initState.updateProgress(3, "Synchronising Regions...")
            try await modelActor.getRegions()

            initState.updateProgress(4, "Synchronising Site Groups...")
            try await modelActor.getSiteGroups()

            initState.updateProgress(5, "Synchronising Sites...")
            try await modelActor.getSites()

            initState.updateProgress(6, "Synchronising Racks...")
            try await modelActor.getRacks()

            initState.updateProgress(7, "Synchronising Devices...")
            try await modelActor.getDevices()

            initState.updateProgress(8, "Synchronising Services...")
            try await modelActor.getServices()

            initState.updateProgress(9, "Setting up Tips...")
            tipManager.configure()

            initState.updateProgress(10, "Ready")
        } catch {
            print("Sync failed (likely due to missing credentials): \(error)")
            initState.currentStep = "Running in Offline Mode"
            initState.showWelcome = true
            try? await Task.sleep(for: .seconds(2))
        }

        // Brief pause so a full bar is visible before the welcome message swaps in.
        try? await Task.sleep(for: .milliseconds(500))

        initState.showWelcome = true
        initState.currentStep = "Welcome to Pulse"

        // Time to read the welcome message.
        try? await Task.sleep(for: .milliseconds(1500))

        // Trigger exit animation.
        initState.startExitAnimation = true

        // Wait for the loading view to animate out.
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
     Initialize PowerSense background processing if configured and enabled.

     This method checks if PowerSense is properly configured before initializing
     the monitor service and starting background event polling.
     */
    private func initializePowerSense() async {
        // Check feature flag (defaults to true if not set)
        let featureFlagValue = UserDefaults.standard.object(forKey: "enablePowerSenseBackground")
        let featureFlagEnabled = featureFlagValue as? Bool ?? true  // Default to enabled

        guard featureFlagEnabled else {
            logger.info("PowerSense background processing disabled (feature flag)")
            return
        }

        // Check if PowerSense is configured and enabled
        let config = await Configuration.shared
        let isConfigured = await config.isPowerSenseConfigured()
        let isEnabled = await config.isPowerSenseEnabled()

        guard isConfigured && isEnabled else {
            logger.info("Skipping PowerSense initialization: not configured/enabled")
            return
        }

        // Ensure monitor service exists
        guard let service = monitorService else {
            logger.error("PowerSense monitor service not initialized")
            return
        }

        logger.info("Initializing PowerSense background processing...")

        do {
            // Initialize service (pre-warm GPU, perform initial clustering)
            try await service.initialize()

            // Start 60-second event polling
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

