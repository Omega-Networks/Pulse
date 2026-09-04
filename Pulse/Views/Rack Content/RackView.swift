//
//  RackView.swift
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
import UniformTypeIdentifiers
#if os (macOS)
import AppKit
#endif

//Global corner radius
let rackCornerRadius: CGFloat = 8
let rackUnitCornerRadius: CGFloat = 5

struct RackView: View {
    @Environment(RackEditSession.self) private var rackEdit
    @Environment(LicenseSeatStore.self) private var seats
    @Environment(RolePresentationStore.self) private var rolePresentation
    var site: Site
    var pointsPerInch: CGFloat = EIA310.pointsPerInch

    private var racks: [Rack] {
        (site.racks ?? [])
            .filter { $0.status != "deprecated" }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            HStack(alignment: .top, spacing: 28) {
                ForEach(racks) { rack in
                    SingleRackView(site: site, rack: rack, pointsPerInch: pointsPerInch)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.topLeading)
        .task(id: rackEdit.draggingDeviceID) {
            await RackEditActions.clearHoverWhenMouseReleased(session: rackEdit)
        }
        .dropDestination(for: String.self) { items, _ in
            RackEditActions.unrack(
                items: items,
                site: site,
                session: rackEdit,
                seats: seats,
                presentation: rolePresentation.presentation
            )
        }
    }
}

struct SingleRackView: View {
    @Environment(RolePresentationStore.self) private var rolePresentation
    @Environment(RackEditSession.self) private var rackEdit
    @Environment(LicenseSeatStore.self) private var seats
    var site: Site
    let rack: Rack
    var pointsPerInch: CGFloat = EIA310.pointsPerInch
    @State private var visibleFace = "front"

    private var rackHeight: Int { max(1, Int(rack.uHeight ?? 45)) }
    private var ruHeight: CGFloat { EIA310.unitHeight(pointsPerInch: pointsPerInch) }
    private var panelWidth: CGFloat { EIA310.panelWidth(pointsPerInch: pointsPerInch) }
    private var chassisWidth: CGFloat { EIA310.chassisWidth(pointsPerInch: pointsPerInch) }
    private var earWidth: CGFloat { EIA310.earWidth(pointsPerInch: pointsPerInch) }
    private var elevationHeight: CGFloat { ruHeight * CGFloat(rackHeight) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(rack.name ?? "Unnamed Rack")
                    .font(.headline)
                    .lineLimit(1)
                Picker("Face", selection: $visibleFace) {
                    Text("Front").tag("front")
                    Text("Rear").tag("rear")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 140)
                .labelsHidden()
            }

