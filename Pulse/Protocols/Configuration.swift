
//
//  Configuration.swift
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
import Security

/// Global actor to ensure thread-safe access to configuration values
@globalActor actor ConfigurationActor {
    static let shared = ConfigurationActor()
}

/// Configuration manager for Pulse application
/// Handles secure storage and retrieval of API credentials and application settings
/// Uses a combination of Keychain (for sensitive data) and UserDefaults (for non-sensitive data)
@ConfigurationActor
final class Configuration: @unchecked Sendable {
    // MARK: - Constants
    
    /// UserDefaults and Keychain keys
    enum Keys {
        static let netboxApiServer = "netboxApiServer"
        static let netboxApiToken = "netboxApiToken"
        static let zabbixApiServer = "zabbixApiServer"
        static let zabbixApiUser = "zabbixApiUser"
        static let zabbixApiToken = "zabbixApiToken"
        static let problemTimeWindow = "problemTimeWindow"
        static let hasCompletedInitialSetup = "hasCompletedInitialSetup"

        // PowerSense Configuration
        static let powerSenseEnabled = "powerSenseEnabled"
        static let powerSenseZabbixServer = "powerSenseZabbixServer"
        static let powerSenseZabbixUser = "powerSenseZabbixUser"
        static let powerSenseZabbixToken = "powerSenseZabbixToken"
        static let powerSenseUpdateInterval = "powerSenseUpdateInterval"
        static let powerSenseMinDeviceThreshold = "powerSenseMinDeviceThreshold"
        static let powerSenseGridSize = "powerSenseGridSize"
    }
    
    /// Example values for configuration (non-functional placeholders)
    enum Examples {
        static let netboxServer = "https://netbox.example.com"
        static let zabbixServer = "https://zabbix.example.com"
        static let problemTimeWindow = 3600 // 1 hour in seconds

        // PowerSense defaults
        static let powerSenseZabbixServer = "https://powersense-zabbix.example.com"
        static let powerSenseUpdateInterval = 60 // 60 seconds
        static let powerSenseMinDeviceThreshold = 3 // Minimum devices before showing aggregation
        static let powerSenseGridSize = 100 // Grid size in meters
    }
    
    // MARK: - Singleton
    
    static let shared = Configuration()
    
