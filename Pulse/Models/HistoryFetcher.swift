//
//  HistoryFetcherActor.swift
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
import OSLog

struct HistoryFetcher {
    private let logger = Logger(subsystem: "zabbix", category: "history")
    /// Trend buckets are one hour. A shorter window stays on history.get.
    private let hourlyTrendMinimum: TimeInterval = 30 * 60

    func getHistories(itemId: String, selectedPeriod: String, valueType: String) async -> [Date: String] {
        guard let historyType = Int(valueType) else {
            logger.error("Item \(itemId, privacy: .public) has no history table (value type \(valueType, privacy: .public))")
            return [:]
        }
        let (desiredTimeFrom, timeTill) = chartTimeWindow(for: selectedPeriod)
        guard historyType == 0 || historyType == 3 else {
            return await fetchPlain(itemId: itemId, from: desiredTimeFrom, until: timeTill, historyType: historyType)
        }
        let start = desiredTimeFrom.timeIntervalSince1970
        let end = timeTill.timeIntervalSince1970
        let store = HistorySeriesStore.shared
        let plan = await store.plan(itemId: itemId, valueType: historyType, from: start, to: end)
        do {
            let rows = try await rows(
                for: plan,
                itemId: itemId,
                historyType: historyType,
                from: desiredTimeFrom,
                until: timeTill,
                start: start,
                end: end
            )
            logger.debug("Completed getHistories for item \(itemId, privacy: .public) points=\(rows.count, privacy: .public)")
            return rows
        } catch {
            if Task.isCancelled { return [:] }
            logger.error("Failed to fetch histories for item \(itemId, privacy: .public). Error: \(error.localizedDescription, privacy: .public)")
            await publishFetchFailure(error)
            return await store.overlap(itemId: itemId, valueType: historyType, from: start, to: end) ?? [:]
        }
    }

    /// The chart keeps the stored overlap. The notice says the tail may be stale.
    private func publishFetchFailure(_ error: Error) async {
        let status = ZabbixError.status(from: error)
        await MainActor.run {
            RequestStatusManager.shared.updateStatus(.zabbix, status)
            if let notice = OperatorNotice.fromZabbix(status) {
                OperatorNoticeCenter.shared.post(notice)
            }
        }
    }

    private func rows(
        for plan: HistoryReadPlan,
        itemId: String,
        historyType: Int,
        from startDate: Date,
        until endDate: Date,
        start: Double,
        end: Double
    ) async throws -> [Date: String] {
        let store = HistorySeriesStore.shared
        switch plan {
        case .serve:
            return await store.serve(itemId: itemId, valueType: historyType, from: start, to: end)
        case .load:
            let loaded = try await loadSeries(itemId: itemId, historyType: historyType, from: startDate, until: endDate, start: start, end: end)
            return await store.commit(loaded, itemId: itemId, valueType: historyType, from: start, to: end)
        case .older(let until):
            return try await extendOlder(
                itemId: itemId, historyType: historyType,
                from: startDate, until: endDate, start: start, end: end, olderUntil: until
            )
        case .newer(let since, let kind):
            return try await extendNewer(
                itemId: itemId, historyType: historyType, kind: kind,
                from: startDate, until: endDate, start: start, end: end, since: since
            )
        case .both(let until, _, _):
            _ = try await extendOlder(
                itemId: itemId, historyType: historyType,
                from: startDate, until: endDate, start: start, end: end, olderUntil: until
            )
            let again = await store.plan(itemId: itemId, valueType: historyType, from: start, to: end)
            if case .newer(let since, let kind) = again {
                return try await extendNewer(
                    itemId: itemId, historyType: historyType, kind: kind,
                    from: startDate, until: endDate, start: start, end: end, since: since
                )
            }
            return await store.serve(itemId: itemId, valueType: historyType, from: start, to: end)
        }
    }

