//
//  EdgeView.swift
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
/// New EdgeView conforming to Swift 6 standards
struct EdgeView: View {
    var start: CGPoint
    var end: CGPoint
    @State private var isVisible = false
    
    var body: some View {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
        }
        .stroke(Color.primary, lineWidth: 1.69)
        .opacity(isVisible ? 1 : 0)
//        .animation(.easeInOut(duration: 0.5), value: isVisible)
        .onAppear {
            isVisible = true
        }
    }
}
