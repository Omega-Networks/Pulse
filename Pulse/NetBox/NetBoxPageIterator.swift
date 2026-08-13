//
//  NetBoxPageIterator.swift
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

/// Iterative fetch-all over NetBox offset pages.
///
/// Lab-confirmed: default page is 50, `MAX_PAGE_SIZE` is 1000. We request
/// 1000 and advance `offset` by the number of rows actually returned.
/// A type's fetch is complete only when a page arrives with `next == nil`.
/// Transport or unexpected-status errors propagate; the caller must not
/// run the delete pass after a throw.
enum NetBoxPageIterator {
    static let pageLimit = 1000
    /// Safety brake against a `next` that never clears. 100 pages at
    /// `pageLimit` is 100_000 rows — well above today's boot set.
    static let maxPages = 100

    struct Page<Element: Sendable>: Sendable {
        var results: [Element]
        var next: String?
        var count: Int
    }

    enum IteratorError: Error, Equatable {
        /// A page returned `next` but zero results — cannot advance offset.
        case emptyPageWithNext
        /// More than `maxPages` arrived with `next` still set.
        case pageLimitExceeded
    }

    /// Materialize every page. Fine for small types (roles, tenants, …).
    static func fetchAll<Element: Sendable>(
        fetchPage: (Int) async throws -> Page<Element>
    ) async throws -> [Element] {
        var collected: [Element] = []
        try await forEachPage(fetchPage: fetchPage) { page in
            collected.append(contentsOf: page)
        }
        return collected
    }

    /// Stream each page into `body`. Use this for devices/services so the
    /// full list is never held just to walk it.
    /// GET every offset page through `NetBoxFetching` and the per-element
    /// list decoder. Shared by the boot engine and on-demand site loads.
    static func fetchDecoded<T: Decodable & Sendable>(
        path: String,
        extraQuery: [URLQueryItem] = [],
        as type: T.Type,
        using fetcher: any NetBoxFetching,
        maxPages: Int = NetBoxPageIterator.maxPages
    ) async throws -> (rows: [T], skipped: Int) {
        var skipped = 0
        var rows: [T] = []
        var offset = 0
        var pages = 0
        while true {
            pages += 1
            guard pages <= maxPages else { throw NetBoxSyncError.pageLimitExceeded }
            var query = extraQuery
            query.append(URLQueryItem(name: "limit", value: String(pageLimit)))
            query.append(URLQueryItem(name: "offset", value: String(offset)))
            let data = try await fetcher.get(path: path, query: query)
            let page = try NetBoxListDecoder.decodePage(T.self, from: data)
            skipped += page.skipped
            rows.append(contentsOf: page.results)
            guard page.next != nil else { break }
            guard !page.results.isEmpty else { throw NetBoxSyncError.emptyPageWithNext }
            offset += page.results.count
        }
        return (rows, skipped)
    }

    static func forEachPage<Element: Sendable>(
        fetchPage: (Int) async throws -> Page<Element>,
        maxPages: Int = NetBoxPageIterator.maxPages,
        body: ([Element]) async throws -> Void
    ) async throws {
        var offset = 0
        var pages = 0
        while true {
            pages += 1
            guard pages <= maxPages else { throw IteratorError.pageLimitExceeded }
            let page = try await fetchPage(offset)
            try await body(page.results)
            guard page.next != nil else { return }
            guard !page.results.isEmpty else { throw IteratorError.emptyPageWithNext }
            offset += page.results.count
        }
    }
}
