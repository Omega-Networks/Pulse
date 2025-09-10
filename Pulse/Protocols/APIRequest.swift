//
//  APIRequest.swift
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

/// JSON Decoder for Response outer wrapper
struct Wrapper<T: Decodable>: Decodable {
    let results: [T]
    let next: String?
    // keep on fetching data until    "next": null,
}

/// Network request protocol and extension
protocol NetworkRequest: AnyObject {
    associatedtype ModelType
    func decode(_ data: Data) -> ModelType?
    func execute(withCompletion completion: @escaping (ModelType?) -> Void)
}

extension NetworkRequest {
    fileprivate func load(_ request: URLRequest) async throws -> ModelType? {
        let (data, _) = try await URLSession.shared.data(for: request)
        return decode(data)
    }
}

/// API Request Class to make requestions using API Resources and Network Requests Protocols
class APIRequest<Resource: NetboxResource> {
    let resource: Resource
    let apiKey: String
    let baseURL: String
    
    init(resource: Resource, apiKey: String, baseURL: String) {
        self.resource = resource
        self.apiKey = apiKey
        self.baseURL = baseURL
    }
}

extension APIRequest {
    func decode(_ data: Data) -> [Resource.ModelType]? {
        let decoder = JSONDecoder()
        let wrapper = try? decoder.decode(Wrapper<Resource.ModelType>.self, from: data)
        return wrapper?.results
    }
    
    fileprivate func load(_ request: URLRequest) async throws -> Wrapper<Resource.ModelType>? {
        print("Request Body: \(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try await decodeWrapper(data, response: response)
    }
    
    private func decodeWrapper(_ data: Data, response: URLResponse) async throws -> Wrapper<Resource.ModelType>? {
        guard let httpResponse = response as? HTTPURLResponse else {
            print("Invalid response type")
            throw NetboxRequestError.networkError(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response type"]))
        }
        
        let statusCode = httpResponse.statusCode
        let statusMessage = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        
        print("HTTP Status Code: \(statusCode)")
        print("HTTP Status Message: \(statusMessage)")
        
        if !(200...299).contains(statusCode) {
            throw NetboxRequestError.failure(code: statusCode, message: statusMessage)
        }
        
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        
        decoder.dateDecodingStrategy = .custom({ (decoder) -> Date in
            let container = try decoder.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = formatter.date(from: dateStr) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateStr)")
        })
        
        // Try decoding as a wrapper first
        do {
            if let wrapper = try? decoder.decode(Wrapper<Resource.ModelType>.self, from: data) {
                return wrapper
            }
            
            // If wrapper decoding fails, try decoding as a single object
            if let singleObject = try? decoder.decode(Resource.ModelType.self, from: data) {
                return Wrapper(results: [singleObject], next: nil)
            }
            
            // If both decoding attempts fail, throw decoding error
            throw NetboxRequestError.decodingError
        } catch {
            print("Decoding error: \(error)")
            throw NetboxRequestError.decodingError
        }
    }
    
    func execute() async throws -> [Resource.ModelType] {
        let fullURLString = baseURL + resource.methodPath
        guard let url = URL(string: fullURLString) else {
            throw URLError(.badURL)
        }
        
        var request = await resource.request
        request.url = url
        
        // Add print statement to verify the URL
        print("APIRequest URL: \(request.url?.absoluteString ?? "Unknown URL")")
        
        return try await fetchAllPages(request, accumulatedResults: [])
    }
    
    private func fetchAllPages(_ request: URLRequest, accumulatedResults: [Resource.ModelType]) async throws -> [Resource.ModelType] {
        let wrapper = try await load(request)
        if let results = wrapper?.results {
            let combinedResults = accumulatedResults + results
            
            if let nextURLString = wrapper?.next, let nextPageURL = URL(string: nextURLString) {
                var nextPageRequest = URLRequest(url: nextPageURL)
                nextPageRequest.allHTTPHeaderFields = await self.resource.request.allHTTPHeaderFields
                return try await fetchAllPages(nextPageRequest, accumulatedResults: combinedResults)
            } else {
                print("Total count of Resource.ModelType collected during getRequest: \(combinedResults.count)")
                return combinedResults
            }
        } else {
            return []
        }
    }
}

//MARK: - Enum for presenting HTTP code and message to the user
enum NetboxRequestError: Error {
    case success(code: Int, message: String)
    case failure(code: Int, message: String)
    case networkError(Error)
    case decodingError
    
    var statusCode: Int {
        switch self {
        case .success(let code, _), .failure(let code, _):
            return code
        default:
            return 0
        }
    }
    
    var message: String {
        switch self {
        case .success(_, let message), .failure(_, let message):
            return message
        case .networkError(let error):
            return error.localizedDescription
        case .decodingError:
            return "Failed to decode response"
        }
    }
}
