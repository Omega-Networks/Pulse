//
//  TableToolbar.swift
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

struct TableToolbar: View {
    @State private var isShowingSheet: Bool = false
    @State private var isHovering: Bool = false
    var selectedEvents: [Event]
    var events: [Event]
    
    var body: some View {
        HStack {
            Text("\(selectedEvents.count) Selected")
                .padding(.leading, 10)
                .padding(.bottom, 10)
            
            /// Update
            Button {
                isShowingSheet = true
            } label: {
                Text("Update")
            }
            .disabled(selectedEvents.count == 0)
            .onHover { isHovered in
                if selectedEvents.count != 0 {
                    self.isHovering = isHovered
                    #if os(macOS)
                    DispatchQueue.main.async {
                        if (self.isHovering) {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    #endif
                }
            }
            .padding(.leading, 10)
            .padding(.bottom, 10)
//            #if os(macOS)
            .sheet(isPresented: $isShowingSheet) {
                UpdateModal(selectedEvents: selectedEvents)
            }
//            #endif
            
            Spacer()
            
            Text("\(events.count) \(events.count == 1 ? "Event" : "Event")")// You need to pass `events` as a property or a binding
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }.frame(height: 20)
    }
}

#Preview {
    TableToolbar(selectedEvents: [], events: [])
}
