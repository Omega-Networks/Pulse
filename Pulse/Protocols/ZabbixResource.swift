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

        func setToken(_ newToken: String?) {
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
    
    /// Credential for the configured auth mode. API-token mode returns the
    /// stored token (no login). Legacy mode returns a `user.login` session.
    func credential(for mode: ZabbixAuthMode) async throws -> String {
        switch mode {
        case .apiToken:
            let token = await Configuration.shared.getZabbixApiToken()
            guard !token.isEmpty else { throw ZabbixError.authenticationFailed }
            return token
        case .legacy:
            return try await getSessionToken()
        }
    }

    func clearSession() async {
        await sessionState.setToken(nil)
    }

    /// Retrieves a legacy JSON-RPC session via `user.login`.
    func getSessionToken() async throws -> String {
        if let token = await sessionState.getToken() {
            logger.debug("Using cached session token")
            return token
        }

        let username = await Configuration.shared.getZabbixApiUser()
        let password = await Configuration.shared.getZabbixApiToken()
        guard !username.isEmpty, !password.isEmpty else {
            throw ZabbixError.authenticationFailed
        }

        let userLoginResource = UserLoginResource(username: username, password: password)
        let urlRequest = try await userLoginResource.request
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw ZabbixError.fromTransport(error)
        }

        let jsonObject = try zabbixJSONObject(from: data)
        if let result = jsonObject["result"] as? String, !result.isEmpty {
            await sessionState.setToken(result)
            return result
        }
        throw ZabbixError.fromRPC(jsonObject)
    }
}

// MARK: - ZabbixResource Protocol Extension

/// API resource protocol extension. Move to own file.
protocol ZabbixResource {
    associatedtype ModelType: Decodable
    var methodPath: String { get }
    var method: String { get }
    var params: [String: Any]? { get }
    var headers: [String: String]? { get }
}

extension ZabbixResource {
    var request: URLRequest {
        get async throws {
            let logger = Logger(subsystem: "zabbix", category: "zabbixResource")
            let startTime = Date()
            
            // Get base URL from configuration
            let zabbixServer = await Configuration.shared.getZabbixApiServer()
            guard !zabbixServer.isEmpty else {
                logger.error("Zabbix server URL not configured or invalid")
                throw ZabbixError.invalidRequest
            }
            let endpoint = try ZabbixServerURL.jsonRPCEndpoint(zabbixServer)

            let mode = await Configuration.shared.getZabbixAuthMode()
            var applied = ZabbixJSONRPC.AppliedAuth(bodyAuth: nil, bearerHeader: nil)
            if ZabbixJSONRPC.methodNeedsAuth(method) {
                let credential = try await ZabbixAPI.shared.credential(for: mode)
                applied = ZabbixJSONRPC.appliedAuth(
                    mode: mode, method: method, credential: credential
                )
            }

            let request = try ZabbixJSONRPC.urlRequest(
                endpoint: endpoint,
                method: method,
                params: params ?? [:],
                applied: applied,
                extraHeaders: headers
            )
            
            logger.debug("Total request generation took: \(Date().timeIntervalSince(startTime))s")
            return request
        }
    }
}

/// Empty or non-JSON bodies mean the server did not answer JSON-RPC
/// (down, reset, HTML error page). Do not surface Cocoa's
/// "isn't in the correct format".
func zabbixJSONObject(from data: Data) throws -> [String: Any] {
    guard !data.isEmpty else {
        throw ZabbixError.unreachable
    }
    do {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ZabbixError.unreachable
        }
        return object
    } catch is ZabbixError {
        throw ZabbixError.unreachable
    } catch {
        throw ZabbixError.unreachable
    }
}

