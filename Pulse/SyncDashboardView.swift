//
//  ContentView.swift
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
import Combine

/**
 A dashboard view that manages and displays the synchronization status between NetBox and local SwiftData storage.
 
 This view provides functionality to:
 - Monitor and display counts of various network infrastructure objects
 - Initiate manual synchronization with NetBox
 - Delete stored data selectively or completely
 - Configure API connections for NetBox and Zabbix
 - Display sync status and error alerts
 */
struct SyncDashboardView: View {
    // MARK: - Environment & State Properties
    
    @Environment(\.modelContext) private var modelContext
    @Query var syncProvider: [SyncProvider]
    
    // MARK: - UI State
    
    @State var isMonitoringEnabled = false
    @State var eventMonitoringTimer: Timer?
    @State var openDeleteButtons = false
    @State var openFetchButtons = false
    
    // MARK: - Object Counts
    
    @State private var deviceRolesCount: Int = 0
    @State private var deviceTypesCount: Int = 0
    @State private var tenantsCount: Int = 0
    @State private var regionsCount: Int = 0
    @State private var siteGroupsCount: Int = 0
    @State private var sitesCount: Int = 0
    @State private var racksCount: Int = 0
    @State private var devicesCount: Int = 0
    @State private var syncProviderCount: Int = 0
    
    // MARK: - API Configuration
    
    @State private var isConfigurationNeeded = false
    @State private var netboxApiServer = ""
    @State private var netboxApiToken = ""
    @State private var zabbixApiServer = ""
    @State private var zabbixApiToken = ""
    
    @State private var contextDidSaveDate = Date()
    
    // MARK: - Alert Properties
    
    private var statusManager = RequestStatusManager.shared
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    
    //MARK: - Main body view
    var body: some View {
        VStack {
            //MARK: - Main view body, containing model object counts
            HStack{
                Text("").frame(width: 150)
                Spacer()
                VStack {
                    Text("Object Counts")
                        .font(.title3)
                        .fontWeight(.bold)
                }
                Spacer()
                //MARK: Primary action buttons
                VStack {
                    HStack {
                        Text("Sync Provider")
                            .font(.title3)
                            .fontWeight(.bold)
                        switch syncProviderCount {
                        case 0: Image(systemName: "multiply.square.fill")
                                .foregroundStyle(Color.red)
                        case 1: Image(systemName: "checkmark.square.fill")
                                .foregroundStyle(Color.green)
                        default:
                            Image(systemName: "exclamationmark.square.fill")
                                .foregroundStyle(Color.orange)
                        }
                    }
                }
                .frame(width: 150)
            }
            .padding(4)
            
            Form {
                LabeledContent("Device Roles:", value: String(deviceRolesCount))
                LabeledContent("Device Types:", value: String(deviceTypesCount))
                LabeledContent("Tenants:", value: String(tenantsCount))
                LabeledContent("Regions:", value: String(regionsCount))
                LabeledContent("Site Groups:", value: String(siteGroupsCount))
                LabeledContent("Sites:", value: String(sitesCount))
                LabeledContent("Racks:", value: String(racksCount))
                LabeledContent("Devices:", value: String(devicesCount))
            }
            .id(contextDidSaveDate)
            HStack {
                /// Button for deleting objects
                Button("Delete Data", role: .destructive) {
                    openDeleteButtons.toggle()
                }
                .popover(isPresented: $openDeleteButtons, arrowEdge: .bottom) {
                    VStack {
                        Button("Delete All Data", role: .destructive) {
                            deleteAllDataAndUpdateCounts()
                        }
                        
                        Button("Delete Racks", role: .destructive) {
                            deleteRacks()
                        }
                        
                        Button("Delete Devices", role: .destructive) {
                            deleteDevices()
                        }
                        
                        Button("Delete Sync Provider", role: .destructive) {
                            deleteSyncProvider()
                            print("Sync provider deleted successfully.")
                        }
                    }
                    .padding()
                }
                .padding(4)
                
                Spacer()
                
                /// Button for fetching data from NetBox
                ///
                Button(isMonitoringEnabled ? "Syncing" : "Sync Data") {
                    Task.detached(priority: .background) {
                        await syncData()
                    }
                }
                .frame(width: 100)
                .buttonStyle(.borderedProminent)
                .disabled(isMonitoringEnabled)
                .padding(4)
            }
        }
        
        .task {
            await updateCounts()
            await checkConfigurationNeeded()
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK") { showAlert = false }
        } message: {
            Text(alertMessage)
        }
        .onChange(of: statusManager.currentStatus) { oldValue, newValue in
            handleStatusChange(newValue)
        }
    }
    
