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

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var tipManager = TipManager.shared
    
    // MARK: - State Properties
    
    // NetBox Settings
    @State private var netboxApiServer: String = ""
    @State private var netboxApiToken: String = ""
    
    // Zabbix Settings
    @State private var zabbixApiUser: String = ""
    @State private var zabbixApiServer: String = ""
    @State private var zabbixApiToken: String = ""
    @State private var problemTimeWindow: Double = 1  // In hours
    
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
            
            
            ///Sync dashboard - contains Model Object Counts
            SyncDashboardView()
                .tabItem {
                    Label("Database", systemImage: "swiftdata")
                }
        }
        .padding(20)
        .frame(width: 700)
        
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
        .frame(width: 350)
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
}