    /// Raw samples stay a raw series. An empty older gap on a long window becomes hourly averages for the whole window.
    private func extendOlder(
        itemId: String,
        historyType: Int,
        from startDate: Date,
        until endDate: Date,
        start: Double,
        end: Double,
        olderUntil: Double
    ) async throws -> [Date: String] {
        let store = HistorySeriesStore.shared
        let kind = await store.kind(itemId: itemId, valueType: historyType)
        if kind == .trend {
            let trends = try await fetchTrendPage(itemId: itemId, from: startDate, until: Date(timeIntervalSince1970: olderUntil))
            if trends.points.isEmpty {
                return await store.noteQuietOlder(itemId: itemId, valueType: historyType, from: start, to: end)
            }
            return await store.commitOlder(
                trends.points, truncated: trends.truncated,
                itemId: itemId, valueType: historyType, from: start, to: end
            )
        }
        let olderRows = try await fetchHistoryPage(itemId: itemId, from: startDate, until: Date(timeIntervalSince1970: olderUntil), historyType: historyType)
        if olderRows.points.isEmpty, fallsBackToHourlyTrends(historyType: historyType, from: startDate, until: endDate) {
            let replacement = try await trendSeries(itemId: itemId, from: startDate, until: endDate, start: start, end: end)
            return await store.commit(replacement, itemId: itemId, valueType: historyType, from: start, to: end)
        }
        if olderRows.points.isEmpty {
            return await store.noteQuietOlder(itemId: itemId, valueType: historyType, from: start, to: end)
        }
        return await store.commitOlder(
            olderRows.points, truncated: olderRows.truncated,
            itemId: itemId, valueType: historyType, from: start, to: end
        )
    }

    private func extendNewer(
        itemId: String,
        historyType: Int,
        kind: HistorySeries.Kind,
        from startDate: Date,
        until endDate: Date,
        start: Double,
        end: Double,
        since: Double
    ) async throws -> [Date: String] {
        let store = HistorySeriesStore.shared
        let sinceDate = Date(timeIntervalSince1970: since)
        let page: HistoryPage
        if kind == .trend {
            page = try await fetchTrendPage(itemId: itemId, from: sinceDate, until: endDate)
        } else {
            page = try await fetchHistoryPage(itemId: itemId, from: sinceDate, until: endDate, historyType: historyType)
        }
        if page.points.isEmpty {
            return await store.noteQuietNewer(itemId: itemId, valueType: historyType, from: start, end: end)
        }
        return await store.commitNewer(
            page.points, truncated: page.truncated,
            itemId: itemId, valueType: historyType, from: start, requestedEnd: end
        )
    }

    private func loadSeries(
        itemId: String,
        historyType: Int,
        from startDate: Date,
        until endDate: Date,
        start: Double,
        end: Double
    ) async throws -> HistorySeries {
        let history = try await fetchHistoryPage(itemId: itemId, from: startDate, until: endDate, historyType: historyType)
        if history.points.isEmpty, fallsBackToHourlyTrends(historyType: historyType, from: startDate, until: endDate) {
            logger.debug("History empty for item \(itemId, privacy: .public); using hourly trends")
            return try await trendSeries(itemId: itemId, from: startDate, until: endDate, start: start, end: end)
        }
        return HistorySeries.loaded(history.points, kind: .history, requestedStart: start, requestedEnd: end, truncated: history.truncated)
    }

    private func trendSeries(itemId: String, from startDate: Date, until endDate: Date, start: Double, end: Double) async throws -> HistorySeries {
        let trends = try await fetchTrendPage(itemId: itemId, from: startDate, until: endDate)
        return HistorySeries.loaded(trends.points, kind: .trend, requestedStart: start, requestedEnd: end, truncated: trends.truncated)
    }

    private func fetchPlain(itemId: String, from startDate: Date, until endDate: Date, historyType: Int) async -> [Date: String] {
        do {
            return try await fetchHistoryData(itemId: itemId, timeFrom: startDate, timeTill: endDate, historyType: historyType)
        } catch {
            if Task.isCancelled { return [:] }
            logger.error("Failed to fetch histories for item \(itemId, privacy: .public). Error: \(error.localizedDescription, privacy: .public)")
            await publishFetchFailure(error)
            return [:]
        }
    }

    private func fetchHistoryPage(itemId: String, from startDate: Date, until endDate: Date, historyType: Int) async throws -> HistoryPage {
        let rows = try await fetchHistories(itemId: itemId, timeFrom: startDate, timeTill: endDate, valueType: historyType)
        return HistoryPage(points: historyPoints(from: datedValues(from: rows)), truncated: rows.count >= zabbixHistoryPageLimit)
    }

