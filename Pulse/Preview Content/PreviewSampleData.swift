//
//  PreviewSampleData.swift
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
//  Abstract:
//  An actor that provides an in-memory model container for previews.
//

import Foundation
import SwiftUI
import SwiftData


/// An actor that provides an in-memory model container for previews.
actor PreviewSampleData {
    @MainActor
    static var container: ModelContainer = {
        return try! inMemoryContainer()
    }()

    @MainActor static var inMemoryContainer: () throws -> ModelContainer = {
        let schema = Schema([DeviceRole.self, DeviceType.self, Site.self, Device.self, Event.self])
//        let schema = Schema([TenantGroup.self, Tenant.self, Region.self, DeviceRole.self, DeviceType.self, SiteGroup.self, Site.self, Device.self, Interface.self, Problem.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        let sampleData: [any PersistentModel] = [
            Tenant.previewTenant,
            TenantGroup.previewTenantGroup,
            Region.previewRegion,
            DeviceRole.previewDeviceRole1,
            DeviceRole.previewDeviceRole2,
            DeviceRole.previewDeviceRole3,
            DeviceType.previewDeviceType1,
            DeviceType.previewDeviceType2,
            DeviceType.previewDeviceType3,
            SiteGroup.previewSiteGroup1,
//            SiteGroup.previewSiteGroup2,
            Site.previewSite1,
//            Site.previewSite2,
            Device.previewS1Device1,
            Device.previewS1Device2,
            Device.previewS1Device3,
            Device.previewS1Device4,
//            Device.previewS2Device1,
//            Device.previewS2Device2,
//            Device.previewS2Device3,
//            Device.previewS2Device4,
//            Interface.previewS1D1Interface1,
//            Interface.previewS1D1Interface2,
//            Interface.previewS1D1Interface3,
//            Interface.previewS1D2Interface1,
//            Interface.previewS1D2Interface2,
//            Interface.previewS1D2Interface3,
//            Interface.previewS1D2Interface4,
//            Interface.previewS1D3Interface1,
//            Interface.previewS1D4Interface1,
//            Interface.previewS2D1Interface1,
//            Interface.previewS2D1Interface2,
//            Interface.previewS2D1Interface3,
//            Interface.previewS2D2Interface1,
//            Interface.previewS2D2Interface2,
//            Interface.previewS2D2Interface3,
//            Interface.previewS2D2Interface4,
//            Interface.previewS2D3Interface1,
//            Interface.previewS2D4Interface1,
            Event.previewS1D1Event1,
            Event.previewS1D1Event2
//            Event.previewS1D2Event1
        ]
        Task { @MainActor in
            sampleData.forEach {
                container.mainContext.insert($0)
            }
            
            // Map Tenant to TenantGroup
//            let descriptorTenant = FetchDescriptor<Tenant>()
//            
//            if let existingTenants = try? container.mainContext.fetch(descriptorTenant) {
//                for tenant in existingTenants {
//                    
//                    let groupId: Int64 = Int64(1) // Force mapping to preview TenantGroup
//                    
//                    let predicate = #Predicate<TenantGroup> { tenantGroup in
//                        tenantGroup.id == groupId
//                    }
//                    
//                    let descriptorTenantGroup = FetchDescriptor(predicate: predicate)
//                    
//                    if let tenantGroup = try? container.mainContext.fetch(descriptorTenantGroup).first {
//                        tenant.group = tenantGroup
//                        print("tenant mapped to tenantGroup")
//                    }
//                }
//            }
            
            // Map Site to Site Group
//            let descriptorSite = FetchDescriptor<Site>()
//            
//            if let existingSites = try? container.mainContext.fetch(descriptorSite) {
//                var groupId: Int64 = Int64(1) // Force mapping to preview TenantGroup
//                for site in existingSites {
//                    
//                    let predicate = #Predicate<SiteGroup> { siteGroup in
//                        siteGroup.id == groupId
//                    }
//                    
//                    let descriptorSiteGroup = FetchDescriptor(predicate: predicate)
//                    
//                    if let siteGroup = try? container.mainContext.fetch(descriptorSiteGroup).first {
//                        site.group = siteGroup
//                        print("site mapped to siteGroup")
//                    }
//                    groupId += 1
//                }
//            }
            
            // Map Device to Site
            let descriptorDevice = FetchDescriptor<Device>()
            
            if let existingDevices = try? container.mainContext.fetch(descriptorDevice) {
                var siteId: Int64 = Int64(1) // Force mapping to preview Site
                var deviceRoleId: Int64 = Int64(1) // Force mapping to preview DeviceRole
                for device in existingDevices {
                    
                    let deviceName = device.name ?? "Error"
                    
                    let predicate = #Predicate<Site> { site in
                        site.id == siteId
                    }
                    
                    let descriptorSite = FetchDescriptor(predicate: predicate)
                    
                    if let site = try? container.mainContext.fetch(descriptorSite).first {
                        device.site = site
                        print("device mapped to site")
                    }
                    
                    let predicateEventId = device.zabbixId
                    
                    let predicateEvent = #Predicate<Event> { event in
                        event.hostId == predicateEventId
                    }
                    
                    let descriptorEvent = FetchDescriptor(predicate: predicateEvent)
                    
                    if let events = try? container.mainContext.fetch(descriptorEvent) {
                        for event in events {
                            event.device = device
                            print("Event mapped to site")
                        }
                    }
                    
                    if deviceName.contains("SR") {
                        deviceRoleId = 3
                    } else if deviceName.contains("SW") {
                        deviceRoleId = 2
                    } else if deviceName.contains("SC") {
                        deviceRoleId = 11
                    } else {
                        deviceRoleId = 1
                    }
                    
                    let predicateDeviceRole = #Predicate<DeviceRole> { deviceRole in
                        deviceRole.id == deviceRoleId
                    }
                    
                    let descriptorDeviceRole = FetchDescriptor(predicate: predicateDeviceRole)
                    
                    if let deviceRole = try? container.mainContext.fetch(descriptorDeviceRole).first {
                        device.deviceRole = deviceRole
                        print("device mapped to deviceRole")
                    }
//                    groupId += 1
                }

            }
            print("SavingContext")
            try container.mainContext.save()
            print("Context ready for preview")
        }
        return container
    }
}


