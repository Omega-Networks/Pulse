//
//  DeviceDetails.swift
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

struct DeviceDetails: View {
    var device: Device
    
    var body: some View {
        VStack {
            Form {
                HStack {
                    Text("Model:")
                        .font(.system(size: 12))
                    
                    Text("\(device.deviceType?.model ?? "Error")")
                        .font(.system(size: 12))
                }
                
                HStack {
                    Text("Serial:")
                        .font(.system(size: 12))
                    
                    Text("\(device.serial ?? "Error")")
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                    
                }
                
                HStack {
                    Text("IP:")
                        .font(.system(size: 12))
                    
                    Text("\(device.primaryIP ?? "Error")")
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                }
                
                HStack {
                    Text("Role:")
                        .font(.system(size: 12))
                    
                    Text("\(device.deviceRole?.name ?? "Error")")
                        .font(.system(size: 12))
                }
            }
        }
        .padding(.trailing, 50)
    }
}
