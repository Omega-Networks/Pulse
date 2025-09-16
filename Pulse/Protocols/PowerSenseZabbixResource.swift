//
//  PowerSenseZabbixResource.swift
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
import OSLog

// MARK: - PowerSense Zabbix API

/// Separate API client for PowerSense Zabbix instance
/// This handles bearer token authentication for the PowerSense-specific Zabbix server
final class PowerSenseZabbixAPI: @unchecked Sendable {
    static let shared = PowerSenseZabbixAPI()
    private let logger = Logger(subsystem: "powersense", category: "zabbixAPI")

    private init() {
        logger.debug("Initializing PowerSenseZabbixAPI singleton")
    }

    /// Retrieves the PowerSense bearer token from configuration
    /// - Returns: A valid bearer token for PowerSense Zabbix instance
    /// - Throws: PowerSenseZabbixError if token is not configured
    func getBearerToken() async throws -> String {
        let token = await Configuration.shared.getPowerSenseZabbixToken()

        guard !token.isEmpty else {
            logger.error("PowerSense bearer token not configured")
            throw PowerSenseZabbixError.authenticationFailed("Bearer token not configured")
        }

        logger.debug("Retrieved PowerSense bearer token (length: \(token.count))")
        return token
    }

    /// Clear any cached session data (kept for API compatibility)
    func clearSession() async {
        logger.debug("PowerSense session cleared (bearer token authentication)")
    }
}

// MARK: - PowerSense Zabbix Resource Protocol

/// Protocol for PowerSense-specific Zabbix API resources
protocol PowerSenseZabbixResource {
    associatedtype ModelType: Decodable
    var methodPath: String { get }
    var method: String { get }
    var params: [String: Any]? { get }
    var headers: [String: String]? { get }
}

extension PowerSenseZabbixResource {
    var request: URLRequest {
        get async throws {
            let logger = Logger(subsystem: "powersense", category: "zabbixResource")
            let startTime = Date()

            // Get PowerSense Zabbix URL from configuration
            let powerSenseZabbixServer = await Configuration.shared.getPowerSenseZabbixServer()
            guard !powerSenseZabbixServer.isEmpty else {
                logger.error("PowerSense Zabbix server URL not configured")
                throw PowerSenseZabbixError.invalidRequest
            }

            // Build the API URL - try different common paths
            let apiPath = "api_jsonrpc.php"
            guard let baseURL = URL(string: powerSenseZabbixServer),
                  let url = URL(string: apiPath, relativeTo: baseURL) else {
                logger.error("PowerSense Zabbix server URL invalid: \(powerSenseZabbixServer)")
                throw PowerSenseZabbixError.invalidRequest
            }

            logger.debug("PowerSense API URL: \(url.absoluteString)")

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json-rpc", forHTTPHeaderField: "Content-Type")

            // Add bearer token authentication for newer Zabbix versions
            let tokenStartTime = Date()
            let bearerToken = try await PowerSenseZabbixAPI.shared.getBearerToken()
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            logger.debug("PowerSense bearer token setup took: \(Date().timeIntervalSince(tokenStartTime))s")

            // Prepare request data (no auth field needed with bearer token)
            let requestData: [String: Any] = [
                "jsonrpc": "2.0",
                "method": method,
                "params": params ?? [:],
                "id": 1
            ]

            // Serialize request data
            let serializationStartTime = Date()
            request.httpBody = try JSONSerialization.data(withJSONObject: requestData)
            logger.debug("PowerSense request serialization took: \(Date().timeIntervalSince(serializationStartTime))s")

            // Log the request data for debugging
            if let requestJsonData = try? JSONSerialization.data(withJSONObject: requestData, options: .prettyPrinted),
               let requestJsonString = String(data: requestJsonData, encoding: .utf8) {
                logger.debug("PowerSense API request: \(requestJsonString)")
            }

            // Add any additional headers
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            logger.debug("Total PowerSense request generation took: \(Date().timeIntervalSince(startTime))s")
            return request
        }
    }
}

// MARK: - PowerSense Zabbix Errors

enum PowerSenseZabbixError: Error {
    case invalidRequest
    case invalidResponse(String)
    case authenticationFailed(String)
    case sessionExpired
    case missingParameters(String)
    case configurationMissing
    case powerSenseDisabled

    var localizedDescription: String {
        switch self {
        case .invalidRequest: return "Invalid PowerSense request configuration"
        case .invalidResponse(let message): return "Invalid PowerSense response: \(message)"
        case .authenticationFailed(let message): return "PowerSense authentication failed: \(message)"
        case .sessionExpired: return "PowerSense session expired"
        case .missingParameters(let params): return "Missing required PowerSense parameters: \(params)"
        case .configurationMissing: return "PowerSense configuration is missing or incomplete"
        case .powerSenseDisabled: return "PowerSense integration is disabled"
        }
    }
}

// MARK: - PowerSense Resource Implementations

/// Resource for retrieving PowerSense ONT hosts (devices)
struct PowerSenseHostResource: PowerSenseZabbixResource {
    typealias ModelType = PowerSenseDeviceProperties

    let method = "host.get"
    let methodPath = ""