    private init() {
        // Set default problem time window only (non-sensitive)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.problemTimeWindow) == nil {
            defaults.set(Examples.problemTimeWindow, forKey: Keys.problemTimeWindow)
        }
    }
    
    // MARK: - Setup Status
    
    /// Check if initial configuration has been completed
    func hasCompletedInitialSetup() -> Bool {
        // Check if all required credentials are present
        let hasNetboxServer = !getNetboxApiServer().isEmpty
        let hasNetboxToken = !getNetboxApiToken().isEmpty
        let hasZabbixServer = !getZabbixApiServer().isEmpty
        let hasZabbixUser = !getZabbixApiUser().isEmpty
        let hasZabbixToken = !getZabbixApiToken().isEmpty
        
        let isConfigured = hasNetboxServer && hasNetboxToken && hasZabbixServer && hasZabbixUser && hasZabbixToken
        
        if !isConfigured {
            print("Configuration check failed:")
            print("  NetBox Server: \(hasNetboxServer ? "✓" : "✗")")
            print("  NetBox Token: \(hasNetboxToken ? "✓" : "✗")")
            print("  Zabbix Server: \(hasZabbixServer ? "✓" : "✗")")
            print("  Zabbix User: \(hasZabbixUser ? "✓" : "✗")")
            print("  Zabbix Token: \(hasZabbixToken ? "✓" : "✗")")
        }
        
        return isConfigured
    }
    
    /// Mark initial setup as completed
    func markInitialSetupCompleted() {
        UserDefaults.standard.set(true, forKey: Keys.hasCompletedInitialSetup)
    }
    
    // MARK: - Validation
    
    /// Validate if all required credentials are configured
    func validateConfiguration() -> (isValid: Bool, missingFields: [String]) {
        var missingFields: [String] = []
        
        if getNetboxApiServer().isEmpty {
            missingFields.append("NetBox Server URL")
        }
        if getNetboxApiToken().isEmpty {
            missingFields.append("NetBox API Token")
        }
        if getZabbixApiServer().isEmpty {
            missingFields.append("Zabbix Server URL")
        }
        if getZabbixApiUser().isEmpty {
            missingFields.append("Zabbix Username")
        }
        if getZabbixApiToken().isEmpty {
            missingFields.append("Zabbix API Token")
        }
        
        return (missingFields.isEmpty, missingFields)
    }
    
    // MARK: - Keychain Access
    
    private func saveToKeychain(key: String, data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil)
    }
    
    private func loadFromKeychain(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        return (status == errSecSuccess) ? (result as? Data) : nil
    }
    
    private func deleteFromKeychain(key: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        
        return SecItemDelete(query as CFDictionary)
    }
    
    // MARK: - Clear Configuration
    
    /// Clear all stored credentials (useful for logout/reset)
    func clearAllCredentials() {
        // Clear from Keychain
        _ = deleteFromKeychain(key: Keys.netboxApiToken)
        _ = deleteFromKeychain(key: Keys.zabbixApiToken)
        
        // Clear from UserDefaults
        UserDefaults.standard.removeObject(forKey: Keys.netboxApiServer)
        UserDefaults.standard.removeObject(forKey: Keys.zabbixApiServer)
        UserDefaults.standard.removeObject(forKey: Keys.zabbixApiUser)
        UserDefaults.standard.removeObject(forKey: Keys.hasCompletedInitialSetup)
    }
    
    // MARK: - Problem Time Window Configuration
    
    func getProblemTimeWindow() -> Int {
        return UserDefaults.standard.integer(forKey: Keys.problemTimeWindow)
    }
    
    func setProblemTimeWindow(_ seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: Keys.problemTimeWindow)
    }
    
    // MARK: - API Configurations
    
    // NetBox Configuration
    func getNetboxApiServer() -> String {
        let server = UserDefaults.standard.string(forKey: Keys.netboxApiServer) ?? ""
        return server
    }
    
    func setNetboxApiServer(_ server: String) {
        UserDefaults.standard.set(server, forKey: Keys.netboxApiServer)
        UserDefaults.standard.synchronize()
    }
    
    func getNetboxApiToken() -> String {
        if let data = loadFromKeychain(key: Keys.netboxApiToken),
           let token = String(data: data, encoding: .utf8) {
            return token
        }
        return ""
    }
    
    func setNetboxApiToken(_ token: String) {
        guard !token.isEmpty else { return }
        let status = saveToKeychain(key: Keys.netboxApiToken, data: Data(token.utf8))
        if status != errSecSuccess {
            print("Failed to save NetBox API Token to Keychain: \(status)")
        }
    }
    
    // Zabbix Configuration
    func getZabbixApiServer() -> String {
        return UserDefaults.standard.string(forKey: Keys.zabbixApiServer) ?? ""
    }
    
    func setZabbixApiServer(_ server: String) {
        UserDefaults.standard.set(server, forKey: Keys.zabbixApiServer)
    }
    
    func getZabbixApiUser() -> String {
        return UserDefaults.standard.string(forKey: Keys.zabbixApiUser) ?? ""
    }
    
    func setZabbixApiUser(_ user: String) {
        UserDefaults.standard.set(user, forKey: Keys.zabbixApiUser)
    }
    
    func getZabbixApiToken() -> String {
        if let data = loadFromKeychain(key: Keys.zabbixApiToken),
           let token = String(data: data, encoding: .utf8) {
            return token
        }
        return ""
    }
    
    func setZabbixApiToken(_ token: String) {
        guard !token.isEmpty else { return }
        let status = saveToKeychain(key: Keys.zabbixApiToken, data: Data(token.utf8))
        if status != errSecSuccess {
            print("Failed to save Zabbix API Token to Keychain: \(status)")
        }
    }
    
    // MARK: - Bulk Updates
    
    func updateSettings(
        netboxApiServer: String,
        netboxApiToken: String,
        zabbixApiServer: String,
        zabbixApiUser: String,
        zabbixApiToken: String
    ) {
        setNetboxApiServer(netboxApiServer)
        setNetboxApiToken(netboxApiToken)
        setZabbixApiServer(zabbixApiServer)
        setZabbixApiUser(zabbixApiUser)
        setZabbixApiToken(zabbixApiToken)
        markInitialSetupCompleted()
    }
    
    // MARK: - PowerSense Configuration

    /// Check if PowerSense integration is enabled
    func isPowerSenseEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: Keys.powerSenseEnabled)
    }

    /// Enable or disable PowerSense integration
    func setPowerSenseEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Keys.powerSenseEnabled)
    }

    /// PowerSense Zabbix Server URL
    func getPowerSenseZabbixServer() -> String {
        return UserDefaults.standard.string(forKey: Keys.powerSenseZabbixServer) ?? ""
    }

    func setPowerSenseZabbixServer(_ server: String) {
        UserDefaults.standard.set(server, forKey: Keys.powerSenseZabbixServer)
    }

    /// PowerSense Zabbix Username
    func getPowerSenseZabbixUser() -> String {
        return UserDefaults.standard.string(forKey: Keys.powerSenseZabbixUser) ?? ""
    }

    func setPowerSenseZabbixUser(_ user: String) {
        UserDefaults.standard.set(user, forKey: Keys.powerSenseZabbixUser)
    }

    /// PowerSense Zabbix API Token (stored in Keychain)
    func getPowerSenseZabbixToken() -> String {
        if let data = loadFromKeychain(key: Keys.powerSenseZabbixToken),
           let token = String(data: data, encoding: .utf8) {
            return token
        }
        return ""
    }

    func setPowerSenseZabbixToken(_ token: String) {
        guard !token.isEmpty else { return }
        let status = saveToKeychain(key: Keys.powerSenseZabbixToken, data: Data(token.utf8))
        if status != errSecSuccess {
            print("Failed to save PowerSense Zabbix API Token to Keychain: \(status)")
        }
    }

    /// PowerSense update interval in seconds
    func getPowerSenseUpdateInterval() -> Int {
        let value = UserDefaults.standard.integer(forKey: Keys.powerSenseUpdateInterval)
        return value > 0 ? value : Examples.powerSenseUpdateInterval
    }

    func setPowerSenseUpdateInterval(_ interval: Int) {
        UserDefaults.standard.set(interval, forKey: Keys.powerSenseUpdateInterval)
    }

    /// Minimum device threshold for privacy aggregation
    func getPowerSenseMinDeviceThreshold() -> Int {
        let value = UserDefaults.standard.integer(forKey: Keys.powerSenseMinDeviceThreshold)
        return value > 0 ? value : Examples.powerSenseMinDeviceThreshold
    }

    func setPowerSenseMinDeviceThreshold(_ threshold: Int) {
        UserDefaults.standard.set(threshold, forKey: Keys.powerSenseMinDeviceThreshold)
    }

    /// PowerSense grid size in meters for aggregation
    func getPowerSenseGridSize() -> Int {
        let value = UserDefaults.standard.integer(forKey: Keys.powerSenseGridSize)
        return value > 0 ? value : Examples.powerSenseGridSize
    }

    func setPowerSenseGridSize(_ size: Int) {
        UserDefaults.standard.set(size, forKey: Keys.powerSenseGridSize)
    }

    /// Check if PowerSense is properly configured
    func isPowerSenseConfigured() -> Bool {
        return isPowerSenseEnabled() &&
               !getPowerSenseZabbixServer().isEmpty &&
               !getPowerSenseZabbixToken().isEmpty
    }

    /// Update PowerSense settings in bulk
    func updatePowerSenseSettings(
        enabled: Bool,
        zabbixServer: String,
        zabbixUser: String,
        zabbixToken: String,
        updateInterval: Int? = nil,
        minDeviceThreshold: Int? = nil,
        gridSize: Int? = nil
    ) {
        setPowerSenseEnabled(enabled)
        setPowerSenseZabbixServer(zabbixServer)
        setPowerSenseZabbixUser(zabbixUser)
        setPowerSenseZabbixToken(zabbixToken)

        if let interval = updateInterval {
            setPowerSenseUpdateInterval(interval)
        }
        if let threshold = minDeviceThreshold {
            setPowerSenseMinDeviceThreshold(threshold)
        }
        if let size = gridSize {
            setPowerSenseGridSize(size)
        }
    }

    /// Clear PowerSense configuration
    func clearPowerSenseConfiguration() {
        UserDefaults.standard.removeObject(forKey: Keys.powerSenseEnabled)
        UserDefaults.standard.removeObject(forKey: Keys.powerSenseZabbixServer)
        UserDefaults.standard.removeObject(forKey: Keys.powerSenseZabbixUser)
        UserDefaults.standard.removeObject(forKey: Keys.powerSenseUpdateInterval)
        UserDefaults.standard.removeObject(forKey: Keys.powerSenseMinDeviceThreshold)
        UserDefaults.standard.removeObject(forKey: Keys.powerSenseGridSize)
        _ = deleteFromKeychain(key: Keys.powerSenseZabbixToken)
    }

    // MARK: - Example Values (for UI placeholders only)

    static var exampleConfiguration: (netboxServer: String, zabbixServer: String) {
        return (Examples.netboxServer, Examples.zabbixServer)
    }

    static var examplePowerSenseConfiguration: (zabbixServer: String, updateInterval: Int, minThreshold: Int, gridSize: Int) {
        return (
            Examples.powerSenseZabbixServer,
            Examples.powerSenseUpdateInterval,
            Examples.powerSenseMinDeviceThreshold,
            Examples.powerSenseGridSize
        )
    }
}

// MARK: - UserDefaults Extensions

extension UserDefaults {
    /// Convenience methods for accessing configuration values
    static func getProblemTimeWindow() -> Int {
        let value = standard.integer(forKey: Configuration.Keys.problemTimeWindow)
        return value > 0 ? value : Configuration.Examples.problemTimeWindow
    }
}
