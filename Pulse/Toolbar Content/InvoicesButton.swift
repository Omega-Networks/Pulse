//
//  InvoicesButton.swift
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

struct InvoicesButton: View {
    @Environment(\.openWindow) var openWindow
    //Binding property for opening the popover
    @Binding var openInvoices: Bool
    
    var body: some View {
        Button(action: {
            openInvoices.toggle()
        }) {
            Image(systemName: "document.fill")
                .fontWeight(.bold)
        }
        .popover(isPresented: $openInvoices, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                Button {
                    openWindow(id: "create-invoices")
                } label: {
                    Label("Create Invoices", systemImage: "document.badge.plus.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(10)
                
                Divider()
                
                Button {
                    openWindow(id: "view-invoices")
                } label: {
                    Label("View Invoices", systemImage: "document.badge.ellipsis.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(PlainButtonStyle())
                .padding(10)
            }
            .frame(width: 250)
        }
    }
}

#Preview {
    InvoicesButton(openInvoices: .constant(false))
}