    let hostIds: [String]?
    let groupNames: [String]?

    init(hostIds: [String]? = nil, groupNames: [String]? = nil) {
        self.hostIds = hostIds
        self.groupNames = groupNames
    }

    var params: [String: Any]? {
        var parameters: [String: Any] = [:]

        if let hostIds = hostIds, !hostIds.isEmpty {
            // If specific host IDs are requested, use them
            parameters["hostids"] = hostIds
            parameters["output"] = ["hostid", "name", "status", "host"]
            parameters["selectMacros"] = ["macro", "value", "description"]
        } else {
            // Optimized request for PowerSense devices
            parameters["search"] = [
                "template": ["PowerSense Device"]
            ]
            // Only request the fields we actually need
            parameters["output"] = ["hostid", "name", "status", "host"]
            parameters["selectMacros"] = ["macro", "value", "description"]
            parameters["templateids"] = ["10614"]
            parameters["limit"] = 1000  // Pull 1,000 devices at once
        }

        if let groupNames = groupNames, !groupNames.isEmpty {
            parameters["groupids"] = groupNames
        }

        return parameters
    }

    var headers: [String: String]? = nil
}

/// Resource for retrieving PowerSense power events
struct PowerSenseEventResource: PowerSenseZabbixResource {
    typealias ModelType = PowerSenseEventProperties

    let method = "problem.get"
    let methodPath = ""

    let hostIds: [String]?
    let timeFrom: Date?
    let timeTill: Date?
    let limit: Int

    init(hostIds: [String]? = nil,
         timeFrom: Date? = nil,
         timeTill: Date? = nil,
         limit: Int = 100) {
        self.hostIds = hostIds
        self.timeFrom = timeFrom
        self.timeTill = timeTill
        self.limit = limit
    }

    var params: [String: Any]? {
        var parameters: [String: Any] = [
            "output": ["eventid", "source", "object", "objectid", "clock", "ns", "name", "severity"],
            "selectAcknowledges": "extend",
            "selectTags": "extend",
            "recent": false,
            "sortfield": ["eventid"],
            "sortorder": "DESC",
            "limit": limit
        ]

        if let hostIds = hostIds, !hostIds.isEmpty {
            parameters["hostids"] = hostIds
        }

        if let timeFrom = timeFrom {
            parameters["time_from"] = Int(timeFrom.timeIntervalSince1970)
        }

        if let timeTill = timeTill {
            parameters["time_till"] = Int(timeTill.timeIntervalSince1970)
        }

        return parameters
    }

    var headers: [String: String]? = nil
}

/// Resource for retrieving recent PowerSense problems (active outages)
struct PowerSenseProblemsResource: PowerSenseZabbixResource {
    typealias ModelType = PowerSenseEventProperties

    let method = "problem.get"
    let methodPath = ""

    let hostIds: [String]?
    let severityMin: Int

    init(hostIds: [String]? = nil, severityMin: Int = 1) {
        self.hostIds = hostIds
        self.severityMin = severityMin
    }

    var params: [String: Any]? {
        var parameters: [String: Any] = [
            "output": "extend",
            "selectHosts": ["hostid"],
            "sortfield": ["eventid"],
            "sortorder": "DESC",
            "recent": true,
            "severities": [severityMin, 2, 3, 4, 5] // Exclude "Not classified" (0)
        ]

        if let hostIds = hostIds, !hostIds.isEmpty {
            parameters["hostids"] = hostIds
        }

        return parameters
    }

    var headers: [String: String]? = nil
}

// MARK: - PowerSense API Functions

/// Fetch PowerSense ONT devices from the dedicated Zabbix instance
func fetchPowerSenseDevices(hostIds: [String]? = nil, groupNames: [String]? = nil) async throws -> [PowerSenseDeviceProperties] {
    let logger = Logger(subsystem: "powersense", category: "api")

    // Check if PowerSense is enabled and configured
    let config = await Configuration.shared
    guard await config.isPowerSenseEnabled() else {
        throw PowerSenseZabbixError.powerSenseDisabled
    }

    guard await config.isPowerSenseConfigured() else {
        throw PowerSenseZabbixError.configurationMissing
    }

    logger.debug("Fetching PowerSense devices: hostIds=\(hostIds?.description ?? "nil"), groupNames=\(groupNames?.description ?? "nil")")

    let resource = PowerSenseHostResource(hostIds: hostIds, groupNames: groupNames)
    let request = try await resource.request
    let (data, response) = try await URLSession.shared.data(for: request)

    // Log response details for debugging
    if let httpResponse = response as? HTTPURLResponse {
        logger.debug("PowerSense HTTP response: \(httpResponse.statusCode)")
        logger.debug("PowerSense response headers: \(httpResponse.allHeaderFields)")
    }

    // Log raw response data
    if let responseString = String(data: data, encoding: .utf8) {
        logger.debug("PowerSense raw response: \(responseString)")
    } else {
        logger.debug("PowerSense response data length: \(data.count) bytes (not UTF-8)")
    }

    // Try to parse JSON with better error handling
    let jsonObject: [String: Any]
    do {
        jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    } catch {
        logger.error("JSON parsing error: \(error)")
        logger.error("Response was not valid JSON")
        throw PowerSenseZabbixError.invalidResponse("Invalid JSON response: \(error.localizedDescription)")
    }

    // Log the raw response for debugging
    if let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        logger.debug("PowerSense API response: \(jsonString)")
    }

    if let result = jsonObject["result"] as? [[String: Any]] {
        let jsonData = try JSONSerialization.data(withJSONObject: result)
        let devices = try JSONDecoder().decode([PowerSenseDeviceProperties].self, from: jsonData)
        logger.debug("Successfully fetched \(devices.count) PowerSense devices")
        return devices.filter { $0.isValid }
    } else if let error = jsonObject["error"] as? [String: Any] {
        let errorCode = error["code"] as? Int ?? -1
        let errorMessage = error["message"] as? String ?? "Unknown error"
        let errorData = error["data"] as? String ?? ""
        let fullError = "Code: \(errorCode), Message: \(errorMessage), Data: \(errorData)"
        logger.error("PowerSense API error: \(fullError)")
        throw PowerSenseZabbixError.invalidResponse(fullError)
    } else {
        let errorDescription = "Invalid response structure"
        logger.error("Error fetching PowerSense devices: \(errorDescription)")
        throw PowerSenseZabbixError.invalidResponse(errorDescription)
    }
}

