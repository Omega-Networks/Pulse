//
//  EventModal.swift
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

#if os(macOS)
struct EventModal: View {
    @State var event: Event
    
    @Environment(\.presentationMode) var presentationMode
    @State private var isHovering0: Bool = false
    @State private var isHovering1: Bool = false
    
    @State private var message: String = ""
    
    @State private var selectedScope = 0
    @State private var selectedSeverity = 0
    @State private var selectedSuppression = 0
    @State private var selectedDate = Date.now
    @State private var selectedDummy = 0
    
    @State private var isChangeSeverity = false
    @State private var isSuppress = false
    @State private var isUnsuppress = false
    @State private var isAcknowledge = false
    @State private var isUnacknowledge = false
    @State private var isCloseEvent = false
    
    @State private var selectedSuppressUntil = Date(timeIntervalSinceNow: 0)
    
    ///Example acknowledge event API from Zabbix
    ///{
    ///    "jsonrpc": "2.0",
    ///   "method": "event.acknowledge",
    ///    "params": {
    ///        "eventids": ["20427", "20428"],
    ///        "action": 12,
    ///        "message": "Maintenance required to fix it.",
    ///        "severity": 4
    ///    },
    ///    "id": 1
    ///}

    var body: some View {
        VStack (alignment: .leading) {
            Form {
                /// Event
                HStack {
                    Text("Event:")
                        .frame(width: 100, alignment: .trailing)
                    Text("\(event.name)")
                }
                .padding(.vertical, 1)
                .offset(x: -109)
                
                /// Message
                TextField("Message:", text: $message)
                    .lineLimit(10)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 553)
                    .padding(.vertical, 1)
                
                /// Scope
                Picker("Scope:", selection: $selectedScope) {
                    Text(" Only selected events").tag(0)
                    Text(" Selected and all other events of related triggers").tag(1)
                }
                .pickerStyle(.radioGroup)
                .padding(.vertical, 1)
                
                /// Change Severity
                Picker(selection: $selectedSeverity, label: Toggle("Change Severity:", isOn: $isChangeSeverity)) {
                    Text("Not Classified").tag(0)
                    Text("Information").tag(1)
                    Text("Warning").tag(2)
                    Text("Average").tag(3)
                    Text("High").tag(4)
                    Text("Disaster").tag(5)
                }
                .pickerStyle(.segmented)
                .frame(width: 600)
                .padding(.vertical, 1)
                .offset(x: 22)
                
                /// Suppress
                HStack {
                    Picker(selection: $selectedSuppression, label: Toggle("Suppress:", isOn: $isSuppress)) {
                        Text("Indefinitely").tag(0)
                        Text("Until").tag(1)
                    }
                    .onChange(of: isSuppress) { newValue, _ in
                        if newValue {
                            isUnsuppress = false
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 290)
                    
                    DatePicker(selection: $selectedDate, displayedComponents: [.date, .hourAndMinute], label: {})
                        .datePickerStyle(.field)
                        .disabled(selectedSuppression != 1)
                        .frame(width: 170)
                }
                .padding(.vertical, 1)
                .offset(x: 129.5)
                
                /// Close Event
                Picker(selection: $selectedDummy, label: Toggle("Close Event:", isOn: $isCloseEvent)) {
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 1)
                .offset(x: 22)
                
            }
            .padding(.trailing, 120)
            HStack {
                Spacer()
                
                /// Update
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("Update")
                        .frame(width: 80)
                        .foregroundColor(.white)
                }
                .onHover { isHovered in
                    self.isHovering0 = isHovered
                    DispatchQueue.main.async {
                        if (self.isHovering0) {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .background(Color.accentColor)
                .cornerRadius(5)
                
                /// Cancel
                Button {
                    presentationMode.wrappedValue.dismiss()
                } label: {
                    Text("Cancel")
                        .frame(width: 80)
                        .foregroundColor(.white)
                        .cornerRadius(5)
                }
                .onHover { isHovered in
                    self.isHovering1 = isHovered
                    DispatchQueue.main.async {
                        if (self.isHovering1) {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }

                .padding(.trailing, 15)
            }
            .padding(.top, 10)

        }
        .frame(minWidth: 700, maxWidth: 700, minHeight: 200, idealHeight: 300, maxHeight: 900)
        .padding(1)
    }
}

#Preview {
    UpdateModal(selectedEvents: [])
}
#endif