enum ZabbixError: Error, LocalizedError, Equatable {
    case invalidRequest
    case invalidServerURL(String)
    case invalidResponse(String)
    case authenticationFailed
    case sessionExpired
    case missingParameters(String)
    case unreachable

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Zabbix is not configured."
        case .invalidServerURL: return "Zabbix server URL must be https with a host and no userinfo."
        case .invalidResponse(let message): return "Zabbix returned an error: \(message)"
        case .authenticationFailed: return "Zabbix authentication failed. Check the API user and token in Settings."
        case .sessionExpired: return "The Zabbix session expired."
        case .missingParameters(let params): return "Missing required parameters: \(params)"
        case .unreachable: return "Zabbix is unreachable. Check that the server is up and reachable from this Mac."
        }
    }

    static func fromTransport(_ error: Error) -> ZabbixError {
        if let zabbix = error as? ZabbixError { return zabbix }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return .unreachable }
        if ns.domain == NSCocoaErrorDomain && ns.code == 3840 { return .unreachable }
        return .invalidResponse(error.localizedDescription)
    }

    static func status(from error: Error) -> RequestStatusManager.RequestStatus {
        let zabbix = fromTransport(error)
        switch zabbix {
        case .unreachable, .invalidRequest, .invalidServerURL:
            return .connectionError(zabbix.localizedDescription)
        case .authenticationFailed, .sessionExpired:
            return .authenticationFailure(code: 401, message: zabbix.localizedDescription)
        case .invalidResponse, .missingParameters:
            return .dataError(code: 0, message: zabbix.localizedDescription)
        }
    }

    static func fromRPC(_ object: [String: Any]) -> ZabbixError {
        let description = ZabbixJSONRPC.errorDescription(from: object)
        if ZabbixJSONRPC.looksLikeRejectedBodyAuth(description) {
            return .invalidResponse(
                "Zabbix 7.2+ rejected body auth. Use API token authentication (default) in Settings."
            )
        }
        if ZabbixJSONRPC.looksLikeUnauthorized(description) {
            return .authenticationFailed
        }
        return .invalidResponse(description)
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
func fetchHostEvents(hostIds: [String]? = nil, eventIds: [String]? = nil) async throws -> ZabbixJSONRPC.DecodedList<EventProperties> {
    let logger = Logger(subsystem: "zabbix", category: "zabbixFetch")
    
    logger.debug("Fetching events: hostIds=\(hostIds?.description ?? "nil"), eventIds=\(eventIds?.description ?? "nil")")
    
    let resource = RetrieveHostEventsResource(
        methodPath: "",
        hostIds: hostIds,
        eventIds: eventIds
    )
    
    let request = try await resource.request
    let data: Data
    do {
        (data, _) = try await URLSession.shared.data(for: request)
    } catch {
        throw ZabbixError.fromTransport(error)
    }
    
    let jsonObject = try zabbixJSONObject(from: data)
    let decoded = try ZabbixJSONRPC.decodeElements(EventProperties.self, from: jsonObject)
    logger.debug("Successfully fetched \(decoded.items.count) events skipped=\(decoded.skipped)")
    return decoded
}

func fetchHostProblems(hostIds: [String]? = nil, eventIds: [String]? = nil) async throws -> ZabbixJSONRPC.DecodedList<EventProperties> {
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
    let data: Data
    do {
        (data, _) = try await URLSession.shared.data(for: request)
    } catch {
        throw ZabbixError.fromTransport(error)
    }
    
    let jsonObject = try zabbixJSONObject(from: data)
    let decoded = try ZabbixJSONRPC.decodeElements(EventProperties.self, from: jsonObject)
    logger.debug("Successfully fetched \(decoded.items.count) problems skipped=\(decoded.skipped)")
    return decoded
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
    let data: Data
    do {
        (data, _) = try await URLSession.shared.data(for: request)
    } catch {
        throw ZabbixError.fromTransport(error)
    }
    let jsonObject = try zabbixJSONObject(from: data)
    guard jsonObject["result"] != nil else {
        throw ZabbixError.fromRPC(jsonObject)
    }
    logger.debug("event.acknowledge accepted for \(params.eventIds.count) events")
}


// Function to fetch Items
func fetchItems(hostId: Int64) async throws -> [ItemProperties] {
    let logger = Logger(subsystem: "zabbix", category: "zabbixFetch")
    
    logger.debug("Fetching items for host: \(hostId)")
    
    let resource = RetrieveItemResource(methodPath: "", hostId: hostId)
    let request = try await resource.request
    let data: Data
    do {
        (data, _) = try await URLSession.shared.data(for: request)
    } catch {
        throw ZabbixError.fromTransport(error)
    }
    
    let jsonObject = try zabbixJSONObject(from: data)
    let decoded = try ZabbixJSONRPC.decodeElements(ItemProperties.self, from: jsonObject)
    logger.debug("Successfully fetched \(decoded.items.count) items skipped=\(decoded.skipped)")
    return decoded.items
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
    
    let jsonObject = try zabbixJSONObject(from: data)
    let decoded = try ZabbixJSONRPC.decodeElements(HistoryProperties.self, from: jsonObject)
    logger.debug("Successfully fetched \(decoded.items.count) history entries skipped=\(decoded.skipped)")
    return decoded.items
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