            HStack(alignment: .top, spacing: 4) {
                unitLabels
                elevation
            }
            .onDrop(of: [.plainText, .utf8PlainText, .text], delegate: RackElevationDropDelegate(
                rack: rack,
                site: site,
                pointsPerInch: pointsPerInch,
                session: rackEdit,
                seats: seats,
                presentation: rolePresentation.presentation,
                face: visibleFace
            ))
        }
    }

    private var unitLabels: some View {
        VStack(spacing: 0) {
            ForEach((1...rackHeight).reversed(), id: \.self) { unit in
                Text("\(unit)")
                    .font(.system(size: min(11, ruHeight * 0.55)))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: ruHeight, alignment: .trailing)
            }
        }
    }

    private var elevation: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                RackEarRail(unitCount: rackHeight, pointsPerInch: pointsPerInch)
                chassisBackground
                RackEarRail(unitCount: rackHeight, pointsPerInch: pointsPerInch)
            }

            ForEach(occupants) { occupant in
                placed(occupant)
                    .opacity(rackEdit.draggingDeviceID == occupant.device.id ? 0.4 : 1)
            }

            if rackEdit.isEditing {
                ForEach(emptyUnits, id: \.self) { unit in
                    if !hoverCovers(unit) {
                        emptySlot(unit: unit)
                    }
                }
            }

            if let hover = rackEdit.hover,
               hover.rackID == rack.id,
               RackOccupancy.normalizedFace(hover.face) == visibleFace {
                hoverHighlight(hover)
            }
        }
        .frame(width: panelWidth, height: elevationHeight)
        .clipShape(RoundedRectangle(cornerRadius: rackCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: rackCornerRadius)
                .stroke(Color.gray, lineWidth: 1)
        )
    }

    private var chassisBackground: some View {
        VStack(spacing: 0) {
            ForEach(0..<rackHeight, id: \.self) { _ in
                Rectangle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: chassisWidth, height: ruHeight)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.gray.opacity(0.25))
                            .frame(height: 0.5)
                    }
            }
        }
        .frame(width: chassisWidth, height: elevationHeight)
    }

    private func hoverCovers(_ unit: Int) -> Bool {
        guard let hover = rackEdit.hover, hover.rackID == rack.id,
              RackOccupancy.normalizedFace(hover.face) == visibleFace,
              let span = RackOccupancy.interval(position: hover.position, uHeight: hover.uHeight) else {
            return false
        }
        return span.overlaps(Float(unit)..<(Float(unit) + 1))
    }

    private var emptyUnits: [Int] {
        (1...rackHeight).filter { unit in
            let slot = Float(unit)..<(Float(unit) + 1)
            return !occupants.contains { occupant in
                guard let span = RackOccupancy.interval(
                    position: occupant.position,
                    uHeight: occupant.uHeight
                ) else { return false }
                return span.overlaps(slot)
            }
        }
    }

    private func emptySlot(unit: Int) -> some View {
        let y = EIA310.yOffset(
            position: Float(unit),
            uHeight: 1,
            rackHeight: rackHeight,
            pointsPerInch: pointsPerInch
        )
        return Button {
            rackEdit.addTarget = RackMountTarget(
                rackID: rack.id,
                position: Float(unit),
                face: visibleFace
            )
        } label: {
            ZStack {
                Color.clear
                Text("Add")
                    .font(.system(size: min(11, ruHeight * 0.45)))
                    .foregroundStyle(.secondary)
            }
            .frame(width: chassisWidth, height: ruHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: earWidth, y: y)
        .help("Add a device at U \(unit)")
    }

    @ViewBuilder
    private func placed(_ occupant: RackOccupant) -> some View {
        let height = EIA310.height(units: CGFloat(occupant.uHeight), pointsPerInch: pointsPerInch)
        let y = EIA310.yOffset(
            position: occupant.position,
            uHeight: occupant.uHeight,
            rackHeight: rackHeight,
            pointsPerInch: pointsPerInch
        )
        occupantFace(occupant.device, height: height, fullWidth: occupant.isFiller)
            .opacity(canEdit(occupant) ? 1 : 0.45)
            .offset(x: occupant.isFiller ? 0 : earWidth, y: y)
            .rackDeviceDrag(
                id: occupant.device.id,
                enabled: rackEdit.isEditing && canEdit(occupant),
                session: rackEdit
            )
            .contextMenu {
                if rackEdit.isEditing, canEdit(occupant) {
                    Button(visibleFace == "front" ? "Move to rear" : "Move to front") {
                        flipFace(occupant)
                    }
                }
            }
    }

    private func canEdit(_ occupant: RackOccupant) -> Bool {
        seats.allowsRackEdit(
            deviceID: occupant.device.id,
            roleID: occupant.device.deviceRole?.id,
            presentation: rolePresentation.presentation
        )
    }

    private func flipFace(_ occupant: RackOccupant) {
        guard canEdit(occupant) else {
            rackEdit.status = BillingError.deviceNotSeated.localizedDescription
            return
        }
        let next = visibleFace == "front" ? "rear" : "front"
        let placement = RackPlacement(
            deviceID: occupant.device.id,
            rackID: rack.id,
            position: occupant.position,
            face: next,
            uHeight: occupant.uHeight
        )
        let store = RackEditActions.storePlacements(site: site, rackID: rack.id)
        if RackOccupancy.conflicts(
            candidate: placement,
            store: store,
            draft: rackEdit.draft,
            rackHeight: rackHeight
        ) {
            rackEdit.status = "U \(RackEditActions.formatU(occupant.position)) on the \(next) is occupied."
            return
        }
        rackEdit.draft.place(placement)
        rackEdit.status = "Moved \(occupant.device.name ?? "device") to the \(next)."
    }

    private func hoverHighlight(_ hover: RackHoverPreview) -> some View {
        let height = EIA310.height(units: CGFloat(hover.uHeight), pointsPerInch: pointsPerInch)
        let y = EIA310.yOffset(
            position: hover.position,
            uHeight: hover.uHeight,
            rackHeight: rackHeight,
            pointsPerInch: pointsPerInch
        )
        let tint = hover.isValid ? Color.accentColor : Color.red
        return RoundedRectangle(cornerRadius: rackUnitCornerRadius)
            .fill(tint.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: rackUnitCornerRadius)
                    .stroke(tint, lineWidth: 2)
            )
            .frame(width: chassisWidth, height: height)
            .offset(x: earWidth, y: y)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func occupantFace(_ device: Device, height: CGFloat, fullWidth: Bool) -> some View {
        if fullWidth {
            FillerInRackView(device: device, unitHeight: height, rackWidth: panelWidth)
        } else {
            DeviceInRackView(device: device, unitHeight: height, rackWidth: chassisWidth)
        }
    }

    private var occupants: [RackOccupant] {
        let presentation = rolePresentation.presentation
        var rows: [Int64: (device: Device, position: Float)] = [:]
        for device in site.devices ?? [] {
            if let moved = rackEdit.draft.placements[device.id], moved.rackID != rack.id {
                continue
            }
            let persistedHere = device.rack?.id == rack.id
            let draftedHere = rackEdit.draft.placements[device.id]?.rackID == rack.id
            guard persistedHere || draftedHere else { continue }
            let position = rackEdit.draft.placements[device.id]?.position ?? device.rackPosition
            guard let position, position > 0 else { continue }
            rows[device.id] = (device, position)
        }
        for placement in rackEdit.draft.placements.values where placement.rackID == rack.id {
            guard let device = site.devices?.first(where: { $0.id == placement.deviceID }) else {
                continue
            }
            rows[placement.deviceID] = (device, placement.position)
        }
        return rows.values.compactMap { row in
            let policy = presentation.policy(for: row.device.deviceRole?.id)
            guard policy.showInRack else { return nil }
            let draft = rackEdit.draft.placements[row.device.id]
            let face = RackOccupancy.normalizedFace(draft?.face ?? row.device.face ?? "front")
            guard face == visibleFace else { return nil }
            let uHeight = draft?.uHeight
                ?? max(0.5, row.device.deviceType?.uHeight ?? 1)
            return RackOccupant(
                device: row.device,
                position: row.position,
                uHeight: uHeight,
                isFiller: row.device.isRackFiller(in: presentation)
            )
        }
        .sorted { $0.position > $1.position }
    }
}

