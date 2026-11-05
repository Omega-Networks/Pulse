//
//  ProblemUpdateForm.swift
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

/// Zabbix's Update problem dialog. macOS lays the rows out in a grid:
/// the label column is the width of its labels, and the control column is
/// the width of the severity segments. A fixed sheet width clipped both.
/// iOS uses the grouped form. The controls are the same.
struct ProblemUpdateForm: View {
    @Binding var draft: ProblemUpdateDraft
    var eventTitle: String
    var showsAcknowledge: Bool
    var showsUnacknowledge: Bool
    var showsUnsuppress: Bool
    var onUpdate: () -> Void
    var onCancel: () -> Void

    /// What the segments show. Unchecking clears the draft and leaves these,
    /// so checking again sends the same pick. A change of either writes the
    /// draft, which is what checks the box.
    @State private var shownSeverity: Int
    @State private var shownSuppression: Int
    @State private var pickedUntil: Date

    init(
        draft: Binding<ProblemUpdateDraft>,
        eventTitle: String,
        showsAcknowledge: Bool,
        showsUnacknowledge: Bool,
        showsUnsuppress: Bool,
        onUpdate: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = draft
        self.eventTitle = eventTitle
        self.showsAcknowledge = showsAcknowledge
        self.showsUnacknowledge = showsUnacknowledge
        self.showsUnsuppress = showsUnsuppress
        self.onUpdate = onUpdate
        self.onCancel = onCancel
        _shownSeverity = State(initialValue: draft.wrappedValue.severity ?? 0)
        switch draft.wrappedValue.suppression {
        case .until(let date):
            _shownSuppression = State(initialValue: 1)
            _pickedUntil = State(initialValue: date)
        case .indefinitely, .none:
            _shownSuppression = State(initialValue: 0)
            _pickedUntil = State(initialValue: .now.addingTimeInterval(3600))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update problem")
                .font(.title2)
                .fontWeight(.bold)
            fields
            buttons
        }
        .padding(20)
        #if os(macOS)
        .fixedSize(horizontal: true, vertical: false)
        #endif
    }

    /// Wide enough for Not classified through Disaster at the system size.
    /// The sheet takes this plus the label column, so neither is clipped.
    private var controlWidth: CGFloat { 620 }

    private var fields: some View {
        #if os(macOS)
        macOSFields
        #else
        iOSFields
        #endif
    }

    private var macOSFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                rowLabel("Problem")
                Text(eventTitle)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(width: controlWidth, alignment: .leading)
            }
            GridRow(alignment: .top) {
                rowLabel("Message")
                    .padding(.top, 5)
                TextField("Message", text: $draft.message, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: controlWidth)
            }
            GridRow {
                checkbox("Change severity", isOn: changesSeverity)
                severityPicker
                    .frame(width: controlWidth)
            }
            GridRow {
                checkbox("Suppress", isOn: suppresses)
                HStack(spacing: 8) {
                    Picker("", selection: suppressionMode) {
                        Text("Indefinitely").tag(0)
                        Text("Until").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    DatePicker("", selection: untilDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .disabled(shownSuppression != 1)
                }
                .frame(width: controlWidth, alignment: .leading)
            }
            if showsUnsuppress {
                GridRow {
                    checkbox("Unsuppress", isOn: unsuppresses)
                    controlGap
                }
            }
            if showsAcknowledge {
                GridRow {
                    checkbox("Acknowledge", isOn: acknowledges)
                    controlGap
                }
            }
            if showsUnacknowledge {
                GridRow {
                    checkbox("Unacknowledge", isOn: unacknowledges)
                    controlGap
                }
            }
            GridRow {
                checkbox("Close problem", isOn: $draft.closes)
                controlGap
            }
        }
    }

    private var iOSFields: some View {
        Form {
            LabeledContent("Problem") {
                Text(eventTitle)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            TextField("Message", text: $draft.message, axis: .vertical)
                .lineLimit(3...6)
            Toggle("Change severity", isOn: changesSeverity)
            severityPicker
            Toggle("Suppress", isOn: suppresses)
            Picker("Suppression", selection: suppressionMode) {
                Text("Indefinitely").tag(0)
                Text("Until").tag(1)
            }
            .pickerStyle(.segmented)
            DatePicker("Until", selection: untilDate, displayedComponents: [.date, .hourAndMinute])
                .disabled(shownSuppression != 1)
            if showsUnsuppress {
                Toggle("Unsuppress", isOn: unsuppresses)
            }
            if showsAcknowledge {
                Toggle("Acknowledge", isOn: acknowledges)
            }
            if showsUnacknowledge {
                Toggle("Unacknowledge", isOn: unacknowledges)
            }
            Toggle("Close problem", isOn: $draft.closes)
        }
        .formStyle(.grouped)
    }

    private var severityPicker: some View {
        Picker("Severity", selection: severitySelection) {
            severityOptions
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var controlGap: some View {
        Color.clear
            .frame(width: controlWidth, height: 0)
            .accessibilityHidden(true)
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .gridColumnAlignment(.trailing)
    }

    private var buttons: some View {
        HStack {
            if let reason = draft.invalidReason {
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .pointingHand()
            Button("Update", action: onUpdate)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
                .pointingHand(when: draft.isValid)
        }
    }

    private func checkbox(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif
            .gridColumnAlignment(.trailing)
    }

    @ViewBuilder
    private var severityOptions: some View {
        Text("Not classified").tag(0)
        Text("Information").tag(1)
        Text("Warning").tag(2)
        Text("Average").tag(3)
        Text("High").tag(4)
        Text("Disaster").tag(5)
    }

    private var changesSeverity: Binding<Bool> {
        Binding(
            get: { draft.severity != nil },
            set: { on in
                draft.severity = on ? shownSeverity : nil
            }
        )
    }

    private var severitySelection: Binding<Int> {
        Binding(
            get: { shownSeverity },
            set: { value in
                shownSeverity = value
                draft.severity = value
            }
        )
    }

    private var suppresses: Binding<Bool> {
        Binding(
            get: { draft.suppression != .none },
            set: { on in
                if on {
                    draft.unsuppresses = false
                    draft.suppression = shownSuppression == 1 ? .until(pickedUntil) : .indefinitely
                } else {
                    draft.suppression = .none
                }
            }
        )
    }

    private var suppressionMode: Binding<Int> {
        Binding(
            get: { shownSuppression },
            set: { mode in
                shownSuppression = mode
                draft.unsuppresses = false
                if mode == 0 {
                    draft.suppression = .indefinitely
                } else {
                    draft.suppression = .until(pickedUntil)
                }
            }
        )
    }

    private var untilDate: Binding<Date> {
        Binding(
            get: { pickedUntil },
            set: { date in
                pickedUntil = date
                guard shownSuppression == 1 else { return }
                draft.unsuppresses = false
                draft.suppression = .until(date)
            }
        )
    }

    private var unsuppresses: Binding<Bool> {
        Binding(
            get: { draft.unsuppresses },
            set: { on in
                draft.unsuppresses = on
                if on { draft.suppression = .none }
            }
        )
    }

    private var acknowledges: Binding<Bool> {
        Binding(
            get: { draft.acknowledges },
            set: { on in
                draft.acknowledges = on
                if on { draft.unacknowledges = false }
            }
        )
    }

    private var unacknowledges: Binding<Bool> {
        Binding(
            get: { draft.unacknowledges },
            set: { on in
                draft.unacknowledges = on
                if on { draft.acknowledges = false }
            }
        )
    }
}
