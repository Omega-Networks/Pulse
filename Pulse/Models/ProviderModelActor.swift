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

// MARK: - Protocols and Extensions

// Protocol for all entity properties
protocol EntityPropertiesProtocol {
    var id: Int64 { get }
    var lastUpdated: Date { get }
//    var created: Date? { get }
}

// Protocol for entities that can be identified and updated
protocol IdentifiableEntity: AnyObject {
    var entityId: Int64 { get }
    var lastUpdated: Date? { get set }
    var created: Date? { get set }
}

// Protocol for entity-specific operations
protocol EntityOperations {
    associatedtype EntityType: IdentifiableEntity & PersistentModel
    associatedtype PropertiesType: EntityPropertiesProtocol
    
    func createEntity(from properties: PropertiesType) -> EntityType
    func updateEntity(_ entity: EntityType, with properties: PropertiesType)
    func setupRelationships(for entity: EntityType, with properties: PropertiesType, in context: ModelContext) throws
}

// Protocol conformances for existing entities
extension SiteGroupProperties: EntityPropertiesProtocol {}
extension SiteProperties: EntityPropertiesProtocol {}
extension DeviceProperties: EntityPropertiesProtocol {}
extension EventProperties: EntityPropertiesProtocol {
    var id: Int64 {
        return Int64.random(in: Int64.min...Int64.max)
    }
}
extension RackProperties: EntityPropertiesProtocol {}
extension DeviceRoleProperties: EntityPropertiesProtocol {}
extension DeviceTypeProperties: EntityPropertiesProtocol {}
extension TenantGroupProperties: EntityPropertiesProtocol {}
extension TenantProperties: EntityPropertiesProtocol {}
extension RegionProperties: EntityPropertiesProtocol {}

// Entity conformances to IdentifiableEntity
extension SiteGroup: IdentifiableEntity { var entityId: Int64 { id } }
extension Site: IdentifiableEntity { var entityId: Int64 { id } }
extension DeviceRole: IdentifiableEntity { var entityId: Int64 { id } }
extension DeviceType: IdentifiableEntity { var entityId: Int64 { id } }
extension TenantGroup: IdentifiableEntity { var entityId: Int64 { id } }
extension Tenant: IdentifiableEntity { var entityId: Int64 { id } }
extension Region: IdentifiableEntity { var entityId: Int64 { id } }
extension Rack: IdentifiableEntity { var entityId: Int64 { id } }
extension Device: IdentifiableEntity { var entityId: Int64 { id } }

// MARK: - Error Types

enum ProviderModelError: Error, LocalizedError {
    case networkFailure(underlying: Error)
    case dataCorruption
    case relationshipMappingFailed(entityId: Int64)
    case saveOperationFailed(underlying: Error)
    case configurationMissing
    
    var errorDescription: String? {
        switch self {
        case .networkFailure(let error):
            return "Network operation failed: \(error.localizedDescription)"
        case .dataCorruption:
            return "Data integrity violation detected"
        case .relationshipMappingFailed(let entityId):
            return "Failed to map relationships for entity ID: \(entityId)"
        case .saveOperationFailed(let error):
            return "Failed to save data: \(error.localizedDescription)"
        case .configurationMissing:
            return "Required configuration is missing"
        }
    }
}

// MARK: - Entity Operations Implementations

struct TenantGroupOperations: EntityOperations {
    typealias EntityType = TenantGroup
    typealias PropertiesType = TenantGroupProperties
    
    func createEntity(from properties: TenantGroupProperties) -> TenantGroup {
        return TenantGroup(properties)
    }
    
    func updateEntity(_ entity: TenantGroup, with properties: TenantGroupProperties) {
        entity.name = properties.name
        entity.created = properties.created
        entity.lastUpdated = properties.lastUpdated
    }
    
    //TODO: Check db for tenant - tenantgroup relationship
    func setupRelationships(for entity: TenantGroup, with properties: TenantGroupProperties, in context: ModelContext) throws {
    }
}

struct TenantOperations: EntityOperations {
    typealias EntityType = Tenant
    typealias PropertiesType = TenantProperties
    
    func createEntity(from properties: TenantProperties) -> Tenant {
        return Tenant(properties)
    }
    
    func updateEntity(_ entity: Tenant, with properties: TenantProperties) {
        entity.name = properties.name
        entity.created = properties.created
        entity.lastUpdated = properties.lastUpdated
    }
    