private struct RackOccupant: Identifiable {
    var id: Int64 { device.id }
    let device: Device
    let position: Float
    let uHeight: Float
    let isFiller: Bool
}

private struct RackEarRail: View {
    let unitCount: Int
    let pointsPerInch: CGFloat

    var body: some View {
        let ru = EIA310.unitHeight(pointsPerInch: pointsPerInch)
        let width = EIA310.earWidth(pointsPerInch: pointsPerInch)
        let hole = max(2, 0.22 * pointsPerInch)
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color(white: 0.16))
            ForEach(0..<unitCount, id: \.self) { index in
                ForEach(Array(EIA310.holeOffsetsInches.enumerated()), id: \.offset) { _, inches in
                    Circle()
                        .fill(Color.black.opacity(0.7))
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.4))
                        .frame(width: hole, height: hole)
                        .position(
                            x: width / 2,
                            y: CGFloat(index) * ru + inches * pointsPerInch
                        )
                }
            }
        }
        .frame(width: width, height: ru * CGFloat(unitCount))
    }
}

enum RackEditActions {
    @MainActor
    @discardableResult
    static func unrack(
        items: [String],
        site: Site,
        session: RackEditSession,
        seats: LicenseSeatStore,
        presentation: RolePresentation
    ) -> Bool {
        guard session.isEditing, let raw = items.first, let deviceID = Int64(raw) else {
            return false
        }
        guard let device = site.devices?.first(where: { $0.id == deviceID }) else {
            return false
        }
        return unrack(device: device, session: session, seats: seats, presentation: presentation)
    }

