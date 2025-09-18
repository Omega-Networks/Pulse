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
    @StateObject private var tipManager = TipManager.shared

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
    
    // MARK: - Main View
    
    var body: some View {
        #if os(iOS)
        NavigationView {
            settingsForm
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Apply") {
                            Task {
                                await applySettings()
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
        }
        #else
        TabView {
            ///Settings page (NetBox, Zabbix API Credentials)
            settingsForm
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }

            ///PowerSense Configuration & Testing
            powerSenseSettingsForm
            .tabItem {
                Label("PowerSense", systemImage: "bolt.circle")
            }

            ///PowerSense Data Viewer - device and event data inspection
            PowerSenseDataViewer()
                .tabItem {
                    Label("Data Viewer", systemImage: "eye.circle")
                }


            ///Sync dashboard - contains Model Object Counts
            SyncDashboardView()
                .tabItem {
                    Label("Database", systemImage: "swiftdata")
                }
        }
        .padding(20)
        
        #endif
    }
    
    // MARK: - Form Content
    
    private var settingsForm: some View {
        Form {
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
            powerSenseDataSection

            Section {
                Button("Apply PowerSense Settings") {
                    Task {
                        await applyPowerSenseSettings()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!powerSenseEnabled || powerSenseZabbixServer.isEmpty || powerSenseZabbixToken.isEmpty)
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

            HStack {
                Button("Fetch Test Devices") {
                    Task {
                        await testFetchDevices()
                    }
                }
                .disabled(!powerSenseEnabled || powerSenseZabbixServer.isEmpty || isTestingDevices)

                Spacer()

                if isTestingDevices {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text("\(powerSenseDeviceCount) devices")
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Button("Fetch Test Events") {
                    Task {
                        await testFetchEvents()
                    }
                }
                .disabled(!powerSenseEnabled || powerSenseZabbixServer.isEmpty || isTestingEvents)

                Spacer()

                if isTestingEvents {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text("\(powerSenseEventCount) events")
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Button("Test Problem Resolution") {
                    Task {
                        await testProblemResolution()
                    }
                }
                .disabled(!powerSenseEnabled || powerSenseZabbixServer.isEmpty || isTestingProblems)

                Spacer()

                if isTestingProblems {
                    ProgressView()
                        .scaleEffect(0.8)
                } else if activeProblemsCount > 0 || resolvedProblemsCount > 0 {
                    HStack(spacing: 8) {
                        if activeProblemsCount > 0 {
                            Text("🔴 \(activeProblemsCount)")
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                        if resolvedProblemsCount > 0 {
                            Text("✅ \(resolvedProblemsCount)")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button("Full Sync All Devices") {
                    Task {
                        await fullSyncAllDevices()
                    }
                }
                .disabled(!powerSenseEnabled || powerSenseZabbixServer.isEmpty || isFullSyncing)

                Spacer()

                if isFullSyncing {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text("Syncs all 120k devices")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }

            Button("View Test Results") {
                showingTestResults = true
            }
            .disabled(testResults.isEmpty)
        }
        .disabled(!powerSenseEnabled)
    }

    private var powerSenseDataSection: some View {
        Section("Data Management") {
            HStack {
                Button("Delete All PowerSense Data") {
                    Task {
                        await deletePowerSenseData()
                    }
                }
                .foregroundColor(.red)

                Spacer()

                VStack(alignment: .trailing) {
                    Text("\(powerSenseDeviceCount) devices")
                    Text("\(powerSenseEventCount) events")
                }
                .foregroundColor(.secondary)
                .font(.caption)
            }

            Button("Refresh Data Counts") {
                Task {
                    await refreshDataCounts()
                }
            }
        }
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
        print("Applying settings:")
        print("  NetBox Server: \(netboxApiServer)")
        print("  Zabbix Server: \(zabbixApiServer)")
        
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
        print("After save - NetBox Server: \(await config.getNetboxApiServer())")
        print("After save - Zabbix Server: \(await config.getZabbixApiServer())")
        
        // Update problem time window
        await config.setProblemTimeWindow(Int(problemTimeWindow * 3600))  // Convert hours to seconds
        
        // Show success message
        alertMessage = "Settings applied successfully"
        showingAlert = true
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

    private func testFetchDevices() async {
        guard powerSenseEnabled else { return }

        isTestingDevices = true
        logger.debug("Testing PowerSense device fetching...")

        do {
            let devices = try await fetchPowerSenseDevices()
            testResults += "\n=== Device Fetch Test ===\n"
            testResults += "✅ Successfully fetched \(devices.count) PowerSense devices\n"
            testResults += "🕒 Test time: \(Date().formatted())\n"

            // Sample a few devices for display
            let sampleDevices = Array(devices.prefix(3))
            for device in sampleDevices {
                testResults += "📍 Device: \(device.name)\n"
                testResults += "   ID: \(device.deviceId)\n"
                testResults += "   Status: \(device.isMonitored ? "Monitored" : "Not Monitored")\n"
                if let lat = device.latitude, let lon = device.longitude {
                    testResults += "   Location: \(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))\n"
                }
                testResults += "\n"
            }

            if devices.count > 3 {
                testResults += "... and \(devices.count - 3) more devices\n"
            }

            // Store devices in SwiftData for testing
            for deviceProperties in devices {
                let device = PowerSenseDevice(
                    deviceId: deviceProperties.deviceId,
                    latitude: deviceProperties.privacyLatitude,
                    longitude: deviceProperties.privacyLongitude
                )
                device.name = deviceProperties.name
                device.isMonitored = deviceProperties.isMonitored
                device.tlc = deviceProperties.tlc
                device.tui = deviceProperties.tui
                device.lastDataReceived = Date()

                modelContext.insert(device)
            }

            try? modelContext.save()
            await refreshDataCounts()

            alertMessage = "Successfully fetched and stored \(devices.count) PowerSense devices"
            showingAlert = true
            logger.debug("PowerSense device fetch test passed: \(devices.count) devices")

        } catch {
            testResults += "\n=== Device Fetch Test ===\n"
            testResults += "❌ Device fetch failed: \(error.localizedDescription)\n"
            testResults += "🕒 Test time: \(Date().formatted())\n"

            alertMessage = "PowerSense device fetch failed: \(error.localizedDescription)"
            showingAlert = true
            logger.error("PowerSense device fetch test failed: \(error.localizedDescription)")
        }

        isTestingDevices = false
    }

    private func testProblemResolution() async {
        guard powerSenseEnabled else { return }

        isTestingProblems = true
        activeProblemsCount = 0
        resolvedProblemsCount = 0
        logger.debug("Testing PowerSense problem resolution...")

        do {
            // Use PowerSenseDataService to test problem resolution
            let dataService = PowerSenseDataService(modelContext: modelContext)
            let (success, message, activeCount, resolvedCount) = await dataService.testProblemsFetching()

            testResults += "\n=== PowerSense Problem Resolution Test ===\n"
            if success {
                testResults += "✅ Successfully processed problems\n"
                testResults += "🔴 Active problems: \(activeCount)\n"
                testResults += "✅ Resolved problems: \(resolvedCount)\n"
                testResults += "🕒 Test time: \(Date().formatted())\n"

                // Update UI counters
                activeProblemsCount = activeCount
                resolvedProblemsCount = resolvedCount
            } else {
                testResults += "❌ Problem resolution failed: \(message)\n"
                throw PowerSenseZabbixError.invalidResponse(message)
            }

            // Show detailed problem info
            let activeEvents = try modelContext.fetch(
                FetchDescriptor<PowerSenseEvent>(
                    predicate: #Predicate<PowerSenseEvent> { event in
                        event.resolvedAt == nil
                    }
                )
            )

            if !activeEvents.isEmpty {
                testResults += "\n--- Active Problems ---\n"
                for event in activeEvents.prefix(5) {
                    testResults += "• Event \(event.eventId): \(event.eventDescription ?? "Unknown")\n"
                    if let device = event.device {
                        testResults += "  Device: \(device.name) (ID: \(device.deviceId))\n"
                    }
                }
                if activeEvents.count > 5 {
                    testResults += "... and \(activeEvents.count - 5) more\n"
                }
            }

            showingTestResults = true
        } catch {
            testResults += "\n❌ Problem resolution test failed: \(error.localizedDescription)\n"
            showingTestResults = true
        }

        isTestingProblems = false
    }

    private func testFetchEvents() async {
        guard powerSenseEnabled else { return }

        isTestingEvents = true
        logger.debug("Testing PowerSense event fetching...")

        do {
            // Use PowerSenseDataService event-only test (no device sync)
            let dataService = PowerSenseDataService(modelContext: modelContext)
            let (success, message, eventCount) = await dataService.testEventFetching()

            testResults += "\n=== PowerSense Event Test ===\n"
            if success {
                testResults += "✅ Successfully fetched PowerSense events\n"
                testResults += "⚡ Events processed: \(eventCount)\n"
                testResults += "🕒 Test time: \(Date().formatted())\n"
            } else {
                testResults += "❌ Event fetch failed: \(message)\n"
                throw PowerSenseZabbixError.invalidResponse(message)
            }

            // Get sample events to display
            var eventDescriptor = FetchDescriptor<PowerSenseEvent>(
                sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
            )
            eventDescriptor.fetchLimit = 3
            let recentEvents = try modelContext.fetch(eventDescriptor)

            for event in recentEvents {
                testResults += "⚡ Event: \(event.eventDescription ?? "PowerSense Event")\n"
                testResults += "   ID: \(event.eventId)\n"
                testResults += "   Status: \(event.isActive ? "Active (Power Off)" : "Resolved (Power On)")\n"
                testResults += "   Severity: \(event.severity)\n"
                testResults += "   Time: \(event.timestamp.formatted())\n"
                testResults += "   Device: \(event.device?.name ?? "nil")\n"
                testResults += "   Device ID: \(event.device?.deviceId ?? "nil")\n"
                testResults += "\n"
            }

            if eventCount > 3 {
                testResults += "... and \(eventCount - 3) more events\n"
            }

            await refreshDataCounts()

            alertMessage = "Successfully processed \(eventCount) events with proper device linking"
            showingAlert = true
            logger.debug("PowerSense event test passed: \(eventCount) events")

        } catch {
            testResults += "\n=== Event Fetch Test ===\n"
            testResults += "❌ Event fetch failed: \(error.localizedDescription)\n"
            testResults += "🕒 Test time: \(Date().formatted())\n"

            alertMessage = "PowerSense event fetch failed: \(error.localizedDescription)"
            showingAlert = true
            logger.error("PowerSense event fetch test failed: \(error.localizedDescription)")
        }

        isTestingEvents = false
    }

    // MARK: - PowerSense Data Management

    private func deletePowerSenseData() async {
        logger.debug("Deleting all PowerSense data...")

        do {
            // Delete all PowerSense devices
            let deviceFetch = FetchDescriptor<PowerSenseDevice>()
            let devices = try modelContext.fetch(deviceFetch)
            for device in devices {
                modelContext.delete(device)
            }

            // Delete all PowerSense events
            let eventFetch = FetchDescriptor<PowerSenseEvent>()
            let events = try modelContext.fetch(eventFetch)
            for event in events {
                modelContext.delete(event)
            }

            try modelContext.save()
            await refreshDataCounts()

            testResults += "\n=== Data Deletion ===\n"
            testResults += "✅ Deleted \(devices.count) devices and \(events.count) events\n"
            testResults += "🕒 Deletion time: \(Date().formatted())\n"

            alertMessage = "Successfully deleted all PowerSense data"
            showingAlert = true
            logger.debug("PowerSense data deletion completed")

        } catch {
            alertMessage = "Failed to delete PowerSense data: \(error.localizedDescription)"
            showingAlert = true
            logger.error("PowerSense data deletion failed: \(error.localizedDescription)")
        }
    }

    private func refreshDataCounts() async {
        do {
            let deviceFetch = FetchDescriptor<PowerSenseDevice>()
            powerSenseDeviceCount = try modelContext.fetchCount(deviceFetch)

            let eventFetch = FetchDescriptor<PowerSenseEvent>()
            powerSenseEventCount = try modelContext.fetchCount(eventFetch)

            logger.debug("Data counts refreshed: \(powerSenseDeviceCount) devices, \(powerSenseEventCount) events")
        } catch {
            logger.error("Failed to refresh data counts: \(error.localizedDescription)")
        }
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