    func setupRelationships(for entity: Tenant, with properties: TenantProperties, in context: ModelContext) throws {
        if let groupId = properties.groupId, groupId != 0 {
            let predicate = #Predicate<TenantGroup> { tenantGroup in
                tenantGroup.id == groupId
            }
            let fetchDescriptor = FetchDescriptor(predicate: predicate)
            if let tenantGroup = try? context.fetch(fetchDescriptor).first {
                entity.group = tenantGroup
            }
        }
    }
}

struct RegionOperations: EntityOperations {
    typealias EntityType = Region
    typealias PropertiesType = RegionProperties
    
    func createEntity(from properties: RegionProperties) -> Region {
        return Region(properties)
    }
    
    func updateEntity(_ entity: Region, with properties: RegionProperties) {
        entity.name = properties.name
        entity.created = properties.created
        entity.siteCount = properties.siteCount
        entity.lastUpdated = properties.lastUpdated
    }
    
    func setupRelationships(for entity: Region, with properties: RegionProperties, in context: ModelContext) throws {
        if let parentId = properties.parentId, parentId != 0, parentId != entity.parent?.id {
            let predicate = #Predicate<Region> { parent in
                parent.id == parentId
            }
            let fetchDescriptor = FetchDescriptor(predicate: predicate)
            if let parent = try? context.fetch(fetchDescriptor).first {
                entity.parent = parent
            }
        }
    }
}

struct DeviceRoleOperations: EntityOperations {
    typealias EntityType = DeviceRole
    typealias PropertiesType = DeviceRoleProperties
    
    func createEntity(from properties: DeviceRoleProperties) -> DeviceRole {
        return DeviceRole(properties)
    }
    
    func updateEntity(_ entity: DeviceRole, with properties: DeviceRoleProperties) {
        entity.name = properties.name
        entity.created = properties.created
        entity.lastUpdated = properties.lastUpdated
        entity.colour = properties.colour
    }
    
    //TODO: Setup Device relationship if needed, check db
    func setupRelationships(for entity: DeviceRole, with properties: DeviceRoleProperties, in context: ModelContext) throws {
    }
}

struct DeviceTypeOperations: EntityOperations {
    typealias EntityType = DeviceType
    typealias PropertiesType = DeviceTypeProperties
    
    func createEntity(from properties: DeviceTypeProperties) -> DeviceType {
        return DeviceType(properties)
    }
    
    func updateEntity(_ entity: DeviceType, with properties: DeviceTypeProperties) {
        entity.model = properties.model
        entity.created = properties.created
        entity.lastUpdated = properties.lastUpdated
        entity.uHeight = properties.uHeight
    }
    
    //TODO: Maybe reverse is enough, check db
    func setupRelationships(for entity: DeviceType, with properties: DeviceTypeProperties, in context: ModelContext) throws {
    }
}

struct SiteGroupOperations: EntityOperations {
    typealias EntityType = SiteGroup
    typealias PropertiesType = SiteGroupProperties
    
    func createEntity(from properties: SiteGroupProperties) -> SiteGroup {
        return SiteGroup(properties)
    }
    
    func updateEntity(_ entity: SiteGroup, with properties: SiteGroupProperties) {
        entity.name = properties.name
        entity.created = properties.created
        entity.lastUpdated = properties.lastUpdated
    }
    
    func setupRelationships(for entity: SiteGroup, with properties: SiteGroupProperties, in context: ModelContext) throws {
        if let parentId = properties.parentId, parentId != 0, parentId != entity.parent?.id {
            let predicate = #Predicate<SiteGroup> { parent in
                parent.id == parentId
            }
            let fetchDescriptor = FetchDescriptor(predicate: predicate)
            if let parent = try? context.fetch(fetchDescriptor).first {
                entity.parent = parent
            }
        }
    }
}

struct SiteOperations: EntityOperations {
    typealias EntityType = Site
    typealias PropertiesType = SiteProperties
    
    func createEntity(from properties: SiteProperties) -> Site {
        return Site(properties)
    }
    
    func updateEntity(_ entity: Site, with properties: SiteProperties) {
        entity.created = properties.created
        entity.deviceCount = properties.deviceCount
        entity.display = properties.display
        entity.lastUpdated = properties.lastUpdated
        entity.latitude = properties.latitude
        entity.longitude = properties.longitude
        entity.name = properties.name
        entity.status = properties.status
        entity.physicalAddress = properties.physicalAddress
        entity.shippingAddress = properties.shippingAddress
        entity.url = properties.url
    }
    
    func setupRelationships(for entity: Site, with properties: SiteProperties, in context: ModelContext) throws {
        if properties.groupId != 0 {
            print("Establishing relationship with Site Group")
            let groupId = properties.groupId
            
            let predicate = #Predicate<SiteGroup> { siteGroup in
                siteGroup.id == groupId
            }
            
            let fetchDescriptor = FetchDescriptor(predicate: predicate)
            
            if let siteGroup = try? context.fetch(fetchDescriptor).first {
                entity.group = siteGroup
            }
        }
    