    @MainActor
    static func unrack(
        device: Device,
        session: RackEditSession,
        seats: LicenseSeatStore,
        presentation: RolePresentation
    ) -> Bool {
        guard session.isEditing else { return false }
        guard seats.allowsRackEdit(
            deviceID: device.id,
            roleID: device.deviceRole?.id,
            presentation: presentation
        ) else {
            session.status = BillingError.deviceNotSeated.localizedDescription
            session.endDrag()
            return false
        }
        let current = session.draft.placements[device.id]?.rackID
            ?? device.rack?.id
            ?? RackOccupancy.unrackedID
        guard current != RackOccupancy.unrackedID else { return false }
        session.draft.place(
            RackPlacement(
                deviceID: device.id,
                rackID: RackOccupancy.unrackedID,
                position: 0,
                face: device.face ?? "front",
                uHeight: max(0.5, device.deviceType?.uHeight ?? 1)
            )
        )
        session.status = "Removed \(device.name ?? "device") from the rack."
        session.endDrag()
        return true
    }

    @MainActor
    static func place(
        device: Device,
        on rack: Rack,
        at position: Float,
        site: Site,
        session: RackEditSession,
        seats: LicenseSeatStore,
        presentation: RolePresentation,
        face: String? = nil
    ) -> Bool {
        guard seats.allowsRackEdit(
            deviceID: device.id,
            roleID: device.deviceRole?.id,
            presentation: presentation
        ) else {
            session.status = BillingError.deviceNotSeated.localizedDescription
            session.endDrag()
            return false
        }
        let rackHeight = max(1, Int(rack.uHeight ?? 45))
        let uHeight = max(0.5, device.deviceType?.uHeight ?? 1)
        let placement = RackPlacement(
            deviceID: device.id,
            rackID: rack.id,
            position: position,
            face: face ?? device.face ?? "front",
            uHeight: uHeight
        )
        let store = storePlacements(site: site, rackID: rack.id)
        if RackOccupancy.conflicts(
            candidate: placement,
            store: store,
            draft: session.draft,
            rackHeight: rackHeight
        ) {
            session.status = "U \(formatU(position)) is occupied or out of range."
            return false
        }
        session.draft.place(placement)
        session.status = "Placed \(device.name ?? "device") at U \(formatU(position))."
        session.endDrag()
        return true
    }

    static func storePlacements(site: Site, rackID: Int64) -> [RackPlacement] {
        (site.devices ?? []).compactMap { device in
            guard device.rack?.id == rackID, let position = device.rackPosition else {
                return nil
            }
            return RackPlacement(
                deviceID: device.id,
                rackID: rackID,
                position: position,
                face: device.face ?? "front",
                uHeight: max(0.5, device.deviceType?.uHeight ?? 1)
            )
        }
    }

    /// `.draggable` custom previews do not tell us when the session
    /// ends. Poll the mouse button so a cancelled lift cannot leave
    /// a blue/red hover on the elevation.
    @MainActor
    static func clearHoverWhenMouseReleased(session: RackEditSession) async {
        guard session.draggingDeviceID != nil else { return }
        let id = session.draggingDeviceID
        #if os(macOS)
        while !Task.isCancelled, session.draggingDeviceID == id {
            try? await Task.sleep(for: .milliseconds(50))
            if NSEvent.pressedMouseButtons & 1 == 0 {
                if session.draggingDeviceID == id {
                    session.endDrag()
                }
                return
            }
        }
        #endif
    }

