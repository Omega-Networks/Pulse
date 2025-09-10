//
//  TimeCell.swift
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

struct TimeCell: View {
    @State var event: Event
    @State private var isHovering: Bool = false
    @State private var isShowingSheet: Bool = false
    
    var body: some View {
        Text(event.formattedClock)
            .foregroundColor(isHovering ? Color.blue : Color.primary)
            .underline()
        // TODO: Develop TimeCell to show Event Details
            .onTapGesture {
                // Disabled for now.. unsure how this will look as we don't have trigger data. Maybe hold in memory?
//                isShowingSheet = true
            }
//            .onHover { isHovered in
//                self.isHovering = isHovered
//                #if os(macOS)
//                DispatchQueue.main.async { //<-- Here
//                    if (self.isHovering) {
//                        NSCursor.pointingHand.push()
//                    } else {
//                        NSCursor.pop()
//                    }
//                }
//                #endif
//            }
        #if os(macOS)
            .sheet(isPresented: $isShowingSheet) {
                EventModal(event: event)
            }
        #endif
    }
}

//#Preview {
//    TimeCell()
//}