        if properties.tenantId != 0 {
            print("Establishing relationship with Site Group")
            let tenantId = properties.tenantId
            
            let predicate = #Predicate<Tenant> { tenant in
                tenant.id == tenantId
            }
            
            let fetchDescriptor = FetchDescriptor(predicate: predicate)
            
            if let tenant = try? context.fetch(fetchDescriptor).first {
                entity.tenant = tenant
            }
        }
        
        if properties.regionId != 0 {
            print("Establishing relationship with Site Group")
            let regionId = properties.regionId
            
            let predicate = #Predicate<Region> { region in
                region.id == regionId
            }
            
            let fetchDescriptor = FetchDescriptor(predicate: predicate)
            
            if let region = try? context.fetch(fetchDescriptor).first {
                entity.region = region
            }
        }
    }
    
}

struct RackOperations: EntityOperations {
    typealias EntityType = Rack
    typealias PropertiesType = RackProperties
    
    func createEntity(from properties: RackProperties) -> Rack {
        return Rack(properties)
    }
    
    func updateEntity(_ entity: Rack, with properties: RackProperties) {
        entity.name = properties.name
        entity.display = properties.display
        entity.created = properties.created
        entity.lastUpdated = properties.lastUpdated
        entity.url = properties.url
        entity.uHeight = properties.uHeight
        entity.startingUnit = properties.startingUnit
        entity.deviceCount = properties.deviceCount
        entity.status = properties.status
        entity.formFactor = properties.formFactor
    }
    
    func setupRelationships(for entity: Rack, with properties: RackProperties, in context: ModelContext) throws {
        // Handle site relationship
        if properties.siteId != 0 {
            let predicate = #Predicate<Site> { site in
                site.id == properties.siteId
            }
            let fetchDescriptor = FetchDescriptor(predicate: predicate)
            if let site = try? context.fetch(fetchDescriptor).first {
                entity.site = site
            }
        }
        
    }
}

struct DeviceOperations: EntityOperations {
    typealias EntityType = Device
    typealias PropertiesType = DeviceProperties
    
    func createEntity(from properties: DeviceProperties) -> Device {
        return  Device(properties)
    }
    
    func updateEntity(_ entity: Device, with properties: DeviceProperties) {
        let device = Device(id: properties.id)
        device.created = properties.created
        device.display = properties.display
        device.lastUpdated = properties.lastUpdated
        device.name = properties.name
        device.rackPosition = properties.rackPosition
        device.primaryIP = properties.primaryIP
        device.serial = properties.serial
        device.url = properties.url
        device.x = properties.x
        device.y = properties.y
        device.zabbixId = properties.zabbixId
        device.zabbixInstance = properties.zabbixInstance
    }
    
    func setupRelationships(for entity: Device, with properties: DeviceProperties, in context: ModelContext) throws {
        // Establishing relationship with Device Role
        if (properties.deviceRoleId != 0) {
            let deviceRolePredicate = #Predicate<DeviceRole> {
                item in item.id == properties.deviceRoleId
            }
            let deviceRole = try? context.fetch(FetchDescriptor(predicate: deviceRolePredicate)).first;
            entity.deviceRole = deviceRole
        }
        
        // Establishing relationship with Device Type
        if (properties.deviceTypeId != 0){
            let deviceTypePredicate = #Predicate<DeviceType> {
                role in role.id == properties.deviceTypeId
            }
            let deviceType = try? context.fetch(FetchDescriptor(predicate: deviceTypePredicate)).first;
            entity.deviceType = deviceType
        }
        
        // Establishing relationship with Site
        if (properties.siteId != 0) {
            let sitePredicate = #Predicate<Site> {
                item in item.id == properties.siteId
            }
            let site = try? context.fetch(FetchDescriptor(predicate: sitePredicate)).first;
            entity.site = site
        }
        
        // Establishing relationship with Rack
        if (properties.rackId != 0){
            let rackPredicate = #Predicate<Rack> {
                role in role.id == (properties.rackId ?? 0)
            }
            let rack = try? context.fetch(FetchDescriptor(predicate: rackPredicate)).first;
            entity.rack = rack
        }
    }
}

// MARK: - Main Actor

