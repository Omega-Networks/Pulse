//
//  SiteLeftPane.swift
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

/**
 A preference key for tracking the width of views in the hierarchy.
 
 This preference key is used as part of a system to measure and propagate
 view widths up through the view hierarchy. It enables dynamic sizing
 of container views based on their content.
 */
struct WidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Width Measuring Modifier

/**
 A view modifier that measures the width of its content view.
 
 This modifier uses GeometryReader to measure its content's width and
 propagates that measurement through the view hierarchy using the
 WidthPreferenceKey preference key.
 */
struct MeasureWidthModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: WidthPreferenceKey.self,
                    value: geometry.size.width
                )
            }
        )
    }
}

/**
 Extends View to provide a convenient method for measuring width.
 
 This extension makes it easy to apply the MeasureWidthModifier to any view
 in the hierarchy using a simple function call.
 
 Example usage:
 ```
 Text("Hello World")
     .measureWidth()
 ```
 */
extension View {
    /// Adds width measurement functionality to the view
    func measureWidth() -> some View {
        modifier(MeasureWidthModifier())
    }
}
