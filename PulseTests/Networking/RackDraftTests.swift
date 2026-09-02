//
//  RackDraftTests.swift
//  PulseTests
//
//  Copyright © 2025–present Omega Networks Limited.
//
//  This program is distributed to enable communities to build and maintain their own
//  digital sovereignty through local control of critical infrastructure data.
//
//  By open sourcing Pulse, we create a circular economy where contributors can both build
//  upon and benefit from the platform, ensuring that value flows back to communities rather
//  than being extracted by external entities. This aligns with our commitment to intergenerational
//  prosperity through collaborative stewardship of public infrastructure.
//
//  Under the terms of the GNU Affero General Public License version 3 as published by the
//  Free Software Foundation, this program is free software: communities can deploy it for
//  sovereignty, academia can extend it for research, and industry can integrate it for resilience.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import XCTest
@testable import Pulse

final class RackDraftTests: XCTestCase {
    func testOverlapAndOutOfBoundsAreConflicts() {
        let store = [
            RackPlacement(deviceID: 1, rackID: 10, position: 10, face: "front", uHeight: 2),
        ]
        let draft = RackDraft()
        let overlap = RackPlacement(deviceID: 2, rackID: 10, position: 11, face: "front", uHeight: 1)
        XCTAssertTrue(RackOccupancy.conflicts(candidate: overlap, store: store, draft: draft, rackHeight: 45))

        let clear = RackPlacement(deviceID: 2, rackID: 10, position: 20, face: "front", uHeight: 1)
        XCTAssertFalse(RackOccupancy.conflicts(candidate: clear, store: store, draft: draft, rackHeight: 45))

        let tooHigh = RackPlacement(deviceID: 2, rackID: 10, position: 45, face: "front", uHeight: 2)
        XCTAssertTrue(RackOccupancy.conflicts(candidate: tooHigh, store: store, draft: draft, rackHeight: 45))
    }

    func testDraftMoveFreesTheOldUs() {
        var draft = RackDraft()
        draft.place(RackPlacement(deviceID: 1, rackID: 10, position: 30, face: "front", uHeight: 2))
        let store = [
            RackPlacement(deviceID: 1, rackID: 10, position: 10, face: "front", uHeight: 2),
        ]
        let intoOldSlot = RackPlacement(deviceID: 2, rackID: 10, position: 10, face: "front", uHeight: 2)
        XCTAssertFalse(RackOccupancy.conflicts(candidate: intoOldSlot, store: store, draft: draft, rackHeight: 45))
    }

    func testUndoRestoresPreviousPlacement() {
        var draft = RackDraft()
        draft.place(RackPlacement(deviceID: 1, rackID: 10, position: 5, face: "front", uHeight: 1))
        draft.place(RackPlacement(deviceID: 1, rackID: 10, position: 8, face: "front", uHeight: 1))
        XCTAssertEqual(draft.placements[1]?.position, 8)
        draft.undo()
        XCTAssertEqual(draft.placements[1]?.position, 5)
        draft.undo()
        XCTAssertTrue(draft.placements.isEmpty)
    }

    func testSameUOnOppositeFacesDoesNotConflict() {
        let store = [
            RackPlacement(deviceID: 1, rackID: 10, position: 10, face: "front", uHeight: 1),
        ]
        let rear = RackPlacement(deviceID: 2, rackID: 10, position: 10, face: "rear", uHeight: 1)
        XCTAssertFalse(
            RackOccupancy.conflicts(candidate: rear, store: store, draft: RackDraft(), rackHeight: 45)
        )
        let front = RackPlacement(deviceID: 2, rackID: 10, position: 10, face: "front", uHeight: 1)
        XCTAssertTrue(
            RackOccupancy.conflicts(candidate: front, store: store, draft: RackDraft(), rackHeight: 45)
        )
    }

    func testUnrackedPlacementNeverConflicts() {
        let store = [
            RackPlacement(deviceID: 1, rackID: 10, position: 10, face: "front", uHeight: 1),
        ]
        let unracked = RackPlacement(
            deviceID: 1,
            rackID: RackOccupancy.unrackedID,
            position: 0,
            face: "front",
            uHeight: 1
        )
        XCTAssertFalse(
            RackOccupancy.conflicts(candidate: unracked, store: store, draft: RackDraft(), rackHeight: 45)
        )
    }