    private func fetchTrendPage(itemId: String, from startDate: Date, until endDate: Date) async throws -> HistoryPage {
        let rows = try await fetchTrends(itemId: itemId, timeFrom: startDate, timeTill: endDate)
        let values = datedValues(from: rows.map {
            HistoryProperties(itemId: $0.itemId, clock: $0.clock, value: $0.valueAvg)
        })
        return HistoryPage(points: historyPoints(from: values), truncated: values.count >= zabbixHistoryPageLimit)
    }

    /// Numeric items (float and unsigned) keep an hourly average when raw history is empty.
    private func fallsBackToHourlyTrends(historyType: Int, from start: Date, until end: Date) -> Bool {
        (historyType == 0 || historyType == 3) && end.timeIntervalSince(start) >= hourlyTrendMinimum
    }

    private func fetchHistoryData(itemId: String, timeFrom: Date, timeTill: Date, historyType: Int) async throws -> [Date: String] {
        let rows = try await fetchHistories(itemId: itemId, timeFrom: timeFrom, timeTill: timeTill, valueType: historyType)
        return datedValues(from: rows)
    }

    private func datedValues(from rows: [HistoryProperties]) -> [Date: String] {
        var results: [Date: String] = [:]
        results.reserveCapacity(rows.count)
        for row in rows {
            guard let clock = Double(row.clock) else { continue }
            results[Date(timeIntervalSince1970: clock)] = row.value
        }
        return results
    }
}

/// The selected period, measured back from now. An unknown period is a single instant.
func chartTimeWindow(for period: String) -> (start: Date, end: Date) {
    let now = Date()
    switch period {
    case "1H":
        return (Calendar.current.date(byAdding: .hour, value: -1, to: now)!, now)
    case "3H":
        return (Calendar.current.date(byAdding: .hour, value: -3, to: now)!, now)
    case "6H":
        return (Calendar.current.date(byAdding: .hour, value: -6, to: now)!, now)
    case "12H":
        return (Calendar.current.date(byAdding: .hour, value: -12, to: now)!, now)
    case "1D":
        return (Calendar.current.date(byAdding: .day, value: -1, to: now)!, now)
    case "2D":
        return (Calendar.current.date(byAdding: .day, value: -2, to: now)!, now)
    case "1W":
        return (Calendar.current.date(byAdding: .weekOfYear, value: -1, to: now)!, now)
    default:
        return (now, now)
    }
}

struct HistoryPoint: Equatable, Sendable {
    var clock: Double
    var value: Double
}

struct HistoryPage: Equatable, Sendable {
    var points: [HistoryPoint]
    var truncated: Bool
}

struct HistorySeries: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case history
        case trend
    }

    var kind: Kind
    var points: [HistoryPoint]
    var coveredStart: Double
    var coveredEnd: Double
    /// The page stopped at `zabbixHistoryPageLimit`, so older rows are not requested again.
    var truncated: Bool

    func slice(from start: Double, to end: Double) -> [HistoryPoint] {
        let lower = historyLowerBound(points, clock: start)
        let upper = historyLowerBound(points, clock: end + 0.000_001)
        return Array(points[lower..<upper])
    }

    static func loaded(
        _ fetched: [HistoryPoint],
        kind: Kind,
        requestedStart: Double,
        requestedEnd: Double,
        truncated: Bool
    ) -> HistorySeries {
        let capped = historyCapped(fetched)
        let hitPage = truncated || capped.dropped
        return HistorySeries(
            kind: kind,
            points: capped.points,
            coveredStart: hitPage ? (capped.points.first?.clock ?? requestedStart) : requestedStart,
            coveredEnd: requestedEnd,
            truncated: hitPage
        )
    }

    func applyingOlder(_ fetched: [HistoryPoint], truncated fetchTruncated: Bool, requestedStart: Double) -> HistorySeries {
        let capped = historyCapped(historyMerged(existing: points, fetched: fetched))
        let hitPage = truncated || fetchTruncated || capped.dropped
        return HistorySeries(
            kind: kind,
            points: capped.points,
            coveredStart: hitPage ? (capped.points.first?.clock ?? requestedStart) : requestedStart,
            coveredEnd: coveredEnd,
            truncated: hitPage
        )
    }

    func applyingNewer(_ fetched: [HistoryPoint], truncated fetchTruncated: Bool, requestedEnd: Double) -> HistorySeries {
        let capped = historyCapped(historyMerged(existing: points, fetched: fetched))
        let hitPage = truncated || fetchTruncated || capped.dropped
        return HistorySeries(
            kind: kind,
            points: capped.points,
            coveredStart: hitPage ? (capped.points.first?.clock ?? coveredStart) : coveredStart,
            coveredEnd: requestedEnd,
            truncated: hitPage
        )
    }

    func coveringOlderQuiet(to requestedStart: Double) -> HistorySeries {
        var copy = self
        copy.coveredStart = min(coveredStart, requestedStart)
        return copy
    }

    func coveringNewerQuiet(to requestedEnd: Double) -> HistorySeries {
        var copy = self
        copy.coveredEnd = max(coveredEnd, requestedEnd)
        return copy
    }
}

