//
//  ZabbixResource.swift
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

// MARK: Network Protocols

/// Class to store the ZabbixAPI Session Token
final class ZabbixAPI: @unchecked Sendable {
    static let shared = ZabbixAPI()
    private let logger = Logger(subsystem: "zabbix", category: "zabbixAPI")
    
    // Use an actor to protect shared state
    private actor SessionState {
        private(set) var token: String?
        
        func setToken(_ newToken: String) {
            token = newToken
        }
        
        func getToken() -> String? {
            token
        }
    }
    
    private let sessionState = SessionState()
    
    private init() {
        logger.debug("Initializing ZabbixAPI singleton")
    }
    
    /// Retrieves the session token, either from cache or by fetching a new one
    /// - Returns: A valid session token
    /// - Throws: NSError if token retrieval fails
    func getSessionToken() async throws -> String {
        let startTime = Date()
        
        // Check current token first
        if let token = await sessionState.getToken() {
            logger.debug("Using cached session token")
            return token
        }
        
        logger.debug("No cached token found, fetching new session token")
        
        // Fetch new token
        let userLoginResource = UserLoginResource(
            username: await Configuration.shared.getZabbixApiUser(),
            password: await Configuration.shared.getZabbixApiToken()
        )
        
        let requestStartTime = Date()
        let urlRequest = try await userLoginResource.request
        logger.debug("Request generation took: \(Date().timeIntervalSince(requestStartTime))s")
        
        let networkStartTime = Date()
        let (data, _) = try await URLSession.shared.data(for: urlRequest)
        logger.debug("Network request took: \(Date().timeIntervalSince(networkStartTime))s")
        
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        
        if let result = jsonObject?["result"] as? String {
            await sessionState.setToken(result)
            logger.debug("Successfully retrieved and cached new session token")
            logger.debug("Total token retrieval took: \(Date().timeIntervalSince(startTime))s")
            return result
        } else {
            let errorDescription = jsonObject?["error"] as? String ?? "Unknown error"
            logger.error("Failed to retrieve session token: \(errorDescription)")
            throw NSError(domain: "InvalidResult", code: -1, userInfo: [NSLocalizedDescriptionKey: errorDescription])
        }
    }
}

// MARK: - ZabbixResource Protocol Extension
extension ZabbixResource {
    var request: URLRequest {
        get async throws {
            let logger = Logger(subsystem: "zabbix", category: "zabbixResource")
            let startTime = Date()
            
            // Get base URL from configuration
            let zabbixServer = await Configuration.shared.getZabbixApiServer()
            guard !zabbixServer.isEmpty,
                  let url = URL(string: zabbixServer)?.appendingPathComponent("zabbix/api_jsonrpc.php") else {
                logger.error("Zabbix server URL not configured or invalid")
                throw ZabbixError.invalidRequest
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json-rpc", forHTTPHeaderField: "Content-Type")
            
            // Prepare request data
            var requestData: [String: Any] = [
                "jsonrpc": "2.0",
                "method": method,
                "params": params ?? [:],
                "id": 1
            ]
            
            // Only fetch auth token if needed
            if method != "user.login" {
                let tokenStartTime = Date()
                requestData["auth"] = try await ZabbixAPI.shared.getSessionToken()
                logger.debug("Token retrieval took: \(Date().timeIntervalSince(tokenStartTime))s")
            }
            
            // Serialize request data
            let serializationStartTime = Date()
            request.httpBody = try JSONSerialization.data(withJSONObject: requestData)
            logger.debug("Request serialization took: \(Date().timeIntervalSince(serializationStartTime))s")
            
            if let headers = headers {
                request.allHTTPHeaderFields = headers
            }
            
            logger.debug("Total request generation took: \(Date().timeIntervalSince(startTime))s")
            return request
        }
    }
}


/// API resource protocol extension. Move to own file.
protocol ZabbixResource {
    associatedtype ModelType: Decodable
    var methodPath: String { get }
    var method: String { get }
    var params: [String: Any]? { get }
    var headers: [String: String]? { get }
}

enum ZabbixError: Error {
    case invalidRequest
    case invalidResponse(String)
    case authenticationFailed
    case sessionExpired
    case missingParameters(String)
    
    var localizedDescription: String {
        switch self {
        case .invalidRequest: return "Invalid request configuration"
        case .invalidResponse(let message): return "Invalid response: \(message)"
        case .authenticationFailed: return "Authentication failed"
        case .sessionExpired: return "Session expired"
        case .missingParameters(let params): return "Missing required parameters: \(params)"
        }
    }
}

struct UserLoginResource: ZabbixResource {
    typealias ModelType = String
    
    let method = "user.login"
    let methodPath = ""
    
    let username: String
    let password: String
    var params: [String: Any]? {
        return [
            "username": username,
            "password": password
        ]
    }
    