    /**
     Updates the count of all managed object types in the local storage.
     
     This function fetches counts for:
     - Device roles and types
     - Tenants and regions
     - Site groups and sites
     - Racks and devices
     - Sync providers
     */
    func updateCounts() async {
        do {
            deviceRolesCount = try await fetchCount(for: DeviceRole.self)
            deviceTypesCount = try await fetchCount(for: DeviceType.self)
            tenantsCount = try await fetchCount(for: Tenant.self)
            regionsCount = try await fetchCount(for: Region.self)
            siteGroupsCount = try await fetchCount(for: SiteGroup.self)
            sitesCount = try await fetchCount(for: Site.self)
            racksCount = try await fetchCount(for: Rack.self)
            devicesCount = try await fetchCount(for: Device.self)
            syncProviderCount = try await fetchCount(for: SyncProvider.self)
        } catch {
            print("Error: \(error)")
        }
    }
    
    /**
      Fetches the count of objects for a specific persistent model type.
      
      - Parameter type: The type of persistent model to count
      - Returns: The number of objects of the specified type in storage
      - Throws: Any errors encountered during the fetch operation
      */
    func fetchCount<T: PersistentModel>(for type: T.Type) async throws -> Int {
        let descriptor = FetchDescriptor<T>()
        return try await withModelContext { context in
            try context.fetchCount(descriptor)
        }
    }
    
    func deleteDevices() {
        deleteAndUpdateCounts(Device.self)
    }
    
    func deleteRacks() {
        deleteAndUpdateCounts(Rack.self)
    }
    
    func deleteSyncProvider() {
        deleteAndUpdateCounts(SyncProvider.self)
    }
    
