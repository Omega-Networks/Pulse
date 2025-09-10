//
//  SearchBar.swift
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

import Foundation
import SwiftUI

#if os(tvOS)
#else

struct SearchBar: View {
    @Binding var text: String
    @State var isClearButtonClicked: Bool = false
    var onClear: (() -> Void)?

    var closeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                isClearButtonClicked = true
            }
            .onEnded { _ in
                isClearButtonClicked = false
                text = ""
                onClear?()
            }
    }
 
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.gray)

            TextField("Search Pulse", text: $text)
                .textFieldStyle(.plain)
                .onChange(of: text) {
                    if text.isEmpty {
                        onClear?()
                    }
                }

            Image(systemName: "xmark.circle.fill")
                .foregroundColor(isClearButtonClicked ? Color.gray.opacity(0.5) : .gray)
                .gesture(closeGesture)
                .font(.system(size: 14))
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

#endif