    func testHalfUOccupiesOnlyItsInterval() {
        let store = [
            RackPlacement(deviceID: 1, rackID: 10, position: 10, face: "front", uHeight: 0.5),
        ]
        let overlap = RackPlacement(deviceID: 2, rackID: 10, position: 10, face: "front", uHeight: 0.5)
        XCTAssertTrue(
            RackOccupancy.conflicts(candidate: overlap, store: store, draft: RackDraft(), rackHeight: 45)
        )
        let neighbour = RackPlacement(deviceID: 2, rackID: 10, position: 10.5, face: "front", uHeight: 0.5)
        XCTAssertFalse(
            RackOccupancy.conflicts(candidate: neighbour, store: store, draft: RackDraft(), rackHeight: 45)
        )
    }

    func testEIA310RatiosMatchTheStandard() {
        XCTAssertEqual(EIA310.ruInches, 1.75)
        XCTAssertEqual(EIA310.panelWidthInches, 19)
        XCTAssertEqual(EIA310.chassisWidthInches, 17.75)
        XCTAssertEqual(EIA310.earInches, 0.625, accuracy: 0.0001)
        XCTAssertEqual(EIA310.holeOffsetsInches, [0.25, 0.875, 1.50])
        XCTAssertEqual(
            EIA310.panelWidth,
            EIA310.chassisWidth + 2 * EIA310.earWidth,
            accuracy: 0.001
        )
        let top = EIA310.yOffset(position: 42, uHeight: 1, rackHeight: 42, pointsPerInch: 10)
        XCTAssertEqual(top, 0, accuracy: 0.001)
        let half = EIA310.yOffset(position: 42, uHeight: 0.5, rackHeight: 42, pointsPerInch: 10)
        XCTAssertEqual(half, EIA310.unitHeight(pointsPerInch: 10) / 2, accuracy: 0.001)
        XCTAssertEqual(
            EIA310.position(y: 0, rackHeight: 42, pointsPerInch: 10, uHeight: 1),
            42
        )
        let ru = EIA310.unitHeight(pointsPerInch: 10)
        XCTAssertEqual(
            EIA310.position(y: ru * 0.75, rackHeight: 42, pointsPerInch: 10, uHeight: 1),
            42
        )
        XCTAssertEqual(
            EIA310.position(y: ru, rackHeight: 42, pointsPerInch: 10, uHeight: 1),
            41
        )
    }

    func testPortNamesSortNumerically() {
        let names = ["10", "2", "1", "24", "Port 12", "Port 3", "Gi0/11", "Gi0/2"]
        let sorted = names.enumerated().sorted { lhs, rhs in
            PortNameOrder.lessThan(lhs.element, id: Int64(lhs.offset), rhs.element, id: Int64(rhs.offset))
        }.map(\.element)
        XCTAssertEqual(sorted, ["1", "2", "Gi0/2", "Port 3", "10", "Gi0/11", "Port 12", "24"])
    }

    func testFaceplateLabelUsesTrailingPortNumber() {
        XCTAssertEqual(PortNameOrder.faceplateLabel("7/1", fallback: 99), "1")
        XCTAssertEqual(PortNameOrder.faceplateLabel("7/12", fallback: 99), "12")
        XCTAssertEqual(PortNameOrder.faceplateLabel("Port 24", fallback: 99), "24")
        XCTAssertEqual(PortNameOrder.faceplateLabel("12", fallback: 99), "12")
        XCTAssertEqual(PortNameOrder.faceplateLabel("", fallback: 3), "3")
    }

    func testPortNamesTieBreakOnStemThenID() {
        XCTAssertTrue(PortNameOrder.lessThan("Gi0/1", id: 2, "Te0/1", id: 1))
        XCTAssertTrue(PortNameOrder.lessThan("1", id: 5, "1", id: 9))
        XCTAssertTrue(PortNameOrder.lessThan("12", id: 1, "A", id: 2))
    }
}
