//
//  GridView.swift
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

struct GridLayerView: View {
    private let grid: CGFloat = 10
    private let width: CGFloat = 5000
    private let height: CGFloat = 5000
    
    var body: some View {
        ZStack {
            GridLines(grid: grid, width: width, height: height, lineWidth: 0.2)
                .opacity(0.3)
            
            GridLines(grid: (grid*5), width: width, height: height, lineWidth: 0.5)
                .opacity(0.3)
        }
    }
}

struct GridLines: View {
    let grid: CGFloat
    let width: CGFloat
    let height: CGFloat
    let lineWidth: CGFloat
    
    private var startWidth: CGFloat {
        ceil(width / grid) * grid
    }
    
    private var startHeight: CGFloat {
        ceil(height / grid) * grid
    }
    
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                // Draw horizontal grid lines
                for i in stride(from: -startWidth, through: height, by: grid) {
                    path.move(to: CGPoint(x: -startWidth, y: i))
                    path.addLine(to: CGPoint(x: width, y: i))
                }
                
                // Draw vertical grid lines
                for i in stride(from: -startHeight, through: width, by: grid) {
                    path.move(to: CGPoint(x: i, y: -startHeight))
                    path.addLine(to: CGPoint(x: i, y: height))
                }
            }
            .stroke(Color.gray, lineWidth: lineWidth)
        }
    }
}

struct GridLayerView_Previews: PreviewProvider {
    static var previews: some View {
        GridLayerView()
    }
}


#Preview  {
        GridLayerView()
}