    /**
     Ensures a single SyncProvider object exists in the data store.
     
     This function:
     1. Checks if a SyncProvider exists
     2. Creates one if none exist
     3. Removes extras and creates a new one if multiple exist
     */
    func ensureSyncProviderExists() {
        do {
            if !syncProvider.isEmpty {
                // If a SyncProvider exists, no need to create a new one
                print("SyncProvider exists, skipping creation.")
            } else if syncProvider.count > 1 {
                // If more than 1 syncProficer exists delete and create a new one.
                print("Muliple SyncProvider's exists, purging and recreating.")
                deleteSyncProvider()
                
                let syncProvider = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date())
                
                modelContext.insert(syncProvider)
                try modelContext.save()
            } else {
                // If no SyncProvider exists, create a new one
                let syncProvider = SyncProvider(lastNetBoxUpdate: Date(), lastZabbixUpdate: Date())
                
                modelContext.insert(syncProvider)
                try modelContext.save()
            }
        } catch {
            print("Error fetching or creating SyncProvider: \(error)")
        }
    }
    
    //MARK: - Functions for fetching data from NetBox
    
    /**
     Performs model context operations on the main actor.
     
     - Parameter perform: The closure to execute with the model context
     - Returns: The result of the performed operation
     - Throws: Any errors encountered during the operation
     */
    @MainActor
    func withModelContext<T>(_ perform: @MainActor (ModelContext) throws -> T) async rethrows -> T {
        try perform(modelContext)
    }
    
    /**
     Checks if API configuration is needed by verifying the existence of required API credentials.
     
     Updates the configuration state and loads existing values if configuration is needed.
     */
    func checkConfigurationNeeded() async {
        
        print("RUNNING CHECK CONFIGURATION NEEDED")
        
        let config = await Configuration.shared
        let netboxServer = await config.getNetboxApiServer()
        let netboxToken = await config.getNetboxApiToken()
        let zabbixServer = await config.getZabbixApiServer()
        let zabbixToken = await config.getZabbixApiToken()
        
        isConfigurationNeeded = netboxServer.isEmpty || netboxToken.isEmpty || zabbixServer.isEmpty || zabbixToken.isEmpty
        
        if isConfigurationNeeded {
            netboxApiServer = netboxServer
            netboxApiToken = netboxToken
            zabbixApiServer = zabbixServer
            zabbixApiToken = zabbixToken
        }
    }
    
    /**
     Deletes all instances of a specified model type and updates the object counts.
     
     - Parameter type: The persistent model type to delete
     */
    func deleteAndUpdateCounts<T: PersistentModel>(_ type: T.Type) {
        do {
            try modelContext.delete(model: type)
            print("\(type) data deleted successfully.")
            Task { await updateCounts() }
        } catch {
            print("Failed to delete all \(type).")
        }
    }
    
    /**
     Deletes all managed objects from local storage and updates counts.
     
     This operation removes:
     - Tenants and regions
     - Device types and roles
     - Site groups and sites
     - Racks and devices
     */
    func deleteAllDataAndUpdateCounts() {
        let modelsToDelete: [any PersistentModel.Type] = [
            DeviceType.self,
            DeviceRole.self,
            Tenant.self,
            Region.self,
            SiteGroup.self,
            Site.self,
            Rack.self,
            Device.self
        ]
        
        do {
            for model in modelsToDelete {
                try modelContext.delete(model: model)
                print("\(model) data deleted successfully.")
            }
            
            Task {
                await updateCounts()
            }
            
            print("All data deleted successfully.")
        } catch {
            print("Failed to delete all data: \(error)")
        }
    }
    
    
    /**
     Creates a toolbar status view showing the last update time from NetBox.
     
     - Returns: A view displaying the relative time since the last NetBox update
     */
    private func SyncDashboardToolbarStatusView() -> some View {
        VStack {
            if let provider = syncProvider.first {
                Text("NetBox Last Updated: \(relativeTimeString(for: provider.lastNetBoxUpdate))")
                    .font(.caption)
            } else {
                Text("NetBox Last Updated: N/A")
                    .font(.caption)
            }
        }
        .font(.caption)
        .id(contextDidSaveDate)
        .onReceive(NotificationCenter.default.managedObjectContextDidSavePublisher) { _ in
            contextDidSaveDate = .now
        }
    }
    
    /**
     Converts a date to a relative time string (e.g., "2 hours ago").
     
     - Parameter date: The date to convert
     - Returns: A localized string representing the relative time
     */
    func relativeTimeString(for date: Date?) -> String {
        guard let date = date else { return "N/A" }
        
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    /**
     Handles changes in request status and updates the alert accordingly.
     
     - Parameter status: The new request status to process
     */
    @MainActor
    private func handleStatusChange(_ status: [RequestStatusManager.RequestSource: RequestStatusManager.RequestStatus]) {
        guard let (source, status) = status.first else { return }
        
        switch status {
        case .success(let code, let message):
            alertTitle = "Success"
            alertMessage = "Data successfully fetched from \(source.displayName)\nStatus: \(code) - \(message)"
        case .authenticationFailure(let code, let message):
            alertTitle = "Authentication Error"
            alertMessage = "\(source.displayName): \(code) - \(message)"
        case .connectionError(let message):
            alertTitle = "Connection Error"
            alertMessage = "\(source.displayName): \(message)"
        case .dataError(let code, let message):
            alertTitle = "Data Error"
            alertMessage = "\(source.displayName): \(code) - \(message)"
        case .unknownError(let message):
            alertTitle = "Error"
            alertMessage = "\(source.displayName): \(message)"
        }
        
        showAlert = true
    }
}