enum HistoryReadPlan: Equatable, Sendable {
    case serve
    case load
    case older(until: Double)
    case newer(since: Double, kind: HistorySeries.Kind)
    case both(until: Double, since: Double, kind: HistorySeries.Kind)
}

func historyReadPlan(_ series: HistorySeries?, from start: Double, to end: Double) -> HistoryReadPlan {
    guard let series else { return .load }
    let needsOlder = start + 1 < series.coveredStart && !series.truncated
    let needsNewer = end > series.coveredEnd + 1
    switch (needsOlder, needsNewer) {
    case (false, false):
        return .serve
    case (true, false):
        return .older(until: series.coveredStart)
    case (false, true):
        return .newer(since: series.coveredEnd, kind: series.kind)
    case (true, true):
        return .both(until: series.coveredStart, since: series.coveredEnd, kind: series.kind)
    }
}

/// One series per item an operator has charted. Eight series, each at most one history page.
actor HistorySeriesStore {
    static let shared = HistorySeriesStore()
    static let maximumSeries = 8

    private var stored: [HistorySeriesKey: HistorySeries] = [:]
    private var order: [HistorySeriesKey] = []

    func plan(itemId: String, valueType: Int, from start: Double, to end: Double) -> HistoryReadPlan {
        historyReadPlan(stored[HistorySeriesKey(itemId: itemId, valueType: valueType)], from: start, to: end)
    }

    /// The live edge is the only gap, so the chart can draw this slice while that edge is fetched.
    func catchingUp(itemId: String, valueType: Int, from start: Double, to end: Double) -> [Date: String]? {
        let key = HistorySeriesKey(itemId: itemId, valueType: valueType)
        guard let series = stored[key] else { return nil }
        guard case .newer = historyReadPlan(series, from: start, to: end) else { return nil }
        return historyDictionary(series.slice(from: start, to: end))
    }

    func kind(itemId: String, valueType: Int) -> HistorySeries.Kind? {
        stored[HistorySeriesKey(itemId: itemId, valueType: valueType)]?.kind
    }

    func serve(itemId: String, valueType: Int, from start: Double, to end: Double) -> [Date: String] {
        let key = HistorySeriesKey(itemId: itemId, valueType: valueType)
        guard let series = stored[key] else { return [:] }
        touch(key)
        return historyDictionary(series.slice(from: start, to: end))
    }

    func overlap(itemId: String, valueType: Int, from start: Double, to end: Double) -> [Date: String]? {
        let key = HistorySeriesKey(itemId: itemId, valueType: valueType)
        guard let series = stored[key] else { return nil }
        touch(key)
        return historyDictionary(series.slice(from: start, to: end))
    }

    func commit(_ series: HistorySeries, itemId: String, valueType: Int, from start: Double, to end: Double) -> [Date: String] {
        let key = HistorySeriesKey(itemId: itemId, valueType: valueType)
        remember(series, key: key)
        return historyDictionary(series.slice(from: start, to: end))
    }

    func commitOlder(
        _ fetched: [HistoryPoint],
        truncated: Bool,
        itemId: String,
        valueType: Int,
        from start: Double,
        to end: Double
    ) -> [Date: String] {
        let key = HistorySeriesKey(itemId: itemId, valueType: valueType)
        guard let existing = stored[key] else { return [:] }
        let series = existing.applyingOlder(fetched, truncated: truncated, requestedStart: start)
        remember(series, key: key)
        return historyDictionary(series.slice(from: start, to: end))
    }

    func commitNewer(
        _ fetched: [HistoryPoint],
        truncated: Bool,
        itemId: String,
        valueType: Int,
        from start: Double,
        requestedEnd end: Double
    ) -> [Date: String] {
        let key = HistorySeriesKey(itemId: itemId, valueType: valueType)
        guard let existing = stored[key] else { return [:] }
        let series = existing.applyingNewer(fetched, truncated: truncated, requestedEnd: end)
        remember(series, key: key)
        return historyDictionary(series.slice(from: start, to: end))
    }

    func noteQuietOlder(itemId: String, valueType: Int, from start: Double, to end: Double) -> [Date: String] {
        let key = HistorySeriesKey(itemId: itemId, valueType: valueType)
        guard let existing = stored[key] else { return [:] }
        let series = existing.coveringOlderQuiet(to: start)
        remember(series, key: key)
        return historyDictionary(series.slice(from: start, to: end))
    }

    func noteQuietNewer(itemId: String, valueType: Int, from start: Double, end: Double) -> [Date: String] {
        let key = HistorySeriesKey(itemId: itemId, valueType: valueType)
        guard let existing = stored[key] else { return [:] }
        let series = existing.coveringNewerQuiet(to: end)
        remember(series, key: key)
        return historyDictionary(series.slice(from: start, to: end))
    }

    private func remember(_ series: HistorySeries, key: HistorySeriesKey) {
        stored[key] = series
        touch(key)
        while order.count > Self.maximumSeries {
            stored[order.removeFirst()] = nil
        }
    }

    private func touch(_ key: HistorySeriesKey) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

struct HistorySeriesKey: Hashable, Sendable {
    var itemId: String
    var valueType: Int
}

func historyPoints(from rows: [Date: String]) -> [HistoryPoint] {
    var points: [HistoryPoint] = []
    points.reserveCapacity(rows.count)
    for (date, raw) in rows {
        guard let value = Double(raw), value.isFinite else { continue }
        points.append(HistoryPoint(clock: date.timeIntervalSince1970, value: value))
    }
    points.sort { $0.clock < $1.clock }
    return points
}

func historyDictionary(_ points: [HistoryPoint]) -> [Date: String] {
    var rows: [Date: String] = [:]
    rows.reserveCapacity(points.count)
    for point in points {
        rows[Date(timeIntervalSince1970: point.clock)] = String(format: "%.17g", point.value)
    }
    return rows
}

func historyMerged(existing: [HistoryPoint], fetched: [HistoryPoint]) -> [HistoryPoint] {
    var merged: [HistoryPoint] = []
    merged.reserveCapacity(existing.count + fetched.count)
    var index = 0
    var fetchedIndex = 0
    while index < existing.count && fetchedIndex < fetched.count {
        let kept = existing[index]
        let incoming = fetched[fetchedIndex]
        if kept.clock < incoming.clock {
            merged.append(kept)
            index += 1
        } else if incoming.clock < kept.clock {
            merged.append(incoming)
            fetchedIndex += 1
        } else {
            merged.append(kept)
            index += 1
            fetchedIndex += 1
        }
    }
    if index < existing.count {
        merged.append(contentsOf: existing[index...])
    }
    if fetchedIndex < fetched.count {
        merged.append(contentsOf: fetched[fetchedIndex...])
    }
    return merged
}

func historyCapped(_ points: [HistoryPoint]) -> (points: [HistoryPoint], dropped: Bool) {
    guard points.count > zabbixHistoryPageLimit else { return (points, false) }
    return (Array(points.suffix(zabbixHistoryPageLimit)), true)
}

func historyLowerBound(_ points: [HistoryPoint], clock: Double) -> Int {
    var lower = 0
    var upper = points.count
    while lower < upper {
        let mid = lower + (upper - lower) / 2
        if points[mid].clock < clock {
            lower = mid + 1
        } else {
            upper = mid
        }
    }
    return lower
}