actor ProviderModelActor {
    // Use custom notification instead of @Published for actor
    private var _isLoadingZabbixEvents = false
    private var _isLoadingZabbixItems = false
    private var _isLoadingZabbixHistories = false
    
    var isLoadingZabbixEvents: Bool { _isLoadingZabbixEvents }
    var isLoadingZabbixItems: Bool { _isLoadingZabbixItems }
    var isLoadingZabbixHistories: Bool { _isLoadingZabbixHistories }
    
    var enableMonitoring = false
    var modelContainer: ModelContainer
    
    private let logger = Logger(subsystem: "PulseSync", category: "ProviderModelActor")
    
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }
    
    // MARK: - Generic CRUD Operations
    
    private func processEntities<T: EntityOperations>(
        properties: [T.PropertiesType]? = nil,
        operations: T,
        apiFetcher: (() async throws -> [T.PropertiesType])? = nil,
        entityName: String
    ) async throws {
        let modelContext = ModelContext(modelContainer)
        var propertiesList: [T.PropertiesType] = []
        var shouldDeleteOld = false
        
        logger.debug("Starting process for \(entityName)")
        
        // Determine data source
        if let properties = properties {
            propertiesList = properties
            logger.debug("Using provided properties for \(entityName)")
        } else if let fetcher = apiFetcher {
            do {
                propertiesList = try await fetcher()
                shouldDeleteOld = true
                logger.debug("Fetched \(propertiesList.count) \(entityName) from API")
            } catch {
                logger.error("Failed to fetch \(entityName): \(error.localizedDescription)")
                throw ProviderModelError.networkFailure(underlying: error)
            }
        }
        
        // Build map of existing entities
        var existingEntityMap: [Int64: T.EntityType] = [:]
        if shouldDeleteOld {
            let descriptor = FetchDescriptor<T.EntityType>()
            if let existingEntities = try? modelContext.fetch(descriptor) {
                for entity in existingEntities {
                    existingEntityMap[entity.entityId] = entity
                }
                logger.debug("Found \(existingEntities.count) existing \(entityName)")
            }
        }
        
        // Process entities
        for properties in propertiesList {
            let entityExists = existingEntityMap.keys.contains(properties.id)
            let entity = entityExists ?
                existingEntityMap.removeValue(forKey: properties.id) :
                operations.createEntity(from: properties)
            
            if let entity = entity {
                // Only update if lastUpdated differs or it's a new entity
                if !entityExists || entity.lastUpdated != properties.lastUpdated {
                    operations.updateEntity(entity, with: properties)
                    do {
                        try operations.setupRelationships(for: entity, with: properties, in: modelContext)
                    } catch {
                        logger.error("Failed to setup relationships for \(entityName) ID \(properties.id): \(error.localizedDescription)")
                        throw ProviderModelError.relationshipMappingFailed(entityId: properties.id)
                    }
                }
                
                if !entityExists {
                    modelContext.insert(entity)
                    logger.debug("Inserting new \(entityName): ID \(properties.id)")
                }
            }
        }
        
        // Delete stale entities
        for remainingEntity in existingEntityMap.values {
            logger.debug("Deleting stale \(entityName): ID \(remainingEntity.entityId)")
            modelContext.delete(remainingEntity)
        }
        
        // Save changes
        do {
            try modelContext.save()
            logger.info("Successfully processed \(propertiesList.count) \(entityName)")
        } catch {
            logger.error("Failed to save \(entityName): \(error.localizedDescription)")
            throw ProviderModelError.saveOperationFailed(underlying: error)
        }
    }
    
    // MARK: - API Fetcher Functions
    
    private func fetchFromNetBoxAPI<Resource: Sendable>(
        resourceType: Resource.Type
    ) async throws -> [Resource.ModelType]
    where Resource: APIResourceProtocol & NetboxResource
    {
        let netboxApiServer = await Configuration.shared.getNetboxApiServer()
        let netboxApiToken = await Configuration.shared.getNetboxApiToken()
        
        let resource = resourceType.init()
        let request = APIRequest(resource: resource, apiKey: netboxApiToken, baseURL: netboxApiServer)
        let res = try await request.execute();
        return res;
    }
    
    // MARK: - Public Interface Methods
    func getTenantGroups(tenantGroupProperties: [TenantGroupProperties]? = nil) async throws {
        try await processEntities(
            properties: tenantGroupProperties,
            operations: TenantGroupOperations(),
            apiFetcher: tenantGroupProperties == nil ? {
                try await self.fetchFromNetBoxAPI(resourceType: TenantGroupResource.self)
            } : nil,
            entityName: "TenantGroups"
        )
    }
    
    func getTenants(tenantProperties: [TenantProperties]? = nil) async throws {
        try await processEntities(
            properties: tenantProperties,
            operations: TenantOperations(),
            apiFetcher: tenantProperties == nil ? {
                try await self.fetchFromNetBoxAPI(resourceType: TenantResource.self)
            } : nil,
            entityName: "Tenants"
        )
    }
    
    func getRegions(regionProperties: [RegionProperties]? = nil) async throws {
        try await processEntities(
            properties: regionProperties,
            operations: RegionOperations(),
            apiFetcher: regionProperties == nil ? {
                try await self.fetchFromNetBoxAPI(resourceType: RegionResource.self)
            } : nil,
            entityName: "Regions"
        )
    }
    
    func getDeviceRoles(deviceRoleProperties: [DeviceRoleProperties]? = nil) async throws {
        try await processEntities(
            properties: deviceRoleProperties,
            operations: DeviceRoleOperations(),
            apiFetcher: deviceRoleProperties == nil ? {
                try await self.fetchFromNetBoxAPI(resourceType: DeviceRoleResource.self)
            } : nil,
            entityName: "DeviceRoles"
        )
    }
    
    func getDeviceTypes(deviceTypeProperties: [DeviceTypeProperties]? = nil) async throws {
        try await processEntities(
            properties: deviceTypeProperties,
            operations: DeviceTypeOperations(),
            apiFetcher: deviceTypeProperties == nil ? {
                try await self.fetchFromNetBoxAPI(resourceType: DeviceTypeResource.self)
            } : nil,
            entityName: "DeviceTypes"
        )
    }
    
    func getSiteGroups(siteGroupProperties: [SiteGroupProperties]? = nil) async throws {
        try await processEntities(
            properties: siteGroupProperties,
            operations: SiteGroupOperations(),
            apiFetcher: siteGroupProperties == nil ? {
                try await self.fetchFromNetBoxAPI(resourceType: SiteGroupResource.self)
            } : nil,
            entityName: "SiteGroups"
        )
    }
    
    func getSites(siteProperties: [SiteProperties]? = nil) async throws {
        try await processEntities(
            properties: siteProperties,
            operations: SiteOperations(),
            apiFetcher: siteProperties == nil ? {
                try await self.fetchFromNetBoxAPI(resourceType: SiteResource.self)
            } : nil,
            entityName: "Sites"
        )
    }
    
    func getRacks(rackProperties: [RackProperties]? = nil) async throws {
        try await processEntities(
            properties: rackProperties,
            operations: RackOperations(),
            apiFetcher: rackProperties == nil ? {
                try await self.fetchFromNetBoxAPI(resourceType: RackResource.self)
            } : nil,
            entityName: "Racks"
        )
    }
    
    func getDevices(deviceProperties: [DeviceProperties]? = nil) async throws {
        try await processEntities(
            properties: deviceProperties,
            operations: DeviceOperations(),
            apiFetcher: deviceProperties == nil ? {
                try await self.fetchFromNetBoxAPI(resourceType: DeviceResource.self)
            } : nil,
            entityName: "Devices"
        )
    }
    // MARK: - Helper Functions (preserved from original)
    
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
    
    // MARK: - Batch Operations
    func updateAllEntities() async throws {
        logger.info("Starting batch update of all entities")
        
        // Use structured concurrency for parallel processing
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.getTenantGroups() }
            group.addTask { try await self.getTenants() }
            group.addTask { try await self.getRegions() }
            group.addTask { try await self.getDeviceRoles() }
            group.addTask { try await self.getDeviceTypes() }
            group.addTask { try await self.getSiteGroups() }
            group.addTask { try await self.getSites() }
            
            // Wait for all tasks to complete
            for try await _ in group {}
        }
        
        logger.info("Completed batch update of all entities")
    }
    
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
        
        let deviceResource = DeviceResource(deviceProperties: properties, deviceId: properties.id)
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

// MARK: - Protocol for APIResource
protocol APIResourceProtocol {
    associatedtype ResultType
    init()
}

extension TenantGroupResource: APIResourceProtocol { typealias ResultType = [TenantGroupProperties] }
extension TenantResource: APIResourceProtocol { typealias ResultType = [TenantProperties] }
extension RegionResource: APIResourceProtocol { typealias ResultType = [RegionProperties] }
extension DeviceRoleResource: APIResourceProtocol { typealias ResultType = [DeviceRoleResource] }
extension DeviceTypeResource: APIResourceProtocol { typealias ResultType = [DeviceTypeProperties] }
extension SiteGroupResource: APIResourceProtocol { typealias ResultType = [SiteGroupProperties] }
extension SiteResource: APIResourceProtocol { typealias ResultType = [SiteProperties] }
extension RackResource: APIResourceProtocol { typealias ResultType = [RackProperties] }
extension DeviceResource: APIResourceProtocol { typealias ResultType = [DeviceProperties] }