//MARK: - Extension containing syncData function
extension SyncDashboardView {
    /**
     This function performs a series of fetch operations to update local data with the latest
     information from NetBox. It handles each fetch operation sequentially and provides status
     updates through alerts. If any fetch operation fails, the function stops and presents an
     error alert without modifying existing data.
     
     The fetch operations are performed in the following order:
     1. Device Roles
     2. Device Types
     3. Tenants
     4. Regions
     5. Site Groups
     6. Sites
     7. Racks
     8. Devices
     
     - Important: Only one sync operation can run at a time, controlled by `isMonitoringEnabled`.
     - Note: This function runs on a background thread to avoid blocking the UI.
     - Note: Status updates are presented through alerts using `RequestStatusManager`.
     */
    func syncData() async {
        guard !isMonitoringEnabled else {
            print("Sync already in progress, skipping...")
            return
        }
        
        // Reset status at start of new sync
        await MainActor.run {
            RequestStatusManager.shared.resetStatus()
            self.isMonitoringEnabled = true
        }

        // Set monitoring state
        await MainActor.run {
            self.isMonitoringEnabled = true
        }

        defer {
            Task { @MainActor in
                self.isMonitoringEnabled = false
            }
        }

        let container = modelContext.container

        await Task.detached(priority: .background) {
            let modelActor = ProviderModelActor(modelContainer: container)

            do {
                // Execute all operations sequentially
                try await modelActor.getDeviceRoles()
                try await modelActor.getDeviceTypes()
                try await modelActor.getTenants()
//                try await modelActor.getRegions()
                try await modelActor.getSiteGroups()
                try await modelActor.getSites()
                try await modelActor.getRacks()
                try await modelActor.getDevices()

                // Only show success if all operations complete
                await MainActor.run {
                    RequestStatusManager.shared.updateStatus(.netbox, .success(code: 200, message: "All data synchronized successfully"))
                }

            } catch let error as NetboxRequestError {
                print("NetBox error occurred: \(error)")
                await MainActor.run {
                    switch error {
                    case .failure(let code, let message):
                        RequestStatusManager.shared.updateStatus(.netbox, .dataError(code: code, message: message))
                    case .networkError(let error):
                        RequestStatusManager.shared.updateStatus(.netbox, .connectionError(error.localizedDescription))
                    case .decodingError:
                        RequestStatusManager.shared.updateStatus(.netbox, .dataError(code: 0, message: "Failed to decode response"))
                    case .success:
                        break // Should never happen in error case
                    }
                }
                // Exit function on error
                return

            } catch {
                print("Unknown error occurred: \(error)")
                await MainActor.run {
                    RequestStatusManager.shared.updateStatus(.netbox, .unknownError(error.localizedDescription))
                }
                // Exit function on error
                return
            }
        }.value

        await updateCounts()
    }

    /**
     A publisher that emits when the managed object context saves changes.
     The publisher's events are delivered on the main dispatch queue.
     */
    @MainActor
    private func handleNetboxError(_ error: NetboxRequestError, operation: String) async {
        switch error {
        case .failure(let code, let message):
            RequestStatusManager.shared.updateStatus(.netbox, .dataError(code: code, message: "\(operation): \(message)"))
        case .networkError(let error):
            RequestStatusManager.shared.updateStatus(.netbox, .connectionError("\(operation): \(error.localizedDescription)"))
        case .decodingError:
            RequestStatusManager.shared.updateStatus(.netbox, .dataError(code: 0, message: "\(operation): Failed to decode response"))
        case .success:
            break
        }
    }
}


extension NotificationCenter {
    var managedObjectContextDidSavePublisher: Publishers.ReceiveOn<NotificationCenter.Publisher, DispatchQueue> {
        return publisher(for: .NSManagedObjectContextDidSave).receive(on: DispatchQueue.main)
    }
}

