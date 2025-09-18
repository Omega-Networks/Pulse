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
            parameters["limit"] = 1000  // Keep at 1000 to prevent server timeouts
        }

        if let groupNames = groupNames, !groupNames.isEmpty {
            parameters["groupids"] = groupNames
        }

        return parameters
    }

    var headers: [String: String]? = nil
}

/// Resource for counting total PowerSense devices
struct PowerSenseDeviceCountResource: PowerSenseZabbixResource {
    typealias ModelType = PowerSenseDeviceCount
    let method = "host.get"
    let methodPath = ""

    var params: [String: Any]? {
        return [
            "search": [
                "template": ["PowerSense Device"]
            ],
            "templateids": ["10614"],
            "countOutput": true  // This returns just the count
        ]
    }

    var headers: [String: String]? = nil
}

/// Simple structure to hold device count
struct PowerSenseDeviceCount: Codable {
    let count: Int

    init(from decoder: Decoder) throws {
        // Zabbix returns count as a string when using countOutput
        let container = try decoder.singleValueContainer()
        if let countString = try? container.decode(String.self) {
            self.count = Int(countString) ?? 0
        } else {
            self.count = try container.decode(Int.self)
        }
    }
}

/// Simple structure to hold only hostid (for Phase 1)
struct PowerSenseHostIdOnly: Codable {
    let hostid: String
}

/// Phase 1: Resource for retrieving only PowerSense host IDs (lightweight)
struct PowerSenseHostIdsResource: PowerSenseZabbixResource {
    typealias ModelType = PowerSenseHostIdOnly
    let method = "host.get"
    let methodPath = ""

    var params: [String: Any]? {
        return [
            "search": [
                "template": ["PowerSense Device"]
            ],
            "output": ["hostid"],  // Only fetch hostid for lightweight response
            "templateids": ["10614"],
            "sortfield": "hostid",
            "sortorder": "ASC"
            // No limit - fetch all host IDs in one call
        ]
    }

    var headers: [String: String]? = nil
}

/// Phase 2: Resource for retrieving full PowerSense device details by hostid array
struct PowerSenseHostDetailsByIdsResource: PowerSenseZabbixResource {
    typealias ModelType = PowerSenseDeviceProperties
    let method = "host.get"
    let methodPath = ""
    let hostIds: [String]

    init(hostIds: [String]) {
        self.hostIds = hostIds
    }

    var params: [String: Any]? {
        return [
            "hostids": hostIds,  // Exact hostid array lookup
            "output": ["hostid", "name", "status", "host"],
            "selectMacros": ["macro", "value", "description"],
            "sortfield": "hostid",
            "sortorder": "ASC"
        ]
    }

    var headers: [String: String]? = nil
}

/// Resource for retrieving PowerSense power events
struct PowerSenseEventResource: PowerSenseZabbixResource {
    typealias ModelType = PowerSenseEventProperties

    let method = "event.get"
    let methodPath = ""

    let hostIds: [String]?
    let timeFrom: Date?
    let timeTill: Date?
    let limit: Int

    init(hostIds: [String]? = nil,
         timeFrom: Date? = nil,
         timeTill: Date? = nil,
         limit: Int = 1000) {
        self.hostIds = hostIds
        self.timeFrom = timeFrom
        self.timeTill = timeTill
        self.limit = limit
    }

