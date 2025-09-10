//
//  Cable.swift
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

import SwiftUI
import SwiftData

///API For Cable
///{
///"id": 1,
///"url": "https://netbox.example.com/api/dcim/cables/1/",
///"display": "#1",
///"type": "cat6a",
///"a_terminations": [
///    {
///        "object_type": "dcim.interface",
///        "object_id": 1,
///        "object": {
///            "id": 1,
///            "url": "https://netbox.example.com/api/dcim/interfaces/1/",
///            "display": "Example",
///            "device": {
///                "id": 1,
///                "url": "https://netbox.example.com/api/dcim/devices/1/",
///                "display": "Example",
///                "name": "Example"
///            },
///            "name": "GigabitEthernet1/0",
///            "cable": 1,
///            "_occupied": true
///        }
///    }
///],
///"b_terminations": [
///    {
///        "object_type": "dcim.interface",
///        "object_id": 1,
///        "object": {
///            "id": 1,
///            "url": "https://netbox.example.com/api/dcim/interfaces/1/",
///            "display": "Example",
///            "device": {
///                "id": 1,
///                "url": "https:/netbox.example.com/api/dcim/devices/1/",
///                "display": "Example",
///                "name": "Example"
///            },
///            "name": "Example",
///            "cable": 1,
///            "_occupied": true
///        }
///    }
///],
///"status": {
///    "value": "connected",
///    "label": "Connected"
///},
///"tenant": {
///    "id": 1,
///    "url": "https://netbox.example.com/api/tenancy/tenants/1/",
///    "display": "Example",
///    "name": "Example",
///    "slug": "example"
///},
///"label": "",
///"color": "",
///"length": null,
///"length_unit": null,
///"description": "",
///"comments": "",
///"tags": [],
///"custom_fields": {},
///"created": "2022-10-12T23:25:22.874457Z",
///"last_updated": "2022-10-12T23:25:22.874472Z"
///}

//TODO: Build CableProperties for POST request to NetBox
struct CableProperties: Codable {
    
    // MARK: - Coding Keys
    enum CodingKeys: String, CodingKey {
        case id, url, display, type, a_terminations, b_terminations, status, tenant, label, color, length, length_unit, description, comments, tags, custom_fields, created, last_updated
    }
    
    // MARK: - Properties
    let id: Int?
    let url: String?
    let display: String?
    let type: String // Make this non-optional
    var a_terminations: [Termination]
    var b_terminations: [Termination]
    var status: String // Changed to String
    
    // MARK: - Nested Structs
    struct Termination: Codable {
        let object_type: String
        let object_id: Int
    }
    
    // MARK: - Initializers
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try? container.decode(Int.self, forKey: .id)
        url = try? container.decode(String.self, forKey: .url)
        display = try? container.decode(String.self, forKey: .display)
        type = try container.decode(String.self, forKey: .type) // Make this non-optional
        
        a_terminations = try container.decode([Termination].self, forKey: .a_terminations)
        b_terminations = try container.decode([Termination].self, forKey: .b_terminations)
        
        status = try container.decode(String.self, forKey: .status) // Changed to String
    }
    
    init(interfaceA: Interface, interfaceB: Interface, statusValue: String, typeValue: String) {
        self.id = nil
        self.url = nil
        self.display = nil
        self.type = typeValue // Set the type
        
        self.a_terminations = [Termination(object_type: "dcim.interface", object_id: Int(interfaceA.id))]
        self.b_terminations = [Termination(object_type: "dcim.interface", object_id: Int(interfaceB.id))]
        
        self.status = statusValue // Set the status
    }
    
    // MARK: - Encoding
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(id, forKey: .id)
        try container.encode(url, forKey: .url)
        try container.encode(display, forKey: .display)
        try container.encode(type, forKey: .type)
        
        try container.encode(a_terminations, forKey: .a_terminations)
        try container.encode(b_terminations, forKey: .b_terminations)
        
        try container.encode(status, forKey: .status)
    }
}


