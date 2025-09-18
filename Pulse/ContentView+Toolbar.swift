//
//  ContentView+Toolbar.swift
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

// MARK: Toolbar Content for Mac now moved into a separate file
extension ContentView {
#if os(macOS)
    /**
     Constructs the toolbar content for macOS.
     
     This function builds a set of toolbar items including navigation, status, and primary action components.
     */
    
    @ToolbarContentBuilder
    func toolbarContent() -> some ToolbarContent {
        
        ToolbarItem(placement: .navigation) {
            FilterButton(
                openSiteGroups: $openSiteGroups,
                selectedSiteGroups: $selectedSiteGroups,
                selectedSite: $selectedSite
            )
            
        }
        
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .status) {
                Image(systemName: "swiftdata")
                    .font(.system(size: 22))
                    .foregroundColor(getSymbolColor(for: syncProvider.first?.lastZabbixUpdate))
            }
            .sharedBackgroundVisibility(.hidden)
            
            ToolbarSpacer()
        } else {
            ToolbarItem(placement: .status) {
                Image(systemName: "swiftdata")
                    .font(.system(size: 22))
                    .foregroundColor(getSymbolColor(for: syncProvider.first?.lastZabbixUpdate))
            }
        }
        
        ToolbarItem(placement: .primaryAction) {
            Toggle("Fetch Events", isOn: $isEventMonitoringEnabled)
                .help("Enable/Disable Event Monitoring")
                .onChange(of: isEventMonitoringEnabled) {
                    Task.detached(priority: .background) {
                        await updateEventMonitoring()
                    }
                }
                .toggleStyle(.switch)
                .popoverTip(tipManager.fetchEventsTip, arrowEdge: .bottom)
        }
            
        ToolbarItem() {
            MapStyleButton(openMapStyles: $openMapStyles, mapStyle: $mapStyle)
        }

        ToolbarItem() {
            EventCounter()
        }

        ToolbarItem() {
            // PowerSense overlay toggle
            Button(action: {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showPowerSenseOverlay.toggle()
                }
            }) {
                Image(systemName: showPowerSenseOverlay ? "bolt.fill" : "bolt")
                    .foregroundStyle(showPowerSenseOverlay ? .blue : .gray)
                    .scaleEffect(showPowerSenseOverlay ? 1.1 : 1.0)
            }
            .help(showPowerSenseOverlay ? "Hide PowerSense Heat Map" : "Show PowerSense Heat Map")
        }

    }
#endif
    
    /**
     Determines whether a given site group is within the user-selected site groups.
     
     - Parameters:
     - group: The `SiteGroup` instance to check.
     - selectedSiteGroups: An array of `String` representing the names of selected site groups.
     - Returns: A `Bool` indicating whether the `group` is within the `selectedSiteGroups`.
     */
    private func isInSelectedSiteGroups(_ group: SiteGroup?, in selectedSiteGroups: [String]) -> Bool {
        guard let group = group else { return false }
        if selectedSiteGroups.contains(group.name) {
            return true
        } else {
            return isInSelectedSiteGroups(group.parent, in: selectedSiteGroups)
        }
    }
    
    /**
     Starts monitoring for Zabbix updates.
     
     This function sets up a timer to regularly check for Zabbix updates and triggers notifications if needed.
     */
    func startMonitoringZabbixUpdates() {
        zabbixUpdateTimer?.invalidate() // Invalidate any existing timer.
        // On initial app start, run monitoring of Zabbix updates
        self.monitorZabbixUpdate()
        
        zabbixUpdateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                self.monitorZabbixUpdate()
            }
        }
    }
    
    /**
     Initializes and starts a timer to monitor Zabbix updates, triggering notifications as needed.
     
     This function sets up a repeating timer that executes `monitorZabbixUpdate` every 60 seconds to check for and respond to Zabbix update statuses.
     */
    func monitorZabbixUpdate() {
        if let existingProvider = syncProvider.first {
            let lastUpdate = existingProvider.lastZabbixUpdate ?? Date ()
            let fiveMinutesAgo = Date().addingTimeInterval(-300) // 300 seconds = 5 minutes
            
            if lastUpdate < fiveMinutesAgo && existingProvider.userNotifiedZabbix == false  {
                dispatchNotification()
                existingProvider.userNotifiedZabbix = true
            } else if lastUpdate < fiveMinutesAgo && existingProvider.userNotifiedZabbix == true {
                print("Zabbix data out of date but user notified. Doing nothing.")
            } else {
                existingProvider.userNotifiedZabbix = false
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["ZabbixUpdateNotification"])
            }
        }
    }
    
    //TODO: Resolve EXC_BREAKPOINT error
    /**
     Initiates a notification process if there are no pending notifications for Zabbix updates.
     
     This function queries the notification center for pending requests. If there is no pending notification
     for Zabbix updates, it calls `scheduleNotification` to create one.
     */
    func dispatchNotification() {
        //Notification content
        let content = UNMutableNotificationContent()
        content.title = "Live Data Disabled"
        content.body = "Monitoring data is out of date. Please re-enable fetching for real-time updates."
        // Ensure the trigger does not repeat by setting repeats: false
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: "ZabbixUpdateNotification", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }
    
    /**
     Removes all notifications from the notification center.
     
     This function clears any notifications that are scheduled or already delivered, ensuring that the notification
     center is reset to a clean state.
     */
    func resetAllNotifications() {
        // Remove all pending notifications
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        
        // Optional: Remove all delivered notifications from Notification Center
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    
    private func getSymbolColor(for lastUpdate: Date?) -> Color {
        guard let lastUpdate = lastUpdate else {
            return .gray // Default color if no update is available
        }
        
        let now = Date()
        let timeDifference = now.timeIntervalSince(lastUpdate)
        
        switch timeDifference {
        case let diff where diff < 300: // Less than 5 minutes
            return .green
        case let diff where diff >= 300 && diff < 600: // Between 5 and 10 minutes
            return .orange
        default: // More than 10 minutes
            return .red
        }
    }
    
}
