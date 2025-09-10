//
//  NetboxResource.swift
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

// MARK: Network Protocols
/// API resource protocol extension. Move to own file.
protocol NetboxResource {
    associatedtype ModelType: Codable
    var methodPath: String { get }
    var filterId: String? { get }
    var headers: [String: String]? { get }
    var body: Data? { get }
}

// Using an environmental variable set via Product > Scheme > Edit Scheme...

extension NetboxResource {
    var body: Data? { return nil }
    
    var request: URLRequest {
        get async {
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
                        
            // Check if we have a valid server URL configured
            guard !netboxApiServer.isEmpty,
                  let baseURL = URL(string: netboxApiServer) else {
                return URLRequest(url: URL(string: "https://invalid.local")!)
            }
            
                        // Use the original simple path construction
            let fullURL = baseURL.appendingPathComponent(methodPath.replacingOccurrences(of: "/?", with: "?"))
                        
            var request = URLRequest(url: fullURL)
            request.httpMethod = "GET"
            
            if let bodyData = body {
                request.httpBody = bodyData
                request.addValue("application/json", forHTTPHeaderField: "Content-Type")
                
                if let deviceResource = self as? DeviceResource {
                    request.httpMethod = deviceResource.isUpdate ? "PATCH" : "POST"
                }
            }
            
            print("Chosen request method: \(request.httpMethod ?? "No request")")
            
            let netboxApiKey = await Configuration.shared.getNetboxApiToken()
            if !netboxApiKey.isEmpty {
                print("\nAPI key found\n")
                request.addValue("Token \(netboxApiKey)", forHTTPHeaderField: "Authorization")
                if let filterId = filterId {
                    request.addValue("filterId=\(filterId)", forHTTPHeaderField: "None")
                }
                request.allHTTPHeaderFields = headers
                return request
            } else {
                print("\nAPI key not found or empty\n")
                return URLRequest(url: baseURL)
            }
        }
    }
}

// Create API Resource for TenantGroups
struct TenantGroupResource: NetboxResource {
    typealias ModelType = TenantGroupProperties
    
    var methodPath: String {
        return "/api/tenancy/tenant-groups/?limit=1000"
    }
    var filterId: String?
    var headers: [String: String]?
}

// API Resource for Tenant
struct TenantResource: NetboxResource {
    typealias ModelType = TenantProperties
    
    var methodPath: String {
        return "/api/tenancy/tenants/?&limit=1000"
    }
    var filterId: String?
    var headers: [String: String]?
    
}

// API Resource for Regions
struct RegionResource: NetboxResource {
    typealias ModelType = RegionProperties
    
    var methodPath: String {
        return "/api/dcim/regions/?limit=1000"
    }
    var filterId: String?
    var headers: [String: String]?
}

// API Resource for SiteGroups
struct SiteGroupResource: NetboxResource {
    typealias ModelType = SiteGroupProperties
    
    var methodPath: String {
        return "/api/dcim/site-groups/?limit=1000"
    }
    var filterId: String?
    var headers: [String: String]?
}

// API Resource for Sites
struct SiteResource: NetboxResource {
    typealias ModelType = SiteProperties
    var methodPath: String { return "/api/dcim/sites/?limit=1000" }
    var filterId: String?
    var headers: [String: String]?
    var body: Data?
    
    init(siteProperties: SiteProperties? = nil) {
        if let siteProperties = siteProperties {
            self.body = try? JSONEncoder().encode(siteProperties)
        } else {
            self.body = nil
        }
    }
}

struct DeviceResource: NetboxResource {
    typealias ModelType = DeviceProperties
    
    var methodPath: String
    var filterId: String?
    var headers: [String: String]?
    var body: Data?
    var isUpdate: Bool //The flag that determines the HTTP method
    
    // Initializer for fetching devices
    init(deviceProperties: DeviceProperties? = nil) {
        self.methodPath = "/api/dcim/devices/?manufacturer_id__n=5&role_id__n=29&role_id__n=30&limit=1000"
        self.isUpdate = false
        
        if let deviceProperties = deviceProperties {
            self.body = try? JSONEncoder().encode(deviceProperties)
        } else {
            self.body = nil
        }
    }
    
    // Initializer for updating an existing device
    init(deviceProperties: DeviceProperties, deviceId: Int64) {
        self.methodPath = "/api/dcim/devices/\(deviceId)/"
        self.body = try? JSONEncoder().encode(deviceProperties)
        self.isUpdate = true
    }
}

// API Resource for Static Devices (Blank Plate, Cable Management, Patch Panel)
struct StaticDeviceResource: NetboxResource {
    typealias ModelType = StaticDeviceProperties
    var siteId: Int64
    
    init(siteId: Int64) {
        self.siteId = siteId
    }
    
    var methodPath: String {
        return "/api/dcim/devices/?site_id=\(siteId)&role_id=6&role_id=7&role_id=18&role_id=27&limit=1000"
    }
    var filterId: String?
    var headers: [String: String]?
}

// API Resource for Device Bays
struct DeviceBayResource: NetboxResource {
    typealias ModelType = DeviceBayProperties
    var deviceId: Int64
    
    init(deviceId: Int64) {
        self.deviceId = deviceId
    }
    
    var methodPath: String {
        return "/api/dcim/device-bays/?device_id=\(deviceId)"
    }
    
    var filterId: String?
    var headers: [String: String]?
}


// API Resource for DeviceRole
struct DeviceRoleResource: NetboxResource {
    typealias ModelType = DeviceRoleProperties
    
    var methodPath: String {
        return "/api/dcim/device-roles/?id__n=29&id__n=30"
    }
    var filterId: String?
    var headers: [String: String]?
}

// API Resource for DeviceTypes
struct DeviceTypeResource: NetboxResource {
    typealias ModelType = DeviceTypeProperties
    
    var methodPath: String {
        return "/api/dcim/device-types/?manufacturer_id__n=5&limit=1000"
    }
    var filterId: String?
    var headers: [String: String]?
}

// API Resource for Interfaces
struct InterfaceResource: NetboxResource {
    typealias ModelType = InterfaceProperties
    
    var methodPath: String
    var filterId: String?
    var headers: [String: String]?
    var body: Data?
    var isUpdate: Bool //The flag that determines the HTTP method
    
    //Property to fetch interfaces by device ID
    var deviceId: Int64
    
    // Initializer for fetching interfaces
    init(deviceId: Int64, interfaceProperties: InterfaceProperties? = nil) {
        self.deviceId = deviceId
        self.methodPath = "/api/dcim/interfaces/?device_id=\(deviceId)&limit=1000"
        self.isUpdate = false
        
        if let interfaceProperties = interfaceProperties {
            self.body = try? JSONEncoder().encode(interfaceProperties)
        } else {
            self.body = nil
        }
    }
}

// API Resource for Cables
struct CableResource: NetboxResource {
    typealias ModelType = CableProperties
    
    var methodPath: String {
        return "/api/dcim/cables/?limit=1000"
    }
    var filterId: String?
    var headers: [String: String]?
    var body: Data?
    
    init(cableProperties: CableProperties? = nil) {
        if let cablePropertiesInstance = cableProperties {
            self.body = try? JSONEncoder().encode(cablePropertiesInstance)
        } else {
            self.body = nil
        }
    }
}

// API Resource for Racks
struct RackResource: NetboxResource {
    typealias ModelType = RackProperties
    
    var methodPath: String {
        return "/api/dcim/racks/?limit=1000"
    }
    var filterId: String?
    var headers: [String: String]?
}