    var params: [String: Any]? {
        var parameters: [String: Any] = [
            "output": ["eventid", "source", "object", "objectid", "clock", "ns", "name", "severity", "r_eventid"],
            "selectAcknowledges": "extend",
            "selectTags": "extend",
            "selectHosts": ["hostid"],
            "tags": [
                [
                    "tag": "classification",
                    "value": "device",
                    "operator": 0
                ],
                [
                    "tag": "component",
                    "value": "power",
                    "operator": 0
                ],
                [
                    "tag": "component",
                    "value": "powersense",
                    "operator": 0
                ]
            ],
            "evaltype": 0,
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
            "selectTags": "extend",
            "tags": [
                [
                    "tag": "classification",
                    "value": "device",
                    "operator": 0
                ],
                [
                    "tag": "component",
                    "value": "power",
                    "operator": 0
                ],
                [
                    "tag": "component",
                    "value": "powersense",
                    "operator": 0
                ]
            ],
            "evaltype": 0,
            "sortfield": ["eventid"],
            "sortorder": "DESC",
            "recent": true
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

/// Count total PowerSense devices available
func countPowerSenseDevices() async throws -> Int {
    let logger = Logger(subsystem: "powersense", category: "api")

    // Check if PowerSense is enabled and configured
    let config = await Configuration.shared
    guard await config.isPowerSenseEnabled() else {
        throw PowerSenseZabbixError.powerSenseDisabled
    }

    guard await config.isPowerSenseConfigured() else {
        throw PowerSenseZabbixError.configurationMissing
    }

    logger.debug("Counting total PowerSense devices...")

    let resource = PowerSenseDeviceCountResource()
    let request = try await resource.request
    let (data, response) = try await URLSession.shared.data(for: request)

    // Log response details for debugging
    if let httpResponse = response as? HTTPURLResponse {
        logger.debug("PowerSense count HTTP response: \(httpResponse.statusCode)")
    }

    // Parse JSON response
    let jsonObject: [String: Any]
    do {
        jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    } catch {
        logger.error("PowerSense count JSON parsing failed: \(error)")
        throw PowerSenseZabbixError.invalidResponse("JSON parsing failed: \(error.localizedDescription)")
    }

    // Check for API error
    if let errorInfo = jsonObject["error"] as? [String: Any] {
        let errorCode = errorInfo["code"] as? Int ?? -1
        let errorMessage = errorInfo["message"] as? String ?? "Unknown error"
        let errorData = errorInfo["data"] as? String ?? ""
        let fullError = "Code: \(errorCode), Message: \(errorMessage), Data: \(errorData)"
        logger.error("PowerSense count API error: \(fullError)")
        throw PowerSenseZabbixError.invalidResponse(fullError)
    }

    // Parse count result
    if let resultString = jsonObject["result"] as? String {
        let count = Int(resultString) ?? 0
        logger.info("Total PowerSense devices: \(count)")
        return count
    } else if let resultInt = jsonObject["result"] as? Int {
        logger.info("Total PowerSense devices: \(resultInt)")
        return resultInt
    } else {
        logger.error("Invalid count response format")
        throw PowerSenseZabbixError.invalidResponse("Count response format invalid")
    }
}

// Old batched function removed - now using two-phase approach:
// Phase 1: fetchAllPowerSenseHostIds()
// Phase 2: fetchPowerSenseDevicesByIds()

/// Phase 1: Fetch all PowerSense host IDs only (lightweight call)
func fetchAllPowerSenseHostIds() async throws -> [String] {
    let logger = Logger(subsystem: "powersense", category: "api")

    // Check if PowerSense is enabled and configured
    let config = await Configuration.shared
    guard await config.isPowerSenseEnabled() else {
        throw PowerSenseZabbixError.powerSenseDisabled
    }

    guard await config.isPowerSenseConfigured() else {
        throw PowerSenseZabbixError.configurationMissing
    }

    logger.info("Phase 1: Fetching all PowerSense host IDs (lightweight call)...")

    let resource = PowerSenseHostIdsResource()
    let request = try await resource.request
    let (data, response) = try await URLSession.shared.data(for: request)

    // Log response details for debugging
    if let httpResponse = response as? HTTPURLResponse {
        logger.debug("PowerSense hostids HTTP response: \(httpResponse.statusCode)")
        logger.debug("Response size: \(data.count) bytes")
    }

    // Parse JSON response
    let jsonObject: [String: Any]
    do {
        jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    } catch {
        logger.error("PowerSense hostids JSON parsing failed: \(error)")
        throw PowerSenseZabbixError.invalidResponse("JSON parsing failed: \(error.localizedDescription)")
    }

    // Check for API error
    if let errorInfo = jsonObject["error"] as? [String: Any] {
        let errorCode = errorInfo["code"] as? Int ?? -1
        let errorMessage = errorInfo["message"] as? String ?? "Unknown error"
        let errorData = errorInfo["data"] as? String ?? ""
        let fullError = "Code: \(errorCode), Message: \(errorMessage), Data: \(errorData)"
        logger.error("PowerSense hostids API error: \(fullError)")
        throw PowerSenseZabbixError.invalidResponse(fullError)
    }

    // Parse hostid results
    if let result = jsonObject["result"] as? [[String: Any]] {
        let jsonData = try JSONSerialization.data(withJSONObject: result)
        let hostIdObjects = try JSONDecoder().decode([PowerSenseHostIdOnly].self, from: jsonData)
        let hostIds = hostIdObjects.map { $0.hostid }

        logger.info("Phase 1 complete: Retrieved \(hostIds.count) PowerSense host IDs")
        logger.debug("Host ID range: \(hostIds.first ?? "none") to \(hostIds.last ?? "none")")

        return hostIds
    } else {
        logger.error("PowerSense hostids result format invalid")
        throw PowerSenseZabbixError.invalidResponse("Result format invalid")
    }
}

/// Phase 2: Fetch full PowerSense device details for specific host IDs
func fetchPowerSenseDevicesByIds(_ hostIds: [String]) async throws -> [PowerSenseDeviceProperties] {
    let logger = Logger(subsystem: "powersense", category: "api")

    guard !hostIds.isEmpty else {
        logger.warning("No host IDs provided for device details fetch")
        return []
    }

    // Check if PowerSense is enabled and configured
    let config = await Configuration.shared
    guard await config.isPowerSenseEnabled() else {
        throw PowerSenseZabbixError.powerSenseDisabled
    }

    guard await config.isPowerSenseConfigured() else {
        throw PowerSenseZabbixError.configurationMissing
    }

    logger.debug("Phase 2: Fetching device details for \(hostIds.count) host IDs")

    let resource = PowerSenseHostDetailsByIdsResource(hostIds: hostIds)
    let request = try await resource.request
    let (data, response) = try await URLSession.shared.data(for: request)

    // Log response details for debugging
    if let httpResponse = response as? HTTPURLResponse {
        logger.debug("PowerSense device details HTTP response: \(httpResponse.statusCode)")
        logger.debug("Response size: \(data.count) bytes")
    }

    // Parse JSON response - same logic as original fetchPowerSenseDevices
    let jsonObject: [String: Any]
    do {
        jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    } catch {
        logger.error("PowerSense device details JSON parsing failed: \(error)")
        throw PowerSenseZabbixError.invalidResponse("JSON parsing failed: \(error.localizedDescription)")
    }

    // Check for API error
    if let errorInfo = jsonObject["error"] as? [String: Any] {
        let errorCode = errorInfo["code"] as? Int ?? -1
        let errorMessage = errorInfo["message"] as? String ?? "Unknown error"
        let errorData = errorInfo["data"] as? String ?? ""
        let fullError = "Code: \(errorCode), Message: \(errorMessage), Data: \(errorData)"
        logger.error("PowerSense device details API error: \(fullError)")
        throw PowerSenseZabbixError.invalidResponse(fullError)
    }

    // Parse device results
    if let result = jsonObject["result"] as? [[String: Any]] {
        let jsonData = try JSONSerialization.data(withJSONObject: result)
        let devices = try JSONDecoder().decode([PowerSenseDeviceProperties].self, from: jsonData)
        logger.debug("Phase 2: Fetched details for \(devices.count) PowerSense devices")
        return devices.filter { $0.isValid }
    } else {
        logger.error("PowerSense device details result format invalid")
        throw PowerSenseZabbixError.invalidResponse("Result format invalid")
    }
}
