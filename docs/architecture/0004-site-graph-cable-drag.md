# ADR 0004 - Cable drag on the site graph

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-10-14 |
| **Decision owner** | Leon Cassidy |
| **Applies to** | `SiteGraphView`, `DeviceView`, `CablePairSheet`, `SiteTopologyEdges.freeInterfaces` |

## Principle

**Pull a cable from the graph. The write stays the one Connect… already uses.**

Build mode gains the two-click tether from the earlier Pulse graph. The sheet picks one free interface on each device and submits a `CableCreateIntent` (ADR 0003, *Write intents*). It sends the same body as `createCable(from:to:)`. The view does not insert a `Cable`. The graph redraws from `connectedEndpointId` when `.netBoxStoreDidApply` fires.

## Decisions

1. **Gesture.** Two clicks, as a sub-state of build mode (`enableGestures`). Hover a seated device and click `plus.circle.fill`. Move. The end is the pointer. While the pointer is inside another seated device's icon, the end is that icon's centre, and it is the pointer again once it leaves the icon. The label is not a target. Left-click that icon to open the sheet. Left-click on empty graph does not cancel. Right-click retracts at once: the end springs back to the start, then the stroke fades. There is no menu. SwiftUI's tap gesture does not carry the mouse button, so right-click is the approved bridge in ADR 0005: an `NSClickGestureRecognizer` for the secondary button, attached with `.gesture`. While the pointer is on the device the cable started from, that plus is an X in the same place, and clicking it retracts the same way. Other pluses stay hidden for the whole tether. Leaving build mode retracts. The cable gesture stays SwiftUI apart from that one recogniser: no AppKit view, no event monitor. Press-drag is not the gesture: the node already has a high-priority drag that repositions it. While a tether is active that drag is masked off and the nodes are not hit-tested.
2. **Anchor and drawing.** The line runs from the start device's image centre (`position` + `imageCentres`, the same sum existing edges use). While the tether is tracking, one SwiftUI layer owns the pointer and writes the stroke on each move. That layer does not take key focus. A focus ring on it is a bitmap of the 5000-point canvas. There is no frame clock and no second point. A move walks that site's icon frames once. The device views are not hit-tested, which is the work that made the key window stall. The tracking stroke is under the nodes (`zIndex` 1, nodes are 5), does not participate in hit testing, and is not animatable, so a move cannot lag the pointer. Retract uses its own shape, sprung back to the start over 0.22s, then the stroke fades. Once the sheet is open the end stays on the two centres. After Create the tether stays, at the stored stroke's width, until the stored cable is drawn, then it fades out as the stored stroke fades in. The plus is an overlay on the icon's bottom-trailing corner, raised 34 points, palette primary on accent. It stays mounted and scales about its own centre, in on hover and back out when the pointer leaves. A press scales it down, like a button. A drag of the node scales it out, and it stays out for 400ms after the pointer is released so the next move does not flash it. It is not a child of the icon stack, so showing it does not change the node's size or the point `.position` is anchored to. A press on the plus does not reposition the node. `ImageCentrePreferenceKey` still subtracts `(30, 45)`. The icon frame used for the snap is a separate preference.
3. **Interfaces.** A port is free when `cableId == nil` and `connectedEndpointId == nil`, the same rule as `ConnectInterfaceSheet`. Disabled and virtual ports stay listed. Names sort with `localizedStandardCompare`. The first free port on each side is preselected. A side with none says so and Create stays disabled. Front ports are out of scope (issue #47).
4. **Sheet.** `CablePairSheet` sits beside `ConnectInterfaceSheet`. The layouts differ (two known devices versus one known interface), so one mode-switching view would branch the whole body. The shared rule is `SiteTopologyEdges.freeInterfaces`. The sheet calls `fetchVOs(deviceId:)` twice, on appear, and holds the value objects. It does not call the site-wide fetch, and a keystroke does not fetch.
5. **Body.** Create sends the same `CableCreate.connecting` body as Connect…: interface terminations only. Status, type, tenant, colour, label, and length are omitted. NetBox applies its default status (`connected`). The `Cable` model comment says NetBox defaults tenant from the device. That has not been re-validated against the lab in this change.
6. **Failure.** Create records the ask and closes the sheet before the POST. A refused POST leaves a failed cable on the graph, at the stored stroke's width, with NetBox's words (or the offline sentence) and Discard. The store is unchanged. If NetBox stores the cable but Pulse cannot load the two ends, the ask still retires as stored and the quiet delta brings the ends. There is no undo toast. Disconnect on the interface popover remains the way to remove a cable.
7. **Seats.** The plus is drawn only when build mode is on, no tether is in progress, the pointer is over the icon, the node is not being dragged, and `allowsActions(deviceID:)` is true. While tracking, the start device shows an X in that plus's place when the pointer is on its icon, and clicking the X retracts. The line snaps only to an icon that passes `allowsActions`. The sheet opens only when `allowsLink(a:b:)` is true. `requireLink` inside the engine's cable path is still the write gate. A refusal there is a failed ask, and no POST is sent.
8. **iOS.** The plus, the tether, and the sheet are macOS-only. On iOS, `enableGestures` is pan and zoom, and there is no hover. Two-tap cable creation is later work. Connect… remains available.
9. **Scale.** Cost is the port count of the two devices, held for a site of about 200 devices and 3,000 interfaces. A move walks that site's icon frames once and does not hit-test the device views. The gesture does not scan the estate.

## State machine

```text
idle
  plus on a seated device, build mode on   →  tethering(A)

tethering(A)
  move, pointer outside every other icon   →  line end is the pointer
  pointer inside seated B's icon, B ≠ A    →  line end is B's image centre
  pointer leaves that icon                 →  line end is the pointer
  pointer on A                            →  A's plus is an X
  right-click, that X, or build mode off   →  end springs back to A, stroke fades, idle
  left-click B's icon, allowsLink          →  sheet(A, B), end fixed on the two centres
  left-click empty graph                   →  stays tethering(A)

sheet(A, B)
  Cancel                                   →  end springs back to A, stroke fades, idle
  Create                                   →  sheet closes, ask recorded, end stays put

handoff(A, B)
  stored cable drawn                       →  tether fades out, stored stroke fades in, idle
  ask failed                               →  tether dissolves, failed cable with Discard, idle
```

Node reposition is off during `tethering` and `sheet`. Other pluses stay hidden in both. On A, while tracking, the plus's place is an X when the pointer is on A.

## Failure

| Failure | Behaviour | Blast radius |
|---|---|---|
| NetBox unreachable | Failed cable with the offline sentence and Discard. No local cable. | One ask. |
| 4xx, including a port occupied concurrently | Failed cable with the server text and Discard. No local row. | One ask. |
| NetBox stored the cable, the end GETs failed | The ask retires as stored. The quiet delta loads the ends. | The edge waits for that delta. |
| Seat lost before POST | `requireLink` refuses. Failed cable with the seat message. | No cable. |
| No free port on one side | Create disabled. No request. | None. |
| Partial sync, port not stored | That port is absent from the picker. | No invented port. |
| Pointer moves while the sheet is up or the ask is posting | The end stays on the two image centres. | No local cable, no moved node. |
| Right-click, the X on the start device, or Cancel | The end springs back to the start, then the stroke fades. | No request. |
| Left-click on empty graph while tracking | The tether stays. | No request. |

An offline sheet still lists ports from the on-device store. There is no queued retry.

## As built

macOS site graph, build mode. `CablePairSheet` submits a `CableCreateIntent`. iOS unchanged. Front ports unchanged. Tenant inheritance on the created cable has not been confirmed in the lab.

## Revision history

- 2026-10-14 - Accepted. Two-click tether in build mode, pair sheet, same cable POST as Connect…. The decisions above are the gesture. A menu, canvas focus, a frame clock, and an event monitor were tried and removed.
- 2026-10-15 - The sheet now records an ask and closes (ADR 0003 P5); decisions 1, 2, 6, the state machine, and the failure table describe that. Right-click retract is kept as the first approved bridge in ADR 0005.