    static func formatU(_ value: Float) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}

private struct RackElevationDropDelegate: DropDelegate {
    let rack: Rack
    let site: Site
    let pointsPerInch: CGFloat
    let session: RackEditSession
    let seats: LicenseSeatStore
    let presentation: RolePresentation
    var face: String = "front"

    func validateDrop(info: DropInfo) -> Bool {
        session.isEditing && !session.isSaving
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard session.isEditing, !session.isSaving else { return nil }
        resolveDeviceID(from: info)
        updateHover(at: info.location)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if session.hover?.rackID == rack.id {
            session.hover = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard session.isEditing, !session.isSaving else { return false }
        resolveDeviceID(from: info)
        guard let deviceID = session.draggingDeviceID
                ?? session.hover?.deviceID,
              let device = site.devices?.first(where: { $0.id == deviceID }) else {
            session.status = "That device is not at this site."
            session.endDrag()
            return true
        }
        let uHeight = max(0.5, device.deviceType?.uHeight ?? 1)
        let position = EIA310.position(
            y: info.location.y,
            rackHeight: max(1, Int(rack.uHeight ?? 45)),
            pointsPerInch: pointsPerInch,
            uHeight: uHeight
        )
        if !RackEditActions.place(
            device: device,
            on: rack,
            at: position,
            site: site,
            session: session,
            seats: seats,
            presentation: presentation,
            face: face
        ) {
            session.hover = nil
        }
        return true
    }

    private func updateHover(at location: CGPoint) {
        guard let deviceID = session.draggingDeviceID
                ?? session.hover?.deviceID,
              let device = site.devices?.first(where: { $0.id == deviceID }) else {
            return
        }
        let rackHeight = max(1, Int(rack.uHeight ?? 45))
        let uHeight = max(0.5, device.deviceType?.uHeight ?? 1)
        let position = EIA310.position(
            y: location.y,
            rackHeight: rackHeight,
            pointsPerInch: pointsPerInch,
            uHeight: uHeight
        )
        let candidate = RackPlacement(
            deviceID: device.id,
            rackID: rack.id,
            position: position,
            face: face,
            uHeight: uHeight
        )
        let valid = !RackOccupancy.conflicts(
            candidate: candidate,
            store: RackEditActions.storePlacements(site: site, rackID: rack.id),
            draft: session.draft,
            rackHeight: rackHeight
        )
        let next = RackHoverPreview(
            deviceID: device.id,
            rackID: rack.id,
            position: position,
            uHeight: uHeight,
            face: face,
            isValid: valid
        )
        if session.hover != next {
            session.hover = next
        }
    }

    private func resolveDeviceID(from info: DropInfo) {
        if session.draggingDeviceID != nil { return }
        let types: [UTType] = [.plainText, .utf8PlainText, .text]
        guard let provider = info.itemProviders(for: types).first else { return }
        let location = info.location
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let raw: String?
            if let string = item as? String {
                raw = string
            } else if let data = item as? Data {
                raw = String(data: data, encoding: .utf8)
            } else {
                raw = nil
            }
            guard let raw,
                  let id = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return
            }
            DispatchQueue.main.async {
                session.draggingDeviceID = id
                updateHover(at: location)
            }
        }
    }
}

#if os(macOS)
private extension View {
    @ViewBuilder
    func rackDeviceDrag(
        id: Int64,
        enabled: Bool,
        session: RackEditSession
    ) -> some View {
        if enabled {
            // Snapshot the occupant from its frame so the lift grows
            // under the pointer. A custom preview is hosted at the
            // window origin and flies down from the top of the screen.
            self.onDrag {
                session.beginDrag(id: id)
                return NSItemProvider(object: NSString(string: String(id)))
            }
        } else {
            self
        }
    }
}
#else
private extension View {
    @ViewBuilder
    func rackDeviceDrag(
        id: Int64,
        enabled: Bool,
        session: RackEditSession
    ) -> some View {
        self
    }
}
#endif
