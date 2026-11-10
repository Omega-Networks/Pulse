# ADR 0006 - Zabbix cause and symptom counting

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-11-08 |
| **Decision owner** | Leon Cassidy |
| **Applies to** | Every counter of Zabbix problems: device squares, device and site colour, map pins, the map window's toolbar squares |

## Principle

**A problem counts when it is open, not suppressed, and not a symptom. A symptom does not count and does not colour a device.**

Zabbix uses this rule for map and widget totals. Pulse uses the same rule so the two pictures match.

## Decision

`Event.counted` is the one predicate. `Event.counted(amongHostIds:)` is that rule limited to a set of Zabbix host ids. A `#Predicate` cannot call another predicate, so the host limit is a second literal, not `evaluate`. `Event.isCountedProblem` is the same rule in memory, and only after `isStoreBacked`.

`Device.activeEvents` uses `isCountedProblem`. `storeActiveCounts` uses `counted(amongHostIds:)`. The toolbar squares and `DevicePopoverView` query `Event.counted`. Device squares, device fill, site colour, map pins, and site list order read the stored ints those counts write.

A later counter uses `Event.counted` or `counted(amongHostIds:)`. It does not restate the three comparisons.

A stored estate-wide tally was withdrawn. `fetchCount` does not live-update a view, and a stored summary (`ProblemCounts`) had already failed. The squares stay a query.

## What a symptom is

Zabbix `cause_eventid` of `"0"`, or a payload that omits the key, is a cause. Any other value is the cause's event id, and the row is a symptom. An update that omits the key does not clear a rank already stored. A present `"0"` does.

`cause_eventid` arrived in Zabbix 6.4.0. The PoC runs 8.0. A 6.2 or earlier server omits the key, so every problem stays a cause and the table stays flat.

Nesting is two levels. A symptom is drawn under its cause when that cause is in the same set. Otherwise it stays at the top and stays a symptom. A resolved cause keeps its symptoms while the cause is in the set.

## Revision history

- 2026-11-08 - Accepted. One counting rule. The stored toolbar tally is withdrawn.
- 2026-11-09 - Nesting needs Zabbix 6.4 or later. The PoC runs 8.0.
- 2026-11-09 - The count is open, not suppressed, and not a symptom. Same rule.