    var headers: [String : String]?
}


struct RetrieveHostEventsResource: ZabbixResource {
    typealias ModelType = EventProperties
    let logger = Logger(subsystem: "zabbix", category: "apiResource")
    
    var methodPath: String
    let method = "event.get"
    let hostIds: [String]?
    let eventIds: [String]?
    
    init(methodPath: String, hostIds: [String]? = nil, eventIds: [String]? = nil) {
        self.methodPath = methodPath
        self.hostIds = hostIds
        self.eventIds = eventIds
    }
    
    var params: [String: Any]? {
        var parameters: [String: Any] = [
            "output": "extend",
            "selectHosts": ["hostid"],
        ]
        
        if let hostIds = hostIds, !hostIds.isEmpty {
            parameters["hostids"] = hostIds
            
            // Only add time window for host-based queries
            let currentTime = Int(Date().timeIntervalSince1970)
            let problemTimeWindow = UserDefaults.getProblemTimeWindow()
            parameters["problem_time_from"] = currentTime - problemTimeWindow
            parameters["problem_time_till"] = currentTime
        }
        
        if let eventIds = eventIds, !eventIds.isEmpty {
            parameters["eventids"] = eventIds
        }
        
        
        logger.debug("""
            Generated parameters for event.get:
            \(parameters.map { "- \($0.key): \(String(describing: $0.value))" }.joined(separator: "\n"))
            """)
        
        return parameters
    }
    
    var headers: [String: String]? = nil
}

struct RetrieveHostProblemsResource: ZabbixResource {
    typealias ModelType = EventProperties
    
    var methodPath: String
    let method = "problem.get"
    let hostIds: [String]?
    let eventIds: [String]?
    
    init(methodPath: String, hostIds: [String]? = nil, eventIds: [String]? = nil) {
        self.methodPath = methodPath
        self.hostIds = hostIds
        self.eventIds = eventIds
    }
    
    var params: [String: Any]? {
        var parameters: [String: Any] = [
            "output": "extend",
            "sortfield": ["eventid"],
            "sortorder": "DESC",
            "recent": true
        ]
        
        if let hostIds = hostIds, !hostIds.isEmpty {
            parameters["hostids"] = hostIds
        }
        
        if let eventIds = eventIds, !eventIds.isEmpty {
            parameters["eventids"] = eventIds
        }
        
        return parameters
    }
    
    var headers: [String: String]? = nil
}

//MARK: Retrieving Item data
// Struct for retrieving Item data
struct RetrieveItemResource: ZabbixResource {
    typealias ModelType = ItemProperties
    
    var methodPath: String
    let method = "item.get"
    
    let hostId: Int64
    var params: [String: Any]? {
        return [
            "output": ["itemid", "name", "history", "trends", "status", "units", "templateid", "value_type", "description", "tags"],
            "hostids": String(hostId),
            "selectTags": "extend",
            "sortfield": ["itemid"],
            "sortorder": "DESC"
        ]
    }
    
    var headers: [String : String]?
}

//MARK: Retrieving History data
struct RetrieveHistoryResource: ZabbixResource {
    typealias ModelType = HistoryProperties
    
    var methodPath: String
    let method = "history.get"
    
    let itemId: String
    let timeFrom: Date?
    let timeTill: Date?
    
    let valueType: Int

    var params: [String: Any]? {
        var parameters: [String: Any] = [
            "output": ["itemid", "clock", "value"],
            "history": valueType,
            "itemids": itemId,
            "sortfield": ["clock"],
            "sortorder": "DESC",
            "limit": 100000
        ]
        
        if let timeFrom = timeFrom {
            parameters["time_from"] = Int(timeFrom.timeIntervalSince1970)
        }
        
        if let timeTill = timeTill {
            parameters["time_till"] = Int(timeTill.timeIntervalSince1970)
        }
        
        return parameters
    }
    
