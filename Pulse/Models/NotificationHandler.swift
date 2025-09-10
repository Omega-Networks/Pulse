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
import CloudKit
import UserNotifications ///Effective in Swift 6 only

/**
 A class responsible for managing notification permissions and handling CloudKit subscriptions.
 This class deals with both local notification permissions and remote notifications that are triggered by data changes in the CloudKit database, specifically for the Pulse app.
 */
//@Observable
actor NotificationHandler {
    static let instance = NotificationHandler()
    private var permissionRequested = false
    
    public init() {}
    
    /**
     Requests notification permissions from the user.
     This function asks for permissions to display alerts, play sounds, and set the app badge.
     If permissions are granted, it proceeds to register the app for remote notifications and subscribes to high severity events.
     */
    func requestPermission() async {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        do {
            let success = try await UNUserNotificationCenter.current().requestAuthorization(options: options)
            if success {
                print("Notification permissions granted!")
                await registerForRemoteNotifications()
                await subscribeToHighSeverityEvents()
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
    
    private func registerForRemoteNotifications() async {
        await MainActor.run {
#if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
#elseif os(macOS)
            NSApplication.shared.registerForRemoteNotifications()
#endif
        }
    }
    
    /**
     Creates a subscription to CloudKit for monitoring changes in Event records with high severity.
     This function sets up a subscription to notify the user when a Event's severity changes to 4 or 5, or when a new high-severity Event is added.
     Utilizes CloudKit's `CKQuerySubscription` to monitor specific record changes based on a defined predicate.
     */
    func subscribeToHighSeverityEvents() async {
        let predicate = NSPredicate(format: "CD_severity IN %@", ["4", "5"])
        
        // Generate a unique subscription ID or use a predefined one
        let subscriptionID = "highSeverityEventsSubscription"
        let subscriptionOptions: CKQuerySubscription.Options = [.firesOnRecordCreation]
        
        // Updated initializer with subscription ID
        let subscription = CKQuerySubscription(recordType: "CD_Event", predicate: predicate, subscriptionID: subscriptionID, options: subscriptionOptions)
        
        let notificationInfo = CKSubscription.NotificationInfo()
        //Setting title and body content to be the fetched record
        notificationInfo.titleLocalizationKey = "event_update_notification_title"
        notificationInfo.alertLocalizationKey = "event_update_notification"
        notificationInfo.titleLocalizationArgs = ["CD_siteName"]
        notificationInfo.alertLocalizationArgs = ["CD_deviceName", "CD_name"]
        
        notificationInfo.soundName = "default"
        notificationInfo.shouldBadge = true
        
        notificationInfo.shouldSendContentAvailable = true // Important for background fetch
        subscription.notificationInfo = notificationInfo
        
        guard let containerID = Bundle.main.infoDictionary?["CloudKitContainerID"] as? String,
              !containerID.isEmpty,
              containerID != "iCloud.default" else {
            print("CloudKit container not configured properly")
            return
        }
        let privateDB = CKContainer(identifier: containerID).privateCloudDatabase
        
        privateDB.save(subscription) { result, error in
            if let error = error {
                print("Subscription failed: \(error.localizedDescription)")
            } else {
                print("Successfully subscribed to high severity events.")
            }
        }
    }
    
    //MARK: Function for subscribing to closed events goes here
    
    /**
     Checks the current notification authorization status of the application.
     Determines whether the application has been granted permission to display notifications.
     This function can be used to decide if the app should attempt to register for remote notifications or subscribe to changes in CloudKit.
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