extension TenantGroup {
    static var previewTenantGroup: TenantGroup {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = TenantGroup(id: 1)
        preview.name = "Preview TenantGroup"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
//        preview.tenants = nil  // Assigning empty array here
        return preview
    }
}

extension Tenant {
    static var previewTenant: Tenant {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = Tenant(id: 1)
        preview.name = "Preview Tenant"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
//        preview.group = nil  // Assigning empty array here
        return preview
    }
}

extension Region {
    static var previewRegion: Region {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = Region(id: 1)
        preview.name = "Preview Region"
        preview.siteCount = 2
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        preview.parent = nil  // Assigning nil here
        return preview
    }
}

extension DeviceRole {
    static var previewDeviceRole1: DeviceRole {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = DeviceRole(id: 3)
        preview.name = "Security Router"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        return preview
    }
    static var previewDeviceRole2: DeviceRole {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = DeviceRole(id: 2)
        preview.name = "Access Switch"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        return preview
    }
    static var previewDeviceRole3: DeviceRole {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = DeviceRole(id: 11)
        preview.name = "Camera"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        return preview
    }
}

extension DeviceType {
    static var previewDeviceType1: DeviceType {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = DeviceType(id: 1)
        preview.model = "Preview Firewall"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        return preview
    }
    static var previewDeviceType2: DeviceType {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = DeviceType(id: 2)
        preview.model = "Preview Switch"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        return preview
    }
    static var previewDeviceType3: DeviceType {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = DeviceType(id: 3)
        preview.model = "Preview Security Camera"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        return preview
    }
}

extension SiteGroup {
    static var previewSiteGroup1: SiteGroup {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = SiteGroup(id: 1)
        preview.name = "Preview SiteGroup 1"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        return preview
    }
//    static var previewSiteGroup2: SiteGroup {
//        let dateFormatter = DateFormatter()
//        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
//        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
//        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
//        
//        let preview = SiteGroup(id: 2)
//        preview.name = "Preview SiteGroup 2"
//        preview.created = createdDate
//        preview.lastUpdated = lastUpdatedDate
//        return preview
//    }
}

