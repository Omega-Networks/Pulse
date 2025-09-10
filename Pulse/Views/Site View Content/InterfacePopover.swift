//
//  InterfacePopover.swift
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

struct InterfacePopover: View {
    @Environment(\.modelContext) private var modelContext
    @State var interface: Interface
    private var squareSize: CGFloat = 15
    private var verticalPadding: CGFloat = 5
    
    public init(interface: Interface) {
        self._interface = State(initialValue: interface)
    }
    
    var body: some View {
        VStack {
            Form {
                HStack {
                    Text("Interface")
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    
                    Label {
                        Text(interface.name)
                    } icon: {
                        Image(systemName: "square")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: squareSize, height: squareSize)
                            .foregroundColor(Color.gray)
                        
                    }
                }
                .padding(.vertical, verticalPadding)
            
                HStack {
                    Text("Port Speed")
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    Text(interface.speed ?? "N/A")
                }
                .padding(.vertical, verticalPadding)
                
//                HStack {
//                    Text("Connected Endpoint Device") //TODO: Change it to either uplink or downlink depending on relationship
//                        .foregroundColor(.gray)
//                    
//                    Spacer()
//                    
//                    Label {
//                        Text(interface.connectedEndpointX?.device?.name ?? "N/A")
//                    } icon: {
//                        if interface.connectedEndpointX?.device != nil {
//                            Image(interface.connectedEndpointX?.device?.symbolName ?? "")
//                                .resizable()
//                                .aspectRatio(contentMode: .fit)
//                                .frame(width: self.squareSize, height: self.squareSize)
//                                .foregroundColor(.primary)
//                                .background(.black)
//                        } else {
//                            Image(systemName: "")
//                                .resizable()
//                                .aspectRatio(contentMode: .fit)
//                                .frame(width: self.squareSize, height: self.squareSize)
//                                .foregroundColor(.clear)
//                        }
//                    }
//                    
//                }
//                .padding(.vertical, verticalPadding)
                
                HStack {
                    Text("Connected Endpoint")
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
//                    Text(interface.connectedEndpointX?.name ?? "N/A")
                }
                .padding(.vertical, verticalPadding)
                
                HStack {
                    Text("Type")
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    Label {
                        Text(interface.name)
                    } icon: {
                        Image(systemName: "square")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: squareSize, height: squareSize)
                    }
                }
                .padding(.vertical, verticalPadding)
            }
        }
        .padding(20)
        .frame(width: 400, height: 250)
    }
}

//#Preview {
//    InterfacePopover(interfaceId: 0)
//}
