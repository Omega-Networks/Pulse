//
//  RackDraft.swift
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
import Observation

/// One device's intended rack mount. Not written to SwiftData.
struct RackPlacement: Equatable, Sendable {
    var deviceID: Int64
    var rackID: Int64
    var position: Float
    var face: String
    var uHeight: Float
}

/// Session-local rack edits. Save PATCHes NetBox; Undo/Cancel do not.
struct RackDraft: Equatable, Sendable {
    var placements: [Int64: RackPlacement] = [:]
    private var history: [[Int64: RackPlacement]] = []

    var isDirty: Bool { !placements.isEmpty }
    var canUndo: Bool { !history.isEmpty }

    mutating func place(_ placement: RackPlacement) {
        history.append(placements)
        placements[placement.deviceID] = placement
    }

    mutating func undo() {
        guard let previous = history.popLast() else { return }
        placements = previous
    }

    mutating func reset() {
        placements = [:]
        history = []
    }
}

enum RackOccupancy {
    /// Unracked draft rows use rackID 0.
    static let unrackedID: Int64 = 0

    /// Half-open U interval [position, position+uHeight).
    static func interval(position: Float, uHeight: Float) -> Range<Float>? {
        let height = max(0.5, uHeight)
        guard position >= 1 else { return nil }
        return position..<(position + height)
    }

    /// True when `candidate` overlaps another occupant of the same rack.
    static func conflicts(
        candidate: RackPlacement,
        store: [RackPlacement],
        draft: RackDraft,
        rackHeight: Int
    ) -> Bool {
        if candidate.rackID == unrackedID { return false }
        guard let wanted = interval(position: candidate.position, uHeight: candidate.uHeight),
              wanted.lowerBound >= 1,
              wanted.upperBound - 0.001 <= Float(rackHeight) + 1 else {
            return true
        }
        if wanted.upperBound - 1 > Float(rackHeight) { return true }
        var occupants: [Int64: RackPlacement] = [:]
        for row in store where row.rackID == candidate.rackID {
            occupants[row.deviceID] = row
        }
        for (id, row) in draft.placements {
            if row.rackID == candidate.rackID {
                occupants[id] = row
            } else {
                occupants.removeValue(forKey: id)
            }
        }
        occupants.removeValue(forKey: candidate.deviceID)
        let wantedFace = normalizedFace(candidate.face)
        for other in occupants.values {
            guard normalizedFace(other.face) == wantedFace else { continue }
            guard let existing = interval(position: other.position, uHeight: other.uHeight) else {
                continue
            }
            if wanted.overlaps(existing) { return true }
        }
        return false
    }

    static func normalizedFace(_ face: String) -> String {
        face == "rear" ? "rear" : "front"
    }
}

/// Clicked empty U waiting for an add.
struct RackMountTarget: Equatable, Sendable {
    var rackID: Int64
    var position: Float
    var face: String
}

/// Live drop target while a device is dragged over a rack.
struct RackHoverPreview: Equatable, Sendable {
    var deviceID: Int64
    var rackID: Int64
    var position: Float
    var uHeight: Float
    var face: String
    var isValid: Bool
}

/// Site-scoped rack surface. Lives in the SwiftUI environment.
/// Drag is armed only while `isEditing` is true (pencil next to +).
@Observable
final class RackEditSession {
    /// True while the Rack View tab is on screen.
    var isOpen = false
    /// Pencil: drag, drop, and unrack are allowed only in this mode.
    var isEditing = false
    var draft = RackDraft()
    var status: String?
    var isSaving = false
    var draggingDeviceID: Int64?
    var hover: RackHoverPreview?
    var addTarget: RackMountTarget?
    /// When true, the add sheet is the clean New Device form.
    var addCreatesDevice = false

    func begin() {
        isEditing = true
        status = nil
        addTarget = nil
        addCreatesDevice = false
        endDrag()
    }

    func beginDrag(id: Int64) {
        draggingDeviceID = id
    }

    func cancel() {
        draft.reset()
        status = nil
        isEditing = false
        addTarget = nil
        addCreatesDevice = false
        endDrag()
    }

    func undo() {
        draft.undo()
        status = nil
    }

    func endDrag() {
        draggingDeviceID = nil
        hover = nil
    }
}
