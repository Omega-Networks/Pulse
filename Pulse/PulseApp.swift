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
    @Published var containerVerified = false
    @Published var contentViewReady = false
    @Published var startExitAnimation = false
    @Published var isConfigured = false
    let totalSteps = 19.0
    
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
    @StateObject private var initState = InitializationState()
    let tipManager = TipManager.shared
    @State private var showContentView = false
    @State private var sharedLocations = SharedLocations()
    
    let notificationHandler = NotificationHandler()
    let modelContainer: ModelContainer
    
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
                Event.self,
                SyncProvider.self
            )
        } catch {
            fatalError("Failed to initialize modelContainer: \(error)")
        }
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
                        .modelContainer(modelContainer)
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

        WindowGroup("Site View", for: Site.ID.self) { $siteId in
            if showContentView {
                if let id = siteId {
                    SiteView(siteId: id)
                        .modelContainer(modelContainer)
                }
            }
        }
        
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
        
        let steps = [
            "Verifying Device Roles...",
            "Verifying Device Types...",
            "Verifying Tenants...",
            "Verifying Regions...",
            "Verifying Site Groups...",
            "Verifying Sites...",
            "Verifying Racks...",
            "Verifying Devices...",
            "Verifying Events...",
            "Final Verification...",
            "Synchronising Device Roles...",
            "Synchronising Device Types...",
            "Synchronising Tenants...",
            "Synchronising Regions...",
            "Synchronising Site Groups...",
            "Synchronising Sites...",
            "Synchronising Racks...",
            "Synchronising Devices...",
            "Setting up Tips..."
        ]
          
          if !initState.containerVerified {
              
              do {
                  let context = modelContainer.mainContext
                  var index: Int = 0
                  
                  let descriptorDeviceRole = FetchDescriptor<DeviceRole>()
                  _ = try context.fetch(descriptorDeviceRole)
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  let descriptorDeviceType = FetchDescriptor<DeviceType>()
                  _ = try context.fetch(descriptorDeviceType)
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  let descriptorTenant = FetchDescriptor<Tenant>()
                  _ = try context.fetch(descriptorTenant)
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  let descriptorRegion = FetchDescriptor<Region>()
                  _ = try context.fetch(descriptorRegion)
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  let descriptorSiteGroup = FetchDescriptor<SiteGroup>()
                  _ = try context.fetch(descriptorSiteGroup)
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  let descriptorSite = FetchDescriptor<Site>()
                  _ = try context.fetch(descriptorSite)
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  let descriptorRack = FetchDescriptor<Rack>()
                  _ = try context.fetch(descriptorRack)
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  let descriptorDevice = FetchDescriptor<Device>()
                  _ = try context.fetch(descriptorDevice)
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  let descriptorEvent = FetchDescriptor<Event>()
                  _ = try context.fetch(descriptorEvent)
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  // Mark container as verified and show welcome
                  initState.containerVerified = true
                  index += 1
                  initState.updateProgress(index, steps[index])
                  try? await Task.sleep(for: .milliseconds(20))
                  
                  //
                  let modelActor = ProviderModelActor(modelContainer: modelContainer)
                  
                  do {
                      // Execute all operations sequentially
                      try await modelActor.getDeviceRoles()
                      index += 1
                      initState.updateProgress(index, steps[index])
                      try await modelActor.getDeviceTypes()
                      index += 1
                      initState.updateProgress(index, steps[index])
                      try await modelActor.getTenants()
                      index += 1
                      initState.updateProgress(index, steps[index])
                      try await modelActor.getRegions()
                      index += 1
                      initState.updateProgress(index, steps[index])
                      try await modelActor.getSiteGroups()
                      index += 1
                      initState.updateProgress(index, steps[index])
                      try await modelActor.getSites()
                      index += 1
                      initState.updateProgress(index, steps[index])
                      try await modelActor.getRacks()
                      index += 1
                      initState.updateProgress(index, steps[index])
                      try await modelActor.getDevices()
                      index += 1
                      initState.updateProgress(index, steps[index])
                  } catch {
                      print("Sync failed (likely due to missing credentials): \(error)")
                      // Continue to show app but without data
                      initState.currentStep = "Running in Offline Mode"
                      initState.showWelcome = true
                      try? await Task.sleep(for: .seconds(2))
                  }
                  
                  //Completed
                  try? await Task.sleep(for: .milliseconds(500))
                  
                  initState.showWelcome = true
                  initState.currentStep = "Welcome to Pulse"
                  
                  // Give time to see welcome message
                  try? await Task.sleep(for: .milliseconds(1500))
                  
                  // Trigger exit animation
                  initState.startExitAnimation = true
                  
                  // Wait for animation to complete
                  try? await Task.sleep(for: .milliseconds(1100))
                  
                  // Show ContentView
                  withAnimation(.easeInOut(duration: 0.5)) {
                      showContentView = true
                  }
      
                  tipManager.configure()
                  
              } catch {
                  print("Container verification failed: \(error)")
              }
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