/// Fetch PowerSense power events from the dedicated Zabbix instance
func fetchPowerSenseEvents(hostIds: [String]? = nil, timeFrom: Date? = nil, timeTill: Date? = nil) async throws -> [PowerSenseEventProperties] {
    let logger = Logger(subsystem: "powersense", category: "api")

    // Check if PowerSense is enabled and configured
    let config = await Configuration.shared
    guard await config.isPowerSenseEnabled() else {
        throw PowerSenseZabbixError.powerSenseDisabled
    }

    guard await config.isPowerSenseConfigured() else {
        throw PowerSenseZabbixError.configurationMissing
    }

    logger.debug("Fetching PowerSense events: hostIds=\(hostIds?.description ?? "nil")")

    let resource = PowerSenseEventResource(hostIds: hostIds, timeFrom: timeFrom, timeTill: timeTill)
    let request = try await resource.request
    let (data, _) = try await URLSession.shared.data(for: request)

    let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    if let result = jsonObject["result"] as? [[String: Any]] {
        let jsonData = try JSONSerialization.data(withJSONObject: result)
        let events = try JSONDecoder().decode([PowerSenseEventProperties].self, from: jsonData)
        logger.debug("Successfully fetched \(events.count) PowerSense events")
        return events.filter { $0.isValid }
    } else if let error = jsonObject["error"] as? [String: Any] {
        let errorCode = error["code"] as? Int ?? -1
        let errorMessage = error["message"] as? String ?? "Unknown error"
        let errorData = error["data"] as? String ?? ""
        let fullError = "Code: \(errorCode), Message: \(errorMessage), Data: \(errorData)"
        logger.error("PowerSense API error: \(fullError)")
        throw PowerSenseZabbixError.invalidResponse(fullError)
    } else {
        let errorDescription = "Invalid response structure"
        logger.error("Error fetching PowerSense events: \(errorDescription)")
        throw PowerSenseZabbixError.invalidResponse(errorDescription)
    }
}

/// Fetch active PowerSense problems (ongoing outages)
func fetchPowerSenseProblems(hostIds: [String]? = nil) async throws -> [PowerSenseEventProperties] {
    let logger = Logger(subsystem: "powersense", category: "api")

    // Check if PowerSense is enabled and configured
    let config = await Configuration.shared
    guard await config.isPowerSenseEnabled() else {
        throw PowerSenseZabbixError.powerSenseDisabled
    }

    guard await config.isPowerSenseConfigured() else {
        throw PowerSenseZabbixError.configurationMissing
    }

    logger.debug("Fetching PowerSense problems: hostIds=\(hostIds?.description ?? "nil")")

    let resource = PowerSenseProblemsResource(hostIds: hostIds)
    let request = try await resource.request
    let (data, _) = try await URLSession.shared.data(for: request)

    let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    if let result = jsonObject["result"] as? [[String: Any]] {
        let jsonData = try JSONSerialization.data(withJSONObject: result)
        let problems = try JSONDecoder().decode([PowerSenseEventProperties].self, from: jsonData)
        logger.debug("Successfully fetched \(problems.count) PowerSense problems")
        return problems.filter { $0.isValid }
    } else if let error = jsonObject["error"] as? [String: Any] {
        let errorCode = error["code"] as? Int ?? -1
        let errorMessage = error["message"] as? String ?? "Unknown error"
        let errorData = error["data"] as? String ?? ""
        let fullError = "Code: \(errorCode), Message: \(errorMessage), Data: \(errorData)"
        logger.error("PowerSense API error: \(fullError)")
        throw PowerSenseZabbixError.invalidResponse(fullError)
    } else {
        let errorDescription = "Invalid response structure"
        logger.error("Error fetching PowerSense problems: \(errorDescription)")
        throw PowerSenseZabbixError.invalidResponse(errorDescription)
    }
}