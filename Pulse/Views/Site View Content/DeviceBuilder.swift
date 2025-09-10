//
//  DeviceBuilder.swift
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

#if os(macOS)
struct DeviceBuilder: View {
    @Query(sort: \DeviceRole.name) private var deviceRoles: [DeviceRole]
    
    let columns: [GridItem] = Array(repeating: .init(.flexible()), count: 3)
    
    var body: some View {
        VStack {
            ScrollView {
                Text("Add A Device")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.top, 5)
                
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(deviceRoles) { deviceRole in
                        DeviceRoleView(deviceRole: deviceRole)
                    }
                }
                .padding()
            }
        }
    }
}

///New helper view for showing device role symbol and name
struct DeviceRoleView: View {
    let deviceRole: DeviceRole
    
    var body: some View {
        VStack {
            Image(symbolName(for: deviceRole))
                .font(.system(size: 40))
                .frame(width: 80, height: 80)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, .white)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(15)
                .padding(10)
            
            Text(deviceRole.name ?? "")
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .draggable(deviceRole.record)
    }
    
    func symbolName(for deviceRole: DeviceRole) -> String {
        switch deviceRole.name {
        case "Access Switch", "Distribution Switch", "Management Switch":
            return "custom.switch"
        case "Core Switch":
            return "custom.coreswitch"
        case "Security Router", "Core Firewall", "Management Firewall":
            return "custom.securityrouter"
        case "Access Point", "Wireless Bridge":
            return "custom.wirelessap"
        case "Camera":
            return "custom.camera"
        case "Router", "Terminal Server", "Provider Edge":
            return "custom.router"
        case "Certificate":
            return "custom.scroll.fill"
        case "Digital Display":
            return "custom.inset.filled.tv"
        case "EdgeAI":
            return "externaldrive.fill"
        default:
            return "custom.questionmark"
        }
    }
}

#Preview {
    DeviceBuilder()
        .modelContainer(for: DeviceRole.self, inMemory: true)
}
#endif
