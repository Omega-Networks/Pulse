//
//  NetBoxPageIterator.swift
//  Pulse
//
//  Copyright © 2025–present Omega Networks Limited.
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

    struct Page<Element: Sendable>: Sendable {
        var results: [Element]
        var next: String?
        var count: Int
    }

    enum IteratorError: Error, Equatable {
        /// A page returned `next` but zero results — cannot advance offset.
        case emptyPageWithNext
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
        using fetcher: any NetBoxFetching
    ) async throws -> (rows: [T], skipped: Int) {
        var skipped = 0
        var rows: [T] = []
        var offset = 0
        while true {
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
        body: ([Element]) async throws -> Void
    ) async throws {
        var offset = 0
        while true {
            let page = try await fetchPage(offset)
            try await body(page.results)
            guard page.next != nil else { return }
            guard !page.results.isEmpty else { throw IteratorError.emptyPageWithNext }
            offset += page.results.count
        }
    }
}
