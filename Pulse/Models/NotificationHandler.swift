//
//  NotificationHandler.swift
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
import SwiftUI
import UserNotifications ///Effective in Swift 6 only

/**
 A class responsible for managing local notification permissions and the app badge.
 Pulse runs without CloudKit or any remote push service — alerts are dispatched
 locally from background polling against NetBox/Zabbix/PowerSense.
 */
//@Observable
actor NotificationHandler {
    static let instance = NotificationHandler()
    private var permissionRequested = false

    public init() {}

    /**
     Requests notification permissions from the user.
     This function asks for permissions to display alerts, play sounds, and set the app badge.
     */
    func requestPermission() async {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        do {
            let success = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
            if success {
                print("Notification permissions granted!")
            } else {
                print("Notification permission declined!")
            }
        } catch {
            print("Error requesting notification permission: \(error)")
        }
    }

    func requestPermissionIfNeeded() async {
            if !permissionRequested {
                await requestPermission()
                permissionRequested = true
            }
        }

    /**
     Checks the current notification authorization status of the application.
     Determines whether the application has been granted permission to display notifications.
     */
    func checkNotificationAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let isAuthorized = settings.authorizationStatus != .denied
                continuation.resume(returning: isAuthorized)
            }
        }
    }
    
    /**
     Resets the app's badge count to 0.
     Call this function when you want to clear the badge count, such as when the user opens the app after receiving a notification.
     */
    func resetBadgeCount() async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(0)
            print("Badge count reset to 0")
        } catch {
            print("Failed to reset badge count: \(error.localizedDescription)")
        }
    }
    
    
    /**
     Resets the app's dock tile badge label on macOS.
     Call this function when you want to clear the badge label on the app's dock icon, such as when the user opens the app after receiving a notification.
     */
    @MainActor func resetDockTileBadgeLabel() {
#if os(macOS)
        NSApplication.shared.dockTile.badgeLabel = ""
#endif
    }
}
