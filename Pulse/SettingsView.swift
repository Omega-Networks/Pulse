//
//  SettingsView.swift
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
import TipKit
import SwiftData
import OSLog

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(PowerSenseMonitorService.self) private var monitorService: PowerSenseMonitorService?
    @Environment(ClusteringService.self) private var clusteringService: ClusteringService?
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(LicenseSeatStore.self) private var seats
    @StateObject private var tipManager = TipManager.shared
    @State private var showingPaywall = false

    private let logger = Logger(subsystem: "powersense", category: "settings")

    // MARK: - State Properties

    // NetBox Settings
    @State private var netboxApiServer: String = ""
    @State private var netboxApiToken: String = ""

    // Zabbix Settings
    @State private var zabbixApiUser: String = ""
    @State private var zabbixApiServer: String = ""
    @State private var zabbixApiToken: String = ""
    @State private var problemTimeWindow: Double = 1  // In hours

    // PowerSense Settings
    @State private var powerSenseEnabled: Bool = false
    @State private var powerSenseZabbixServer: String = ""
    @State private var powerSenseZabbixToken: String = ""
    @State private var powerSenseUpdateInterval: Int = 60
    @State private var powerSenseMinDeviceThreshold: Int = 3
    @State private var powerSenseGridSize: Int = 100
    @State private var isFullSyncing = false

    // PowerSense Testing State
    @State private var isTestingConnection = false
    @State private var isTestingDevices = false
    @State private var isTestingEvents = false
    @State private var isTestingProblems = false
    @State private var testResults: String = ""
    @State private var showingTestResults = false
    @State private var powerSenseDeviceCount = 0
    @State private var powerSenseEventCount = 0
    @State private var activeProblemsCount = 0
    @State private var resolvedProblemsCount = 0

    // Alert State
    @State private var showingAlert = false
    @State private var alertMessage = ""

    // Data Management State
    @State private var showingDeleteEventsConfirmation = false
    @State private var showingDeleteAllDataConfirmation = false
    @State private var isDeletingData = false
    
    // MARK: - Main View
    
    var body: some View {
        #if os(iOS)
        NavigationStack {
            List {
                Section("Subscription") {
                    LabeledContent("Plan", value: entitlements.tier.displayName)
                    if let caption = entitlements.periodCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    subscriptionSeatsRow
                    Button("Subscribe") {
                        showingPaywall = true
                    }
                    Button("Restore Purchases") {
                        Task { @MainActor in
                            await entitlements.restore()
                        }
                    }
                }
                Section("Connection") {
                    NavigationLink("API credentials") {
                        settingsForm
                            .navigationTitle("API credentials")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Apply") {
                                        Task { await applySettings() }
                                    }
                                }
                            }
                    }
                }
                Section("NetBox") {
                    NavigationLink("Device Roles") {
                        RolePresentationSettings()
                    }
                    NavigationLink("Database") {
                        SyncDashboardView()
                            .navigationTitle("Database")
                    }
                }
                Section("Access") {
                    NavigationLink("SSH") {
                        SSHCredentialsSettings()
                    }
                    NavigationLink("Web Trust") {
                        WebTrustSettingsView()
                    }
                }
                Section("Power") {
                    NavigationLink("PowerSense") {
                        powerSenseSettingsForm
                            .navigationTitle("PowerSense")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .modifier(SubscriptionPaywallSheet(isPresented: $showingPaywall))
        }
        #else
        TabView {
            ///Settings page (NetBox, Zabbix API Credentials)
            settingsForm
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }

            RolePresentationSettings()
                .tabItem {
                    Label("Roles", systemImage: "server.rack")
                }

            ///PowerSense Configuration & Testing
            powerSenseSettingsForm
            .tabItem {
                Label("PowerSense", systemImage: "bolt.circle")
            }

            ///SSH credentials (Secure Enclave default, PEM import for legacy keys)
            SSHCredentialsSettings()
                .tabItem {
                    Label("SSH", systemImage: "key.fill")
                }

            ///Device-web TLS trust: review and edit pinned (trusted) and blocked hosts
            WebTrustSettingsView()
                .tabItem {
                    Label("Web Trust", systemImage: "lock.shield")
                }

            ///Sync dashboard - contains Model Object Counts
            SyncDashboardView()
                .tabItem {
                    Label("Database", systemImage: "swiftdata")
                }
        }
        .padding(20)
        .modifier(SubscriptionPaywallSheet(isPresented: $showingPaywall))
        
        #endif
    }

    private var subscriptionSeatsRow: some View {
        LabeledContent("Seats") {
            HStack(spacing: 4) {
                Text(entitlements.tier.meterLabel(seated: seats.seatedIDs.count))
                SeatLicenseInfoButton()
            }
        }
    }
        
    // MARK: - Form Content

    private var settingsForm: some View {
        Form {
            #if os(macOS)
            Section(header: Text("            Subscription")
                .font(.title3)
                .fontWeight(.bold)
            ) {
                LabeledContent("Plan", value: entitlements.tier.displayName)
                if let caption = entitlements.periodCaption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                subscriptionSeatsRow
                HStack {
                    Button("Subscribe") {
                        showingPaywall = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Restore Purchases") {
                        Task { @MainActor in
                            await entitlements.restore()
                        }
                    }
                }
            }
            .padding(.bottom, 8)
            #endif

            Section(header: Text("            NetBox Settings")
                .font(.title3)
                .fontWeight(.bold)
//                .popoverTip(tipManager.credentialsTip) //TODO: Implement updated tip
            ) {
                TextField("API Server", text: $netboxApiServer)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Token", text: $netboxApiToken)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.bottom, 4)
            
            Section(header: Text("            Zabbix Settings")
                .font(.title3)
                .fontWeight(.bold)
            ) {
                TextField("API Server", text: $zabbixApiServer)
                    .textFieldStyle(.roundedBorder)
                TextField("API User", text: $zabbixApiUser)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Token", text: $zabbixApiToken)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.bottom, 4)
            #if os(macOS)
            HStack {
                Spacer()
                Button("Apply Settings") {
                    Task {
                        await applySettings()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
#endif
        }
        .frame(minWidth: 350, maxWidth: .infinity)
        .alert(isPresented: $showingAlert) {
            Alert(
                title: Text("Settings"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .task {
            await loadSettings()
        }
    }

    // MARK: - PowerSense Settings Form

    private var powerSenseSettingsForm: some View {
        Form {
            Section("PowerSense Configuration") {
                Toggle("Enable PowerSense Integration", isOn: $powerSenseEnabled)
                    .onChange(of: powerSenseEnabled) { _, newValue in
                        logger.debug("PowerSense enabled changed to: \(newValue)")
                    }

                TextField("PowerSense Zabbix Server", text: $powerSenseZabbixServer)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!powerSenseEnabled)
                    .onChange(of: powerSenseZabbixServer) { _, newValue in
                        logger.debug("PowerSense server changed to: \(newValue)")
                    }

                SecureField("PowerSense Bearer Token", text: $powerSenseZabbixToken)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!powerSenseEnabled)
                    .onChange(of: powerSenseZabbixToken) { _, newValue in
                        logger.debug("PowerSense bearer token changed (length: \(newValue.count))")
                    }
            }

            Section("Privacy & Performance") {
                LabeledContent("Update Interval (seconds)") {
                    TextField("60", value: $powerSenseUpdateInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!powerSenseEnabled)
                        .onChange(of: powerSenseUpdateInterval) { _, newValue in
                            logger.debug("Update interval changed to: \(newValue)")
                        }
                }

                LabeledContent("Minimum Device Threshold") {
                    TextField("3", value: $powerSenseMinDeviceThreshold, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!powerSenseEnabled)
                        .onChange(of: powerSenseMinDeviceThreshold) { _, newValue in
                            logger.debug("Min device threshold changed to: \(newValue)")
                        }
                }

                LabeledContent("Grid Size (meters)") {
                    TextField("100", value: $powerSenseGridSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!powerSenseEnabled)
                        .onChange(of: powerSenseGridSize) { _, newValue in
                            logger.debug("Grid size changed to: \(newValue)")
                        }
                }
            }

            powerSenseTestingSection

            Section {
                Button("Apply PowerSense Settings") {
                    Task {
                        await applyPowerSenseSettings()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!powerSenseEnabled || powerSenseZabbixServer.isEmpty || powerSenseZabbixToken.isEmpty)
            }
            
            HStack {
                Button("Full Sync All Devices") {
                    Task {
                        await fullSyncAllDevices()
                    }
                }
                .disabled(!powerSenseEnabled || powerSenseZabbixServer.isEmpty || isFullSyncing)

                if isFullSyncing {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                }
             }

            Section("Data Management") {
                HStack {
                    Text("Devices:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(powerSenseDeviceCount)")
                }
                HStack {
                    Text("Events:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(powerSenseEventCount)")
                }

                Button("Delete All PowerSense Events", role: .destructive) {
                    showingDeleteEventsConfirmation = true
                }
                .disabled(isDeletingData || powerSenseEventCount == 0)

                Button("Delete All PowerSense Data", role: .destructive) {
                    showingDeleteAllDataConfirmation = true
                }
                .disabled(isDeletingData || (powerSenseDeviceCount == 0 && powerSenseEventCount == 0))

                if isDeletingData {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Deleting...")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .confirmationDialog(
                "Delete All PowerSense Events?",
                isPresented: $showingDeleteEventsConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Events", role: .destructive) {
                    Task { await deleteAllPowerSenseEvents() }
                }
            } message: {
                Text("This will delete all \(powerSenseEventCount) PowerSense events. Devices will be kept. This cannot be undone.")
            }
            .confirmationDialog(
                "Delete All PowerSense Data?",
                isPresented: $showingDeleteAllDataConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete All Data", role: .destructive) {
                    Task { await deleteAllPowerSenseData() }
                }
            } message: {
                Text("This will delete all \(powerSenseDeviceCount) devices and \(powerSenseEventCount) events. This cannot be undone.")
            }
        }
        .alert(isPresented: $showingAlert) {
            Alert(
                title: Text("PowerSense Settings"),
                message: Text(alertMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $showingTestResults) {
            PowerSenseTestResultsView(results: testResults)
        }
        .task {
            await loadPowerSenseSettings()
        }
    }

    private var powerSenseTestingSection: some View {
        Section("Integration Testing") {
            HStack {
                Button("Test Connection") {
                    Task {
                        await testPowerSenseConnection()
                    }
                }
                .disabled(!powerSenseEnabled || powerSenseZabbixServer.isEmpty || isTestingConnection)

                if isTestingConnection {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            Divider()

            Button("View Test Results") {
                showingTestResults = true
            }
            .disabled(testResults.isEmpty)
        }
        .disabled(!powerSenseEnabled)
    }


    
    private func fullSyncAllDevices() async {
        guard !isFullSyncing else { return }
        
        isFullSyncing = true
        defer { isFullSyncing = false }
        
        logger.info("Starting full sync of all PowerSense devices...")
        
        do {
            let dataService = PowerSenseDataService(modelContext: modelContext)
            let (deviceCount, eventCount) = try await dataService.syncPowerSenseData()
            
            await refreshDataCounts()
            
            logger.info("Full sync completed: \(deviceCount) devices, \(eventCount) events processed")
            
        } catch {
            logger.error("Full sync failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Data Management

    private func deleteAllPowerSenseEvents() async {
        isDeletingData = true
        defer { isDeletingData = false }

        logger.info("Deleting all PowerSense events...")
        let dataService = PowerSenseDataService(modelContext: modelContext)
        await dataService.clearAllPowerSenseEvents(monitorService: monitorService, clusteringService: clusteringService)
        await refreshDataCounts()

        alertMessage = "All PowerSense events deleted"
        showingAlert = true
        logger.info("PowerSense events deleted successfully")
    }

    private func deleteAllPowerSenseData() async {
        isDeletingData = true
        defer { isDeletingData = false }

        logger.info("Deleting all PowerSense data...")
        let dataService = PowerSenseDataService(modelContext: modelContext)
        await dataService.clearAllPowerSenseData(monitorService: monitorService, clusteringService: clusteringService)
        await refreshDataCounts()

        alertMessage = "All PowerSense data deleted"
        showingAlert = true
        logger.info("PowerSense data deleted successfully")
    }

    // MARK: - Settings Management

    private func loadSettings() async {
        let config = await Configuration.shared

        netboxApiServer = await config.getNetboxApiServer()
        zabbixApiServer = await config.getZabbixApiServer()

        netboxApiToken = await config.getNetboxApiToken()
        zabbixApiUser = await config.getZabbixApiUser()
        zabbixApiToken = await config.getZabbixApiToken()

        problemTimeWindow = Double(await config.getProblemTimeWindow()) / 3600.0
    }
    
    private func loadPowerSenseSettings() async {
        let config = await Configuration.shared

        powerSenseEnabled = await config.isPowerSenseEnabled()
        powerSenseZabbixServer = await config.getPowerSenseZabbixServer()
        powerSenseZabbixToken = await config.getPowerSenseZabbixToken()
        powerSenseUpdateInterval = await config.getPowerSenseUpdateInterval()
        powerSenseMinDeviceThreshold = await config.getPowerSenseMinDeviceThreshold()
        powerSenseGridSize = await config.getPowerSenseGridSize()

        await refreshDataCounts()

        logger.debug("Loaded PowerSense settings: enabled=\(powerSenseEnabled), server=\(powerSenseZabbixServer)")
    }
    
    private func applySettings() async {
        logger.debug("Applying settings: NetBox=\(netboxApiServer), Zabbix=\(zabbixApiServer)")
        
        // Create local reference and await it
        let config = await Configuration.shared
        
        // Update all settings
        await config.updateSettings(
            netboxApiServer: netboxApiServer,
            netboxApiToken: netboxApiToken,
            zabbixApiServer: zabbixApiServer,
            zabbixApiUser: zabbixApiUser,
            zabbixApiToken: zabbixApiToken
        )
        
        // Verify the save worked
        let savedNetbox = await config.getNetboxApiServer()
        let savedZabbix = await config.getZabbixApiServer()
        logger.debug("After save — NetBox: \(savedNetbox), Zabbix: \(savedZabbix)")
        
        // Update problem time window
        await config.setProblemTimeWindow(Int(problemTimeWindow * 3600))  // Convert hours to seconds
        
        // Show success message
        alertMessage = "Settings applied successfully"
        showingAlert = true
    }
    
    private func refreshDataCounts() async {
        do {
            // Use a fresh context to see changes made by background actors
            let freshContext = ModelContext(modelContext.container)
            let deviceFetch = FetchDescriptor<PowerSenseDevice>()
            powerSenseDeviceCount = try freshContext.fetchCount(deviceFetch)

            let eventFetch = FetchDescriptor<PowerSenseEvent>()
            powerSenseEventCount = try freshContext.fetchCount(eventFetch)

            logger.debug("Data counts refreshed: \(powerSenseDeviceCount) devices, \(powerSenseEventCount) events")
        } catch {
            logger.error("Failed to refresh data counts: \(error.localizedDescription)")
        }
    }

    // MARK: - PowerSense Settings Management

    private func applyPowerSenseSettings() async {
        logger.debug("Applying PowerSense settings:")
        logger.debug("  Enabled: \(powerSenseEnabled)")
        logger.debug("  Server: \(powerSenseZabbixServer)")
        logger.debug("  Update Interval: \(powerSenseUpdateInterval)")

        let config = await Configuration.shared

        await config.updatePowerSenseSettings(
            enabled: powerSenseEnabled,
            zabbixServer: powerSenseZabbixServer,
            zabbixUser: "", // No username needed for bearer token auth
            zabbixToken: powerSenseZabbixToken,
            updateInterval: powerSenseUpdateInterval,
            minDeviceThreshold: powerSenseMinDeviceThreshold,
            gridSize: powerSenseGridSize
        )

        // Clear PowerSense API session to force re-authentication
        await PowerSenseZabbixAPI.shared.clearSession()

        alertMessage = "PowerSense settings applied successfully"
        showingAlert = true

        logger.debug("PowerSense settings saved successfully")
    }

    // MARK: - PowerSense Testing Functions

    private func testPowerSenseConnection() async {
        guard powerSenseEnabled else { return }

        isTestingConnection = true
        logger.debug("Testing PowerSense connection...")

        do {
            // Try to get the bearer token
            let token = try await PowerSenseZabbixAPI.shared.getBearerToken()

            // Test actual API call with a simple host.get request
            let devices = try await fetchPowerSenseDevices(hostIds: [], groupNames: [])

            testResults += "\n=== Connection Test ===\n"
            testResults += "✅ Successfully connected to PowerSense Zabbix\n"
            testResults += "🔑 Bearer token validated (length: \(token.count))\n"
            testResults += "📡 API test successful - fetched \(devices.count) devices\n"
            testResults += "🕒 Test time: \(Date().formatted())\n"

            alertMessage = "PowerSense connection test successful!"
            showingAlert = true
            logger.debug("PowerSense connection test passed")

        } catch {
            testResults += "\n=== Connection Test ===\n"
            testResults += "❌ Connection failed: \(error.localizedDescription)\n"

            // Add more detailed error information
            if let powerSenseError = error as? PowerSenseZabbixError {
                testResults += "   Error type: PowerSense Zabbix Error\n"
                testResults += "   Details: \(powerSenseError.localizedDescription)\n"
            } else {
                testResults += "   Error type: \(type(of: error))\n"
                testResults += "   Full error: \(error)\n"
            }

            testResults += "🕒 Test time: \(Date().formatted())\n"

            alertMessage = "PowerSense connection test failed: \(error.localizedDescription)"
            showingAlert = true
            logger.error("PowerSense connection test failed: \(error)")
        }

        isTestingConnection = false
    }
}


// MARK: - PowerSense Test Results View

struct PowerSenseTestResultsView: View {
    let results: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
#if os(iOS)
        NavigationView {
            scrollContent
                .navigationTitle("Test Results")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Close") {
                            dismiss()
                        }
                    }
                }
        }
#else
        VStack {
            HStack {
                Text("PowerSense Integration Test Results")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button("Close") {
                    dismiss()
                }
            }
            .padding()
            
            scrollContent
        }
        .frame(minWidth: 600, minHeight: 500)
#endif
    }
    
    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading) {
#if os(iOS)
                Text("PowerSense Integration Test Results")
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.bottom)
#endif
                
                Text(results.isEmpty ? "No test results available yet." : results)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
#if os(macOS)
                    .background(Color(NSColor.textBackgroundColor))
#else
                    .background(Color(UIColor.systemBackground))
#endif
                    .cornerRadius(8)
            }
            .padding()
        }
    }
    

}

