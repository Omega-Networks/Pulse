//
//  Rack.swift
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
import SwiftUI


//    TODO: Add status property
@Model
final class Rack {
    @Attribute(.unique) var id: Int64
    var created: Date?
    var display: String?
    var lastUpdated: Date?
    var name: String?
    var url: String?
    var uHeight: Int64?
    var startingUnit: Int64 = 1
    var deviceCount: Int64?
    var status: String?
    
    var site: Site?
    var formFactor: String?
    
    init(id: Int64) {
        self.id = id
    }
    
    @Relationship(deleteRule: .cascade, inverse: \Device.rack)
    var devices: [Device]?
}

// API For Rack
//{
//    "id": 1,
//    "url": "https://netbox.example.com/api/dcim/racks/1/",
//    "display_url": "https://netbox.example.com/dcim/racks/1/",
//    "display": "A.0.A.1",
//    "name": "A.0.A.1",
//    "facility_id": null,
//    "site": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/sites/1/",
//        "display": "001 - Museum",
//        "name": "001 - Museum",
//        "slug": "001-museum",
//        "description": "Museum"
//    },
//    "location": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/locations/1/",
//        "display": "FD - 0.a",
//        "name": "FD - 0.A",
//        "slug": "fd-0-a",
//        "description": "Ground floor",
//        "rack_count": 0,
//        "_depth": 2
//    },
//    "tenant": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/tenancy/tenants/1/",
//        "display": "Example",
//        "name": "Example",
//        "slug": "example",
//        "description": ""
//    },
//    "status": {
//        "value": "active",
//        "label": "Active"
//    },
//    "role": {
//        "id": 1,
//        "url": "https://netbox.example.com/api/dcim/rack-roles/1/",
//        "display": "Primary",
//        "name": "Primary",
//        "slug": "primary",
//        "description": "Primary Comms Rack"
//    },
//    "serial": "",
//    "asset_tag": null,
//    "rack_type": null,
//    "form_factor": null,
//    "width": {
//        "value": 19,
//        "label": "19 inches"
//    },
//    "u_height": 45,
//    "starting_unit": 1,
//    "weight": null,
//    "max_weight": null,
//    "weight_unit": null,
//    "desc_units": false,
//    "outer_width": null,
//    "outer_depth": null,
//    "outer_unit": null,
//    "mounting_depth": null,
//    "airflow": null,
//    "description": "",
//    "comments": "",
//    "tags": [],
//    "custom_fields": {},
//    "created": "2022-06-08T00:25:40.759962Z",
//    "last_updated": "2024-04-24T00:06:46.017955Z",
//    "device_count": 21,
//    "powerfeed_count": 0
//}

import OSLog
import Foundation