    var headers: [String: String]?
}

//MARK: Retrieving Event data
func fetchHostEvents(hostIds: [String]? = nil, eventIds: [String]? = nil) async throws -> [EventProperties] {
    let logger = Logger(subsystem: "zabbix", category: "zabbixFetch")
    
    logger.debug("Fetching events: hostIds=\(hostIds?.description ?? "nil"), eventIds=\(eventIds?.description ?? "nil")")
    
    let resource = RetrieveHostEventsResource(
        methodPath: "",
        hostIds: hostIds,
        eventIds: eventIds
    )
    
    let request = try await resource.request
    let (data, _) = try await URLSession.shared.data(for: request)
    
    let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let result = jsonObject?["result"] as? [[String: Any]] {
        let jsonData = try JSONSerialization.data(withJSONObject: result)
        let events = try JSONDecoder().decode([EventProperties].self, from: jsonData)
        logger.debug("Successfully fetched \(events.count) events")
        return events
    } else {
        let errorDescription = jsonObject?["error"] as? String ?? "Unknown error"
        logger.error("Error fetching events: \(errorDescription)")
        throw ZabbixError.invalidResponse(errorDescription)
    }
}

func fetchHostProblems(hostIds: [String]? = nil, eventIds: [String]? = nil) async throws -> [EventProperties] {
    let logger = Logger(subsystem: "zabbix", category: "zabbixFetch")
    
    guard hostIds != nil || eventIds != nil else {
        logger.error("Missing parameters: either hostIds or eventIds must be provided")
        throw ZabbixError.missingParameters("Either hostIds or eventIds must be provided")
    }
    
    let resource = RetrieveHostProblemsResource(
        methodPath: "",
        hostIds: hostIds,
        eventIds: eventIds
    )
    
    let request = try await resource.request
    let (data, _) = try await URLSession.shared.data(for: request)
    
    let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let result = jsonObject?["result"] as? [[String: Any]] {
        let jsonData = try JSONSerialization.data(withJSONObject: result)
        let problems = try JSONDecoder().decode([EventProperties].self, from: jsonData)
        logger.debug("Successfully fetched \(problems.count) problems")
        return problems
    } else {
        let errorDescription = jsonObject?["error"] as? String ?? "Unknown error"
        logger.error("Error fetching problems: \(errorDescription)")
        throw ZabbixError.invalidResponse(errorDescription)
    }
}

func updateHostEvents(params: UpdateParameters) async throws {
    let logger = Logger(subsystem: "zabbix", category: "zabbixFetch")
    
    logger.debug("Updating events: \(params.eventIds)")
    
    let jsonBody: [String: Any] = [
        "eventids": params.eventIds,
        "action": params.action,
        "message": params.message as Any,
        "severity": params.severity as Any,
        "suppress_until": params.suppressUntil as Any
    ]
    
    let resource = EventAcknowledgeResource(params: jsonBody)
    let request = try await resource.request
    let (data, _) = try await URLSession.shared.data(for: request)
    
    if let responseString = String(data: data, encoding: .utf8) {
        logger.debug("Update successful. Response: \(responseString)")
    }
}


// Function to fetch Items
func fetchItems(hostId: Int64) async throws -> [ItemProperties] {
    let logger = Logger(subsystem: "zabbix", category: "zabbixFetch")
    
    logger.debug("Fetching items for host: \(hostId)")
    
    let resource = RetrieveItemResource(methodPath: "", hostId: hostId)
    let request = try await resource.request
    let (data, _) = try await URLSession.shared.data(for: request)
    
    let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let result = jsonObject?["result"] as? [[String: Any]] {
        let jsonData = try JSONSerialization.data(withJSONObject: result)
        let items = try JSONDecoder().decode([ItemProperties].self, from: jsonData)
        logger.debug("Successfully fetched \(items.count) items")
        return items
    } else {
        let errorDescription = jsonObject?["error"] as? String ?? "Unknown error"
        logger.error("Error fetching items: \(errorDescription)")
        throw ZabbixError.invalidResponse(errorDescription)
    }
}

// Function to fetch Histories
func fetchHistories(itemId: String, timeFrom: Date? = nil, timeTill: Date? = nil, valueType: Int) async throws -> [HistoryProperties] {
    let logger = Logger(subsystem: "zabbix", category: "zabbixFetch")
    
    logger.debug("""
        Fetching histories:
        - itemId: \(itemId)
        - timeFrom: \(timeFrom?.description ?? "nil")
        - timeTill: \(timeTill?.description ?? "nil")
        - valueType: \(valueType)
        """)
    
    let resource = RetrieveHistoryResource(
        methodPath: "",
        itemId: itemId,
        timeFrom: timeFrom,
        timeTill: timeTill,
        valueType: valueType
    )
    
    let request = try await resource.request
    let (data, _) = try await URLSession.shared.data(for: request)
    
    let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let result = jsonObject?["result"] as? [[String: Any]] {
        let jsonData = try JSONSerialization.data(withJSONObject: result)
        let histories = try JSONDecoder().decode([HistoryProperties].self, from: jsonData)
        logger.debug("Successfully fetched \(histories.count) history entries")
        return histories
    } else {
        let errorDescription = jsonObject?["error"] as? String ?? "Unknown error"
        logger.error("Error fetching histories: \(errorDescription)")
        throw ZabbixError.invalidResponse(errorDescription)
    }
}

// MARK: Consolidate to single URL Resource

// Struct for acknowledging events
struct EventAcknowledgeResource: ZabbixResource {
    var params: [String : Any]?
    
    typealias ModelType = String

    let method = "event.acknowledge"
    let methodPath = ""

    var headers: [String : String]?
}

