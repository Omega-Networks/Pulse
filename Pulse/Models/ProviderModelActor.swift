//
//  ProviderModelActor.swift
//  PulseSync
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
import SwiftData
import Dispatch
import OSLog

// Protocols and extensions go here
protocol PropertiesType {
}
extension SiteGroupProperties: PropertiesType {}
extension SiteProperties: PropertiesType {}
extension DeviceProperties: PropertiesType {}
extension EventProperties: PropertiesType {}
//extension CableProperties: PropertiesType {}
extension DeviceRoleProperties: PropertiesType {}
extension DeviceTypeProperties: PropertiesType {}


actor ProviderModelActor {
    @Published private(set) var isLoadingZabbixEvents = false
    @Published private(set) var isLoadingZabbixItems = false
    @Published private(set) var isLoadingZabbixHistories = false
    
    
    var enableMonitoring = false
    
    var modelContainer: ModelContainer
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }
    

    
    // MARK: - Helper functions
    
    func updateEvents(params: UpdateParameters, eventIds: [String]) async {
        let logger = Logger(subsystem: "zabbix", category: "eventUpdate")
        
        logger.debug("Running updateEvents with eventIds: \(eventIds)")
        do {
            try await updateHostEvents(params: params)
            
            // After successful update, refresh events for affected events
            logger.debug("Fetching updated events")
            let service = SiteDataService(modelContainer: modelContainer)
            await service.getProblems(using: eventIds)
            
        } catch {
            logger.error("Failed to update events: \(error.localizedDescription)")
        }
    }
    
    // TODO: Obtain and store most recent Object Change id "/api/extras/object-changes/" and check for changes prior to getting updates from Netbox
    
    /**
     Fetch and process tenantGroup properties.
     
     This function fetches and processes tenantGroup properties, updating existing tenantGroups and inserting new ones as necessary.
     It then deletes any remaining tenantGroupa that were not in the fetched tenantGroup properties.
     
     - Parameter tenantGroupProperties: An optional array of `tenantGroupProperties` to be processed. If `nil`, the function will fetch the tenantGroup properties by executing a tenantGroup API request.
     */
    func getTenantGroups(tenantGroupProperties: [TenantGroupProperties]? = nil) async throws {
        let modelContext = ModelContext(modelContainer)
        
        var tenantGroupPropertiesList: [TenantGroupProperties] = []
        
        var deleteOld = false
        
        // If tenantGroupPropertiesList is nil, execute tenantGroup request to populate it.
        if let tenantGroupProperties = tenantGroupProperties {
            print("tenantGroupProperties IF")
            tenantGroupPropertiesList = tenantGroupProperties
        } else {
            print("tenantGroupProperties ELSE")
            // Initialize resource and request objects.
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
            let netboxApiToken = await Configuration.shared.getNetboxApiToken()
            
            let resource = TenantGroupResource()
            let tenantGroupRequest = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
            // Execute tenantGroup API request.
            do {
                tenantGroupPropertiesList = try await tenantGroupRequest.execute()
            } catch {
                // TODO: Advise user of errors
                print("Error executing tenantGroup request: \(error)")
                throw error
            }
            deleteOld = true
        }
        
        // Initialize a dictionary to hold tenantGroup categorized as insert or delete.
        var existingTenantGroupMap: [Int64: TenantGroup] = [:]
        
        
        if deleteOld {
            // Fetch existing tenantGroups.
            let descriptor = FetchDescriptor<TenantGroup>()
            if let existingTenantGroups = try? modelContext.fetch(descriptor) {
                // Map existing deviceRole by their IDs
                for tenantGroup in existingTenantGroups {
                    existingTenantGroupMap[tenantGroup.id] = tenantGroup
                }
            }
        }
        
        do {
            for tenantGroupProperty in tenantGroupPropertiesList {
                
                print("tenantGroupProperty: \(tenantGroupProperty.name)")
                // Determine if <tenantGroup> already exists and remove from deletion queue
                let tenantGroupExists: Bool = existingTenantGroupMap.keys.contains(tenantGroupProperty.id)
                print("tenantGroupExists: \(tenantGroupExists)")
                let tenantGroupOptional = tenantGroupExists ? existingTenantGroupMap.removeValue(forKey: tenantGroupProperty.id) : TenantGroup(id: tenantGroupProperty.id)
                
                // Using optional binding to safely unwrap the tenantGroup
                if let tenantGroup = tenantGroupOptional {
                    // Check if lastUpdated values are equal
                    if tenantGroup.lastUpdated != tenantGroupProperty.lastUpdated {
                        tenantGroup.name = tenantGroupProperty.name
                        tenantGroup.created = tenantGroupProperty.created
                        tenantGroup.lastUpdated = tenantGroupProperty.lastUpdated
                    }
                    tenantGroup.name = tenantGroupProperty.name
                    tenantGroup.created = tenantGroupProperty.created
                    tenantGroup.lastUpdated = tenantGroupProperty.lastUpdated
                    
                    // If tenantGroup does not exist, insert it into the model context
                    if !tenantGroupExists {
                        print("Inserting \(tenantGroupProperty.name) into swiftData")
                        modelContext.insert(tenantGroup)
                    }
                }
            }
        }
        
        // Delete legacy tenantGroups after processing all tenantGroupProperties
        for remainingTenantGroup in existingTenantGroupMap.values {
            print("Deleting tenantGroup: \(remainingTenantGroup.name ?? "Unknown")")
            modelContext.delete(remainingTenantGroup)
        }
        
        // Save the context to commit the changes
        do {
            print("Attempting to save swiftData")
            try modelContext.save()
        } catch {
            print("Error saving context after deleting tenantGroups: \(error)")
        }
        
        print ("Completed getTenantGroup function")
    }
    
    /**
     Fetch and process tenant properties.
     
     This function fetches and processes tenant properties, updating existing tenant and inserting new ones as necessary.
     It then deletes any remaining tenant that were not in the fetched tenant properties.
     
     - Parameter tenantProperties: An optional array of `tenantProperties` to be processed. If `nil`, the function will fetch the region properties by executing a tenant API request.
     */
    func getTenants(tenantProperties: [TenantProperties]? = nil) async throws {
        let modelContext = ModelContext(modelContainer)
        
        var tenantPropertiesList: [TenantProperties] = []
        
        var deleteOld = false
        
        // If tenantPropertiesList is nil, execute tenant request to populate it.
        if let tenantProperties = tenantProperties {
            tenantPropertiesList = tenantProperties
        } else {
            // Initialize resource and request objects.
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
            let netboxApiToken = await Configuration.shared.getNetboxApiToken()
            
            let resource = TenantResource()
            let tenantRequest = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
            // Execute device API request.
            do {
                tenantPropertiesList = try await tenantRequest.execute()
            } catch {
                // TODO: Advise user of errors
                print("Error executing tenant request: \(error)")
                throw error
            }
            deleteOld = true
        }
        
        // Initialize a dictionary to hold tenants categorized as insert or delete.
        var existingTenantMap: [Int64: Tenant] = [:]
        
        if deleteOld {
            // Fetch existing tenants.
            let descriptor = FetchDescriptor<Tenant>()
            if let existingTenants = try? modelContext.fetch(descriptor) {
                // Map existing tenants by their IDs
                for tenant in existingTenants {
                    existingTenantMap[tenant.id] = tenant
                }
            }
        }
        
        do {
            for tenantProperty in tenantPropertiesList {
                
                print("tenantProperty: \(tenantProperty.name)")
                // Determine if <Tenant> already exists and remove from deletion queue
                let tenantExists: Bool = existingTenantMap.keys.contains(tenantProperty.id)
                print("tenantExists: \(tenantExists)")
                let tenantOptional = tenantExists ? existingTenantMap.removeValue(forKey: tenantProperty.id) : Tenant(id: tenantProperty.id)
                
                // Using optional binding to safely unwrap the tenant
                if let tenant = tenantOptional {
                    // Check if lastUpdated values are equal
                    if tenant.lastUpdated != tenantProperty.lastUpdated {
                        tenant.name = tenantProperty.name
                        tenant.created = tenantProperty.created
                        tenant.lastUpdated = tenantProperty.lastUpdated
                        if tenantProperty.groupId != 0 {
                            print("Establishing relationship with Tenant Group")
                            let groupId = tenantProperty.groupId ?? 0
                            
                            let predicate = #Predicate<TenantGroup> { tenantGroup in
                                tenantGroup.id == groupId
                            }
                            
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let tenantGroup = try? modelContext.fetch(fetchDescriptor).first {
                                tenant.group = tenantGroup
                            }
                        }
                    } else {
                        tenant.name = tenantProperty.name
                        tenant.created = tenantProperty.created
                        tenant.lastUpdated = tenantProperty.lastUpdated
                        
                        // If tenant does not exist, insert it into the model context
                        if !tenantExists {
                            print("Inserting \(tenantProperty.name) into swiftData")
                            modelContext.insert(tenant)
                        }
                        
                        // TODO: Refactor mapping of relationships
                        // Establishing relationship with Tenant Group
                        if tenantProperty.groupId != 0 {
                            print("Establishing relationship with Tenant Group")
                            let groupId = tenantProperty.groupId ?? 0
                            
                            let predicate = #Predicate<TenantGroup> { tenantGroup in
                                tenantGroup.id == groupId
                            }
                            
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let tenantGroup = try? modelContext.fetch(fetchDescriptor).first {
                                tenant.group = tenantGroup
                            }
                        }
                    }
                }
            }
        }
        
        // Delete legacy tenants after processing all tenantProperties
        for remainingTenant in existingTenantMap.values {
            
            print("Deleting tenant: \(remainingTenant.name)")
            modelContext.delete(remainingTenant)
        }
        
        // Save the context to commit the changes
        do {
            print("Attempting to save swiftData")
            try modelContext.save()
        } catch {
            print("Error saving context after deleting tenants: \(error)")
        }
        print ("Completed getTenants function")
    }
    
    /**
     Fetch and process region properties.
     
     This function fetches and processes region properties, updating existing region and inserting new ones as necessary.
     It then deletes any remaining region that were not in the fetched region properties.
     
     - Parameter regionProperties: An optional array of `regionProperties` to be processed. If `nil`, the function will fetch the region properties by executing a deviceRole API request.
     */
    func getRegions(regionProperties: [RegionProperties]? = nil) async throws {
        let modelContext = ModelContext(modelContainer)
        
        var regionPropertiesList: [RegionProperties] = []
        
        var deleteOld = false
        
        // If regionPropertiesList is nil, execute regionRole request to populate it.
        if let regionProperties = regionProperties {
            regionPropertiesList = regionProperties
        } else {
            // Initialize resource and request objects.
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
            let netboxApiToken = await Configuration.shared.getNetboxApiToken()
            
            let resource = RegionResource()
            let regionRequest = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
            // Execute region API request.
            do {
                regionPropertiesList = try await regionRequest.execute()
            } catch {
                // TODO: Advise user of errors
                print("Error executing site request: \(error)")
                throw error
            }
            deleteOld = true
        }
        
        // Initialize a dictionary to hold region categorized as insert or delete.
        var existingRegionMap: [Int64: Region] = [:]
        
        if deleteOld {
            // Fetch existing regions.
            let descriptor = FetchDescriptor<Region>()
            if let existingregions = try? modelContext.fetch(descriptor) {
                // Map existing region by their IDs
                for region in existingregions {
                    existingRegionMap[region.id] = region
                }
            }
        }
        
        do {
            for regionProperty in regionPropertiesList {
                
                print("regionProperty: \(regionProperty.name)")
                // TODO: regionProperty.id should not be optional
                // Determine if <Region> already exists and remove from deletion queue
                let regionExists: Bool = existingRegionMap.keys.contains(regionProperty.id)
                print("deviceRoleExists: \(regionExists)")
                let regionOptional = regionExists ? existingRegionMap.removeValue(forKey: regionProperty.id) : Region(id: regionProperty.id)
                
                // Using optional binding to safely unwrap the region
                if let region = regionOptional {
                    // Check if lastUpdated values are equal
                    if region.lastUpdated != regionProperty.lastUpdated {
                        region.name = regionProperty.name
                        region.created = regionProperty.created
                        region.siteCount = regionProperty.siteCount
                        region.lastUpdated = regionProperty.lastUpdated
                        
                        // Establishing relationship with region
                        if let parentId = regionProperty.parentId,
                           parentId != 0,
                           parentId != region.parent?.id {
                            print("Establishing relationship with parent Region")
                            
                            let predicate = #Predicate<Region> { parent in
                                parent.id == parentId
                            }
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let parent = try? modelContext.fetch(fetchDescriptor).first {
                                region.parent = parent
                            }
                        }
                    } else {
                        region.name = regionProperty.name
                        region.created = regionProperty.created
                        region.siteCount = regionProperty.siteCount
                        region.lastUpdated = regionProperty.lastUpdated
                        
                        // Establishing relationship with region
                        if let parentId = regionProperty.parentId,
                           parentId != 0,
                           parentId != region.parent?.id {
                            print("Establishing relationship with parent Region")
                            
                            let predicate = #Predicate<Region> { parent in
                                parent.id == parentId
                            }
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let parent = try? modelContext.fetch(fetchDescriptor).first {
                                region.parent = parent
                            }
                        }
                    }
                    
                    // If region does not exist, insert it into the model context
                    if !regionExists {
                        print("Inserting \(regionProperty.name) into swiftData")
                        modelContext.insert(region)
                    }
                    
                }
            }
        }
        
        // Delete legacy regions after processing all regionProperties
        for remainingRegion in existingRegionMap.values {
            print("Deleting region: \(remainingRegion.name)")
            modelContext.delete(remainingRegion)
        }
        
        // Save the context to commit the changes
        do {
            print("Attempting to save swiftData")
            try modelContext.save()
        } catch {
            print("Error saving context after deleting deviceRoles: \(error)")
        }
        print ("Completed getRegions function")
    }
    
    /**
     Fetch and process deviceRole properties.
     
     This function fetches and processes deviceRole properties, updating existing deviceRoles and inserting new ones as necessary.
     It then deletes any remaining deviceRoles that were not in the fetched deviceRole properties.
     
     - Parameter deviceRoleProperties: An optional array of `deviceRoleProperties` to be processed. If `nil`, the function will fetch the deviceRole properties by executing a deviceRole API request.
     */
    func getDeviceRoles(deviceRoleProperties: [DeviceRoleProperties]? = nil) async throws  {
        let modelContext = ModelContext(modelContainer)
        
        var deviceRolePropertiesList: [DeviceRoleProperties] = []
        
        var deleteOld = false
        
        // If deviceRolePropertiesList is nil, execute deviceRole request to populate it.
        if let deviceRoleProperties = deviceRoleProperties {
            deviceRolePropertiesList = deviceRoleProperties
        } else {
            // Initialize resource and request objects.
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
            let netboxApiToken = await Configuration.shared.getNetboxApiToken()
            
            let resource = DeviceRoleResource()
            let deviceRoleRequest = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
            // Execute deviceRole API request.
            do {
                deviceRolePropertiesList = try await deviceRoleRequest.execute()
            } catch {
                // TODO: Advise user of errors
                print("Error executing deviceRole request: \(error)")
                throw error
            }
            deleteOld = true
        }
        
        // Initialize a dictionary to hold deviceRole categorized as insert or delete.
        var existingDeviceRoleMap: [Int64: DeviceRole] = [:]
        
        if deleteOld {
            // Fetch existing deviceRoles.
            let descriptor = FetchDescriptor<DeviceRole>()
            if let existingDeviceRoles = try? modelContext.fetch(descriptor) {
                // Map existing deviceRole by their IDs
                for deviceRole in existingDeviceRoles {
                    existingDeviceRoleMap[deviceRole.id] = deviceRole
                }
            }
        }
        
        do {
            for deviceRoleProperty in deviceRolePropertiesList {
                
                print("deviceRoleProperty: \(deviceRoleProperty.name)")
                // TODO: deviceRoleProperty.id should not be optional
                // Determine if <DeviceRole> already exists and remove from deletion queue
                let deviceRoleExists: Bool = existingDeviceRoleMap.keys.contains(deviceRoleProperty.id)
                print("deviceRoleExists: \(deviceRoleExists)")
                let deviceRoleOptional = deviceRoleExists ? existingDeviceRoleMap.removeValue(forKey: deviceRoleProperty.id) : DeviceRole(id: deviceRoleProperty.id)
                
                // Using optional binding to safely unwrap the deviceRole
                if let deviceRole = deviceRoleOptional {
                    // Check if lastUpdated values are equal
                    if deviceRole.lastUpdated != deviceRoleProperty.lastUpdated {
                        ///Perform updates if lastUpdated do not match
                        deviceRole.name = deviceRoleProperty.name
                        deviceRole.created = deviceRoleProperty.created
                        deviceRole.lastUpdated = deviceRoleProperty.lastUpdated
                        deviceRole.colour = deviceRoleProperty.colour
                        
                    } else {
                        deviceRole.name = deviceRoleProperty.name
                        deviceRole.created = deviceRoleProperty.created
                        deviceRole.lastUpdated = deviceRoleProperty.lastUpdated
                        deviceRole.colour = deviceRoleProperty.colour
                    }
                    
                    // If deviceRole does not exist, insert it into the model context
                    if !deviceRoleExists {
                        print("Inserting \(deviceRoleProperty.name) into swiftData")
                        modelContext.insert(deviceRole)
                    }
                    
                }
            }
        }
        
        // Delete legacy deviceRoles after processing all deviceRoleProperties
        for remainingDeviceRole in existingDeviceRoleMap.values {
            print("Deleting deviceRole: \(remainingDeviceRole.name ?? "Unknown")")
            modelContext.delete(remainingDeviceRole)
        }
        
        // Save the context to commit the changes
        do {
            print("Attempting to save swiftData")
            try modelContext.save()
        } catch {
            print("Error saving context after deleting deviceRoles: \(error)")
        }
        print ("Completed getDeviceRole function")
    }
    
    /**
     Fetch and process deviceType properties.
     
     This function fetches and processes deviceType properties, updating existing deviceTypes and inserting new ones as necessary.
     It then deletes any remaining deviceTypes that were not in the fetched deviceType properties.
     
     - Parameter deviceTypeProperties: An optional array of `deviceTypeProperties` to be processed. If `nil`, the function will fetch the site properties by executing a deviceType API request.
     */
    func getDeviceTypes(deviceTypeProperties: [DeviceTypeProperties]? = nil) async throws  {
        let modelContext = ModelContext(modelContainer)
        
        var deviceTypePropertiesList: [DeviceTypeProperties] = []
        
        var deleteOld = false
        
        // If deviceTypePropertiesList is nil, execute deviceType request to populate it.
        if let deviceTypeProperties = deviceTypeProperties {
            deviceTypePropertiesList = deviceTypeProperties
        } else {
            // Initialize resource and request objects.
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
            let netboxApiToken = await Configuration.shared.getNetboxApiToken()
            
            let resource = DeviceTypeResource()
            let deviceTypeRequest = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
            // Execute deviceType API request.
            do {
                deviceTypePropertiesList = try await deviceTypeRequest.execute()
            } catch {
                // TODO: Advise user of errors
                print("Error executing site request: \(error)")
                throw error
            }
            deleteOld = true
        }
        
        // Initialize a dictionary to hold deviceTypes categorized as insert or delete.
        var existingDeviceTypeMap: [Int64: DeviceType] = [:]
        
        if deleteOld {
            // Fetch existing deviceTypes.
            let descriptor = FetchDescriptor<DeviceType>()
            if let existingDeviceTypes = try? modelContext.fetch(descriptor) {
                // Map existing deviceTypes by their IDs
                for deviceType in existingDeviceTypes {
                    existingDeviceTypeMap[deviceType.id] = deviceType
                }
            }
        }
        
        do {
            for deviceTypeProperty in deviceTypePropertiesList {
                
                print("deviceTypeProperty: \(deviceTypeProperty.model)")
                // TODO: deviceTypeProperty.id should not be optional
                // Determine if <DeviceType> already exists and remove from deletion queue
                let deviceTypeExists: Bool = existingDeviceTypeMap.keys.contains(deviceTypeProperty.id)
                print("deviceTypeExists: \(deviceTypeExists)")
                let deviceTypeOptional = deviceTypeExists ? existingDeviceTypeMap.removeValue(forKey: deviceTypeProperty.id) : DeviceType(id: deviceTypeProperty.id)
                
                // Using optional binding to safely unwrap the deviceType
                if let deviceType = deviceTypeOptional {
                    // Check if lastUpdated values are equal
                    if deviceType.lastUpdated != deviceTypeProperty.lastUpdated {
                        ///Perform updates if lastUpdated do not match
                        deviceType.model = deviceTypeProperty.model
                        deviceType.created = deviceTypeProperty.created
                        deviceType.lastUpdated = deviceTypeProperty.lastUpdated
                        deviceType.uHeight = deviceTypeProperty.uHeight
                    } else {
                        deviceType.model = deviceTypeProperty.model
                        deviceType.created = deviceTypeProperty.created
                        deviceType.lastUpdated = deviceTypeProperty.lastUpdated
                        deviceType.uHeight = deviceTypeProperty.uHeight
                    }
                    
                    // If deviceType does not exist, insert it into the model context
                    if !deviceTypeExists {
                        print("Inserting \(deviceTypeProperty.model) into swiftData")
                        modelContext.insert(deviceType)
                    }
                }
            }
        }
        
        // Delete legacy deviceTypes after processing all deviceProperties
        for remainingDeviceType in existingDeviceTypeMap.values {
            print("Deleting deviceType: \(remainingDeviceType.model ?? "Unknown")")
            modelContext.delete(remainingDeviceType)
        }
        
        // Save the context to commit the changes
        do {
            print("Attempting to save swiftData")
            try modelContext.save()
        } catch {
            print("Error saving context after deleting sites: \(error)")
        }
        print ("Completed getDeviceType function")
    }
    
    /**
     Fetch and process siteGroup properties.
     
     This function fetches and processes siteGroup properties, updating existing siteGroups and inserting new ones as necessary.
     It then deletes any remaining site that were not in the fetched siteGroup properties.
     
     - Parameter siteGroupProperties: An optional array of `siteGroupProperties` to be processed. If `nil`, the function will fetch the site properties by executing a site API request.
     */
    func getSiteGroups(siteGroupProperties: [SiteGroupProperties]? = nil) async throws  {
        let modelContext = ModelContext(modelContainer)
        
        var siteGroupPropertiesList: [SiteGroupProperties] = []
        
        var deleteOld = false
        
        // If siteGroupProperties is nil, execute device request to populate it.
        if let siteGroupProperties = siteGroupProperties {
            siteGroupPropertiesList = siteGroupProperties
        } else {
            // Initialize resource and request objects.
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
            let netboxApiToken = await Configuration.shared.getNetboxApiToken()
            
            let resource = SiteGroupResource()
            let siteGroupRequest = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
            // Execute device API request.
            do {
                siteGroupPropertiesList = try await siteGroupRequest.execute()
            } catch {
                // TODO: Advise user of errors
                print("Error executing site request: \(error)")
                throw error
            }
            deleteOld = true
        }
        
        // Initialize a dictionary to hold siteGroups categorized as insert or delete.
        var existingSiteGroupMap: [Int64: SiteGroup] = [:]
        
        if deleteOld {
            // Fetch existing siteGroups.
            let descriptor = FetchDescriptor<SiteGroup>()
            if let existingSiteGroups = try? modelContext.fetch(descriptor) {
                // Map existing siteGroups by their IDs
                for siteGroup in existingSiteGroups {
                    existingSiteGroupMap[siteGroup.id] = siteGroup
                }
            }
        }
        
        do {
            for siteGroupProperty in siteGroupPropertiesList {
                
                print("siteGroupProperty: \(siteGroupProperty.name)")
                // TODO: siteGroupProperty.id should not be optional
                // Determine if <SiteGroup> already exists and remove from deletion queue
                let siteGroupExists: Bool = existingSiteGroupMap.keys.contains(siteGroupProperty.id)
                print("siteGroupExists: \(siteGroupExists)")
                let siteGroupOptional = siteGroupExists ? existingSiteGroupMap.removeValue(forKey: siteGroupProperty.id) : SiteGroup(id: siteGroupProperty.id)
                
                // Using optional binding to safely unwrap the device
                if let siteGroup = siteGroupOptional {
                    // Check if lastUpdated values are equal
                    if siteGroup.lastUpdated != siteGroupProperty.lastUpdated {
                        ///Perform updates if lastUpdated do not match
                        siteGroup.name = siteGroupProperty.name
                        siteGroup.created = siteGroupProperty.created
                        siteGroup.lastUpdated = siteGroupProperty.lastUpdated
                        
                        // Establishing relationship with siteGroup
                        if let parentId = siteGroupProperty.parentId,
                           parentId != 0,
                           parentId != siteGroup.parent?.id {
                            print("Establishing relationship with parent Site Group")
                            
                            let predicate = #Predicate<SiteGroup> { parent in
                                parent.id == parentId
                            }
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let parent = try? modelContext.fetch(fetchDescriptor).first {
                                siteGroup.parent = parent
                            }
                        }
                        
                    } else {
                        ///Create new Site object
                        siteGroup.name = siteGroupProperty.name
                        siteGroup.created = siteGroupProperty.created
                        siteGroup.lastUpdated = siteGroupProperty.lastUpdated
                        
                        // Establishing relationship with siteGroup
                        if let parentId = siteGroupProperty.parentId,
                           parentId != 0,
                           parentId != siteGroup.parent?.id {
                            print("Establishing relationship with parent Site Group")
                            
                            let predicate = #Predicate<SiteGroup> { parent in
                                parent.id == parentId
                            }
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let parent = try? modelContext.fetch(fetchDescriptor).first {
                                siteGroup.parent = parent
                            }
                        }
                    }
                    
                    // If siteGroup does not exist, insert it into the model context
                    if !siteGroupExists {
                        print("Inserting \(siteGroupProperty.name) into swiftData")
                        modelContext.insert(siteGroup)
                    }
                    
                }
            }
        }
        
        if deleteOld {
            // Delete legacy siteGroups after processing all siteGroupProperties
            for remainingSiteGroup in existingSiteGroupMap.values {
                
                print("Deleting siteGroup: \(remainingSiteGroup.name)")
                modelContext.delete(remainingSiteGroup)
            }
        }
        
        // Save the context to commit the changes
        do {
            print("Attempting to save swiftData")
            try modelContext.save()
        } catch {
            print("Error saving context after deleting sites: \(error)")
        }
        print ("Completed getSiteGroups function")
    }
    
    /**
     Fetch and process site properties.
     
     This function fetches and processes site properties, updating existing sites and inserting new ones as necessary.
     It then deletes any remaining site that were not in the fetched site properties.
     
     - Parameter siteProperties: An optional array of `SiteProperties` to be processed. If `nil`, the function will fetch the site properties by executing a site API request.
     */
    func getSites(siteProperties: [SiteProperties]? = nil) async throws  {
        let modelContext = ModelContext(modelContainer)
        
        var sitePropertiesList: [SiteProperties] = []
        
        //Flag for deleting old sites depending on whether a GET or POST request was made
        var deleteOld = false
        
        // If sitePropertiesList is nil, execute site request to populate it.
        if let siteProperties = siteProperties {
            sitePropertiesList = siteProperties
        } else {
            // Initialize resource and request objects.
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
            let netboxApiToken = await Configuration.shared.getNetboxApiToken()
            
            let resource = SiteResource()
            let siteRequest = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
            // Execute device API request.
            do {
                sitePropertiesList = try await siteRequest.execute()
            } catch {
                // TODO: Advise user of errors
                print("Error executing site request: \(error)")
                throw error
            }
            deleteOld = true
        }
        
        // Initialize a dictionary to hold sites categorized as insert or delete.
        var existingSiteMap: [Int64: Site] = [:]
        
        if deleteOld {
            // Fetch existing sites.
            let descriptor = FetchDescriptor<Site>()
            if let existingSites = try? modelContext.fetch(descriptor) {
                // Map existing sites by their IDs
                for site in existingSites {
                    existingSiteMap[site.id] = site
                }
            }
        }
        
        do {
            for siteProperty in sitePropertiesList {
                
                print("siteProperty: \(siteProperty.name)")
                // TODO: siteProperty.id should not be optional
                // Determine if <Site> already exists and remove from deletion queue
                let siteExists: Bool = existingSiteMap.keys.contains(siteProperty.id ?? 0)
                print("siteExists: \(siteExists)")
                let siteOptional = siteExists ? existingSiteMap.removeValue(forKey: siteProperty.id ?? 0) : Site(id: siteProperty.id ?? 0)
                
                // Using optional binding to safely unwrap the site
                if let site = siteOptional {
                    // Check if lastUpdated values are equal
                    if site.lastUpdated != siteProperty.lastUpdated {
                        site.created = siteProperty.created
                        site.deviceCount = siteProperty.deviceCount
                        site.display = siteProperty.display
                        site.lastUpdated = siteProperty.lastUpdated
                        site.latitude = siteProperty.latitude
                        site.longitude = siteProperty.longitude
                        site.name = siteProperty.name
                        site.status = siteProperty.status
                        site.physicalAddress = siteProperty.physicalAddress
                        site.shippingAddress = siteProperty.shippingAddress
                        site.url = siteProperty.url
                        
                        if siteProperty.groupId != 0 {
                            print("Establishing relationship with Site Group")
                            let groupId = siteProperty.groupId
                            
                            let predicate = #Predicate<SiteGroup> { siteGroup in
                                siteGroup.id == groupId
                            }
                            
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let siteGroup = try? modelContext.fetch(fetchDescriptor).first {
                                site.group = siteGroup
                            }
                        }
                        
                        // Establishing relationship with Tenant Group
                        if siteProperty.tenantId != 0 {
                            print("Establishing relationship with Site Group")
                            let tenantId = siteProperty.tenantId
                            
                            let predicate = #Predicate<Tenant> { tenant in
                                tenant.id == tenantId
                            }
                            
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let tenant = try? modelContext.fetch(fetchDescriptor).first {
                                site.tenant = tenant
                            }
                        }
                        
                        if siteProperty.regionId != 0 {
                            print("Establishing relationship with Site Group")
                            let regionId = siteProperty.regionId
                            
                            let predicate = #Predicate<Region> { region in
                                region.id == regionId
                            }
                            
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let region = try? modelContext.fetch(fetchDescriptor).first {
                                site.region = region
                            }
                        }
                        
                    } else {
                        site.created = siteProperty.created
                        site.deviceCount = siteProperty.deviceCount
                        site.display = siteProperty.display
                        site.lastUpdated = siteProperty.lastUpdated
                        site.latitude = siteProperty.latitude
                        site.longitude = siteProperty.longitude
                        site.name = siteProperty.name
                        site.status = siteProperty.status
                        site.physicalAddress = siteProperty.physicalAddress
                        site.shippingAddress = siteProperty.shippingAddress
                        site.url = siteProperty.url
                        
                        // If site does not exist, insert it into the model context
                        if !siteExists {
                            print("Inserting \(siteProperty.name) into swiftData")
                            modelContext.insert(site)
                        }
                        
                        // TODO: Refactor mapping of relationships
                        // Establishing relationship with Site Group
                        if siteProperty.groupId != 0 {
                            print("Establishing relationship with Site Group")
                            let groupId = siteProperty.groupId
                            
                            let predicate = #Predicate<SiteGroup> { siteGroup in
                                siteGroup.id == groupId
                            }
                            
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let siteGroup = try? modelContext.fetch(fetchDescriptor).first {
                                site.group = siteGroup
                            }
                        }
                        
                        // Establishing relationship with Tenant Group
                        if siteProperty.tenantId != 0 {
                            print("Establishing relationship with Site Group")
                            let tenantId = siteProperty.tenantId
                            
                            let predicate = #Predicate<Tenant> { tenant in
                                tenant.id == tenantId
                            }
                            
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let tenant = try? modelContext.fetch(fetchDescriptor).first {
                                site.tenant = tenant
                            }
                        }
                        
                        if siteProperty.regionId != 0 {
                            print("Establishing relationship with Site Group")
                            let regionId = siteProperty.regionId
                            
                            let predicate = #Predicate<Region> { region in
                                region.id == regionId
                            }
                            
                            let fetchDescriptor = FetchDescriptor(predicate: predicate)
                            
                            if let region = try? modelContext.fetch(fetchDescriptor).first {
                                site.region = region
                            }
                        }
                    }
                }
            }
        }
        
        // Delete legacy sites after processing all deviceProperties
        for remainingSite in existingSiteMap.values {
            
            print("Deleting site: \(remainingSite.name)")
            modelContext.delete(remainingSite)
        }
        
        // Save the context to commit the changes
        do {
            print("Attempting to save swiftData")
            try modelContext.save()
        } catch {
            print("Error saving context after deleting sites: \(error)")
        }
        print ("Completed getSites function")
    }
    
    //TODO: Implement logic to delete old racks
    func getRacks(rackProperties: [RackProperties]? = nil) async throws  {
        let modelContext = ModelContext(modelContainer)
        
        var rackPropertiesList: [RackProperties] = []
        var deleteOld = false
        
        // Fetch rack properties if not provided
        if let rackProperties = rackProperties {
            rackPropertiesList = rackProperties
        } else {
            // Fetch from API
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
            let netboxApiToken = await Configuration.shared.getNetboxApiToken()
            
            let resource = RackResource()
            let rackRequest = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
            
            do {
                rackPropertiesList = try await rackRequest.execute()
            } catch {
                print("Error executing rack request: \(error)")
                throw error
            }
            deleteOld = true
        }
        
        // Fetch existing racks
        var existingRackMap: [Int64: Rack] = [:]
        if deleteOld {
            let descriptor = FetchDescriptor<Rack>()
            if let existingRacks = try? modelContext.fetch(descriptor) {
                for rack in existingRacks {
                    existingRackMap[rack.id] = rack
                }
            }
        }
        
        // Process rack properties
        for rackProperty in rackPropertiesList {
            let rackExists = existingRackMap.keys.contains(rackProperty.id ?? 0)
            let rack = rackExists ? existingRackMap.removeValue(forKey: rackProperty.id ?? 0) : Rack(id: rackProperty.id ?? 0)
            
            if let rack = rack {
                // Update rack properties
                rack.name = rackProperty.name
                rack.display = rackProperty.display
                rack.created = rackProperty.created
                rack.lastUpdated = rackProperty.lastUpdated
                rack.url = rackProperty.url
                rack.uHeight = rackProperty.uHeight
                rack.startingUnit = rackProperty.startingUnit
                rack.deviceCount = rackProperty.deviceCount
                rack.status = rackProperty.status
                rack.formFactor = rackProperty.formFactor
                
                // Handle site relationship
                if rackProperty.siteId != 0 {
                    let predicate = #Predicate<Site> { site in
                        site.id == rackProperty.siteId
                    }
                    let fetchDescriptor = FetchDescriptor(predicate: predicate)
                    if let site = try? modelContext.fetch(fetchDescriptor).first {
                        rack.site = site
                    }
                }
                
                if !rackExists {
                    modelContext.insert(rack)
                }
            }
        }
        
        // Delete old racks
        for remainingRack in existingRackMap.values {
            modelContext.delete(remainingRack)
        }
        
        // Save changes
        do {
            try modelContext.save()
        } catch {
            print("Error saving context after processing racks: \(error)")
        }
        
        print("Completed getRacks function")
    }
    
    
    /**
     Fetch and process device properties.
     
     This function fetches and processes device properties, updating existing devices and inserting new ones as necessary.
     It then deletes any remaining devices that were not in the fetched device properties.
     
     - Parameter deviceProperties: An optional array of `DeviceProperties` to be processed. If `nil`, the function will fetch the device properties by executing a device API request.
     */
    func getDevices(deviceProperties: [DeviceProperties]? = nil) async throws  {
        let modelContext = ModelContext(modelContainer)
        
        var devicePropertiesList: [DeviceProperties] = []
        
        // Flag for deleting old devices depending on whether a GET or POST request was made
        var deleteOld = false
        
        // If devicePropertiesList is nil, execute device request to populate it.
        if let deviceProperties = deviceProperties {
            devicePropertiesList = deviceProperties
        } else {
            // Initialize resource and request objects.
            let netboxApiServer = await Configuration.shared.getNetboxApiServer()
            let netboxApiToken = await Configuration.shared.getNetboxApiToken()
            
            let resource = DeviceResource()
            let deviceRequest = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
            // Execute device API request.
            do {
                devicePropertiesList = try await deviceRequest.execute()
            } catch {
                // TODO: Advise user of errors
                print("Error executing device request: \(error)")
                throw error
            }
            deleteOld = true
        }
        
        let existingDevices = (try? modelContext.fetch(FetchDescriptor<Device>())) ?? []
        let existingDeviceIds = Set(existingDevices.map { $0.id })
        
        do {
            
            // Processing devices in batches
            let batchSize = determineBatchSize(for: devicePropertiesList.count)
            let totalBatches = (devicePropertiesList.count + batchSize - 1) / batchSize
            
            print("Batch size: \(batchSize)")
            print("Batch count: \(totalBatches)")
            
            await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<totalBatches {
                    let batchStartIndex = i * batchSize
                    let batchEndIndex = min(batchStartIndex + batchSize, devicePropertiesList.count)
                    let batch = Array(devicePropertiesList[batchStartIndex..<batchEndIndex])
                    
                    group.addTask {
                        try await self.processDeviceBatch(batch: batch, existingDeviceIds: existingDeviceIds)
                    }
                }
            }
            
            if deleteOld {
                let updatedDeviceIds = Set(devicePropertiesList.map { $0.id! })
                let devicesToDelete = existingDeviceIds.subtracting(updatedDeviceIds)
                
                for deviceId in devicesToDelete {
                    let predicate = #Predicate<Device> { $0.id == deviceId }
                    let fetchDescriptor = FetchDescriptor(predicate: predicate)
                    if let deviceToDelete = try? modelContext.fetch(fetchDescriptor).first {
                        modelContext.delete(deviceToDelete)
                    }
                }
            }
            
            // Set last NetBox update to now
            let fetchDescriptor = FetchDescriptor<SyncProvider>()
            let syncProvider = try modelContext.fetch(fetchDescriptor)
            syncProvider.first?.lastNetBoxUpdate = Date()
            
            try modelContext.save()
            
        } catch {
            print("Failed. Error: \(error)")
        }
        print("Completed getDevices function")
    }
    
    private func processDeviceBatch(batch: [DeviceProperties], existingDeviceIds: Set<Int64>) async throws {
        let batchContext = ModelContext(modelContainer)
        
        // Fetch related objects in advance
        let devices = try batchContext.fetch(FetchDescriptor<Device>())
        let filteredDevices = devices.filter { existingDeviceIds.contains($0.id) }
        
        // Use a dictionary that allows multiple values per key
        var devicesDict = [Int64: [Device]]()
        for device in filteredDevices {
            devicesDict[device.id, default: []].append(device)
        }
        
        let deviceRoles = try batchContext.fetch(FetchDescriptor<DeviceRole>())
        let deviceRolesDict = Dictionary(uniqueKeysWithValues: deviceRoles.map { ($0.id, $0) })
        
        let deviceTypes = try batchContext.fetch(FetchDescriptor<DeviceType>())
        let deviceTypesDict = Dictionary(uniqueKeysWithValues: deviceTypes.map { ($0.id, $0) })
        
        let sites = try batchContext.fetch(FetchDescriptor<Site>())
        let sitesDict = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, $0) })
        
        // Fetch all Racks
        let racks = try batchContext.fetch(FetchDescriptor<Rack>())
        let racksDict = Dictionary(uniqueKeysWithValues: racks.map { ($0.id, $0) })
        
        for deviceProperty in batch {
            if let existingDevices = devicesDict[deviceProperty.id!], !existingDevices.isEmpty {
                // Update the first existing device with this ID
                let existingDevice = existingDevices[0]
                // Optionally update existing device properties if needed
                existingDevice.created = deviceProperty.created
                existingDevice.display = deviceProperty.display
                existingDevice.lastUpdated = deviceProperty.lastUpdated
                existingDevice.name = deviceProperty.name
                existingDevice.rackPosition = deviceProperty.rackPosition
                existingDevice.primaryIP = deviceProperty.primaryIP
                existingDevice.serial = deviceProperty.serial
                existingDevice.url = deviceProperty.url
                existingDevice.x = deviceProperty.x
                existingDevice.y = deviceProperty.y
                existingDevice.zabbixId = deviceProperty.zabbixId
                existingDevice.zabbixInstance = deviceProperty.zabbixInstance
                
                // Update device role relationship
                if deviceProperty.deviceRoleId != 0, let deviceRole = deviceRolesDict[deviceProperty.deviceRoleId] {
                    existingDevice.deviceRole = deviceRole
                } else {
                    existingDevice.deviceRole = nil
                }
                
                // Update device type relationship
                if deviceProperty.deviceTypeId != 0, let deviceType = deviceTypesDict[deviceProperty.deviceTypeId] {
                    existingDevice.deviceType = deviceType
                } else {
                    existingDevice.deviceType = nil
                }
                
                // Update site relationship
                if deviceProperty.siteId != 0, let site = sitesDict[deviceProperty.siteId] {
                    existingDevice.site = site
                } else {
                    existingDevice.site = nil
                }
                
                // Update rack relationship
                if let rackId = deviceProperty.rackId, rackId != 0, let rack = racksDict[rackId] {
                    existingDevice.rack = rack
                } else {
                    existingDevice.rack = nil
                }
                
                // If there are more devices with the same ID, log a warning
                if existingDevices.count > 1 {
                    print("Warning: Multiple devices found with ID: \(deviceProperty.id!). Only the first one was updated.")
                }
            } else {
                // Insert new device
                let device = Device(id: deviceProperty.id!)
                device.created = deviceProperty.created
                device.display = deviceProperty.display
                device.lastUpdated = deviceProperty.lastUpdated
                device.name = deviceProperty.name
                device.rackPosition = deviceProperty.rackPosition
                device.primaryIP = deviceProperty.primaryIP
                device.serial = deviceProperty.serial
                device.url = deviceProperty.url
                device.x = deviceProperty.x
                device.y = deviceProperty.y
                device.zabbixId = deviceProperty.zabbixId
                device.zabbixInstance = deviceProperty.zabbixInstance
                
                // Establishing relationship with Device Role
                if deviceProperty.deviceRoleId != 0, let deviceRole = deviceRolesDict[deviceProperty.deviceRoleId] {
                    device.deviceRole = deviceRole
                }
                
                // Establishing relationship with Device Type
                if deviceProperty.deviceTypeId != 0, let deviceType = deviceTypesDict[deviceProperty.deviceTypeId] {
                    device.deviceType = deviceType
                }
                
                // Establishing relationship with Site
                if deviceProperty.siteId != 0, let site = sitesDict[deviceProperty.siteId] {
                    device.site = site
                }
                
                // Establishing relationship with Rack
                if let rackId = deviceProperty.rackId, rackId != 0, let rack = racksDict[rackId] {
                    device.rack = rack
                }
                
                batchContext.insert(device)
            }
        }
        
        try batchContext.save()
        print("Devices in batch processed.")
    }
    
    private func determineBatchSize(for count: Int) -> Int {
        // TODO: Adjust these values based on performance testing
        switch count {
        case 1...10:
            return 2
        case 11...100:
            return 10
        case 101...500:
            return 25
        case 501...1000:
            return 50
        case 1001...10000:
            return 500
        case 10001...50000:
            return 2500
        case 50001...100000:
            return 1000
        default:
            return 2000
        }
    }
    
    //MARK: New functions for creating Device, Site and Cable
    func postSite(with properties: SiteProperties) async {
        let netboxApiServer = await Configuration.shared.getNetboxApiServer()
        let netboxApiToken = await Configuration.shared.getNetboxApiToken()
        
        let siteResource = SiteResource(siteProperties: properties)
        let apiRequest = APIRequest(resource: siteResource, apiKey: netboxApiToken, baseURL: netboxApiServer)
        
        do {
            let response = try await apiRequest.execute()
            try await getSites(siteProperties: response)
            
            print ("Completed submitSite function")
            print ("Response: \(response)")
        } catch {
            print("Failed. Error: \(error)")
        }
    }
    
    func postDevice(with properties: DeviceProperties) async {
        let netboxApiServer = await Configuration.shared.getNetboxApiServer()
        let netboxApiToken = await Configuration.shared.getNetboxApiToken()
        
        let deviceResource = DeviceResource(deviceProperties: properties)
        let apiRequest = APIRequest(resource: deviceResource, apiKey: netboxApiToken, baseURL: netboxApiServer)
        
        do {
            let response = try await apiRequest.execute()
            try await getDevices(deviceProperties: response)
            
            print ("Completed submitDevice function")
            print ("Response: \(response)")
        } catch {
            print("Failed. Error: \(error)")
        }
    }
    
    //MARK: Functions for updating Device (and other NetBox objects in the future)
    func updateDevice(with properties: DeviceProperties) async {
        guard properties.id != nil else {
            print("Error: Device ID is missing for update operation.")
            return
        }
        let netboxApiServer = await Configuration.shared.getNetboxApiServer()
        let netboxApiToken = await Configuration.shared.getNetboxApiToken()
        
        let deviceResource = DeviceResource(deviceProperties: properties, deviceId: properties.id ?? 0)
        let apiRequest = APIRequest(resource: deviceResource, apiKey: netboxApiToken, baseURL: netboxApiServer)
        
        do {
            let response = try await apiRequest.execute()
            
            print("Response: \(response)")
            print("Completed updateDevice function" )
        } catch {
            print("Failed to update device. Error: \(error)")
        }
    }
}
