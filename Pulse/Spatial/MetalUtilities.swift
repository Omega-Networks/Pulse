//
//  MetalUtilities.swift
//  Pulse
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
//  This program is free software: communities can deploy it for sovereignty, academia can
//  extend it for research, and industry can integrate it for resilience — all under the terms
//  of the GNU Affero General Public License version 3 as published by the Free Software Foundation.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Metal

// MARK: - Sendable Wrapper for Metal Types

/// A Sendable wrapper for MTLBuffer to comply with Swift 6 concurrency.
///
/// MTLBuffer is thread-safe for read access (per Metal Programming Guide: buffers can be shared concurrently if not modified).
/// This wrapper uses @unchecked Sendable to assert safety, isolating the unchecked conformance for maintainability.
///
/// For open-source contributors: This is a temporary bridge until Metal framework adopts Sendable annotations.
/// Remove wrapper once MTLBuffer conforms to Sendable (expected in future Swift versions).
public struct SendableBuffer: @unchecked Sendable {
    let buffer: MTLBuffer

    init(_ buffer: MTLBuffer) {
        self.buffer = buffer
    }

    /// Convenience accessors for kernel use
    var contents: UnsafeMutableRawPointer { buffer.contents() }
    var length: Int { buffer.length }
}