extension Site {
    static var previewSite1: Site {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = Site(id: 1)
        preview.name = "Preview Site 1"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        preview.longitude = -41.32894
        preview.latitude = 174.81180
        preview.physicalAddress = "Terminal, Wellington, 6022,New Zealand"
        preview.shippingAddress = "Terminal, Wellington, 6022,New Zealand"
        preview.display = "Preview Site 1"
        preview.deviceCount = 4
        return preview
    }
//    static var previewSite2: Site {
//        let dateFormatter = DateFormatter()
//        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
//        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
//        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
//        
//        let preview = Site(id: 2)
//        preview.name = "Preview Site 2"
//        preview.created = createdDate
//        preview.lastUpdated = lastUpdatedDate
//        preview.longitude = -41.13933
//        preview.latitude = 175.03862
//        preview.physicalAddress = "10 Racecourse Rd, Trentham, Upper Hutt 5018, New Zealand"
//        preview.shippingAddress = "Terminal, Wellington 6022 ,New Zealand"
//        preview.display = "Preview Site 2"
//        preview.deviceCount = 4
//        return preview
//    }
}

extension Device {
    static var previewS1Device1: Device {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = Device(id: 1)
        preview.name = "PRE-S1-SR01"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        preview.primaryIP = "1.1.1.1/32"
        preview.serial = "SN_PREV-SITE1-SR01"
        preview.x = 220
        preview.y = 350
        preview.zabbixId = 10418
        preview.display = "PRE-S1-SR01"
        return preview
    }
    static var previewS1Device2: Device {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = Device(id: 2)
        preview.name = "PRE-S1-SW01"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        preview.primaryIP = "1.1.1.2/32"
        preview.serial = "SN_PREV-SITE1-SW01"
        preview.x = 520
        preview.y = 350
        preview.zabbixId = 10417
        preview.display = "PRE-S1-SW01"
        return preview
    }
    static var previewS1Device3: Device {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = Device(id: 3)
        preview.name = "PRE-S1-SC01"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        preview.primaryIP = "1.1.1.3/32"
        preview.serial = "SN_PREV-SITE1-SC01"
        preview.x = 820
        preview.y = 280
        preview.zabbixId = 10424
        preview.display = "PRE-S1-SC01"
        return preview
    }
    static var previewS1Device4: Device {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let createdDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        let lastUpdatedDate = dateFormatter.date(from: "2022-06-07 04:02:38 +0000")
        
        let preview = Device(id: 4)
        preview.name = "PRE-S1-SC02"
        preview.created = createdDate
        preview.lastUpdated = lastUpdatedDate
        preview.primaryIP = "1.1.1.4/32"
        preview.serial = "SN_PREV-SITE1-SC02"
        preview.x = 820
        preview.y = 420
        preview.zabbixId = 10419
        preview.display = "PRE-S1-SC02"
        return preview
    }
}

extension Event {
    static var previewS1D1Event1: Event {
        
        let preview = Event(eventId: "1")
        preview.acknowledged = "1"
        preview.clock = "2022-06-07 04:02:38 +0000"
        preview.value = "1"
        preview.name = "Preview Event 1"
        preview.severity = "4"
        preview.object = ""
        preview.objectId = ""
        preview.rClock = "2022-06-07 04:02:38 +0000"
        preview.opData = "We can do this!"
        preview.source = ""
        preview.suppressed = ""
        preview.hostId = 10418
        return preview
    }
    
    static var previewS1D1Event2: Event {
        
        let preview = Event(eventId: "2")
        preview.acknowledged = "0"
        preview.clock = "2022-06-07 04:02:38 +0000"
        preview.value = "1"
        preview.name = "Preview Event 2"
        preview.severity = "2"
        preview.object = ""
        preview.objectId = ""
        preview.rClock = "2022-06-07 04:02:38 +0000"
        preview.opData = "Keep on going."
        preview.source = ""
        preview.suppressed = ""
        preview.hostId = 10418
        return preview
    }
}
