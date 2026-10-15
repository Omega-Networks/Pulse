# ADR 0005 - SwiftUI interface and approved bridges

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-10-15 |
| **Decision owner** | Leon Cassidy |
| **Applies to** | Every view in `Pulse/Views/`, `Pulse/Web/`, and any new interface code |

## Principle

**The interface is SwiftUI and follows Apple's Human Interface Guidelines. A bridge to AppKit or UIKit is an exception a person approves, recorded here, and kept as small as the behaviour allows.**

## Decisions

1. **SwiftUI first.** When SwiftUI has no API for a behaviour, the change first asks whether the behaviour is needed. The order is the one every change follows: question the requirement, delete the part, then optimise, accelerate, and automate. A behaviour that is not needed is removed, not bridged.
2. **Approved bridges.** A bridge to a non-SwiftUI interface SDK (`NSViewRepresentable`, `NSGestureRecognizerRepresentable`, `UIViewRepresentable`, an event monitor, a direct AppKit or UIKit view) lands only when a person who owns the area has approved it. The change adds a row to the register below. The bridge is the smallest one that does the job: one representable, no view hierarchy of its own, no second pattern. The import carries a comment that points here.
3. **Choices in a form.** Every choice in a form is a `ChoiceField`: a text field with `textInputSuggestions`, in `DeviceBuilder.swift`. A text field is always on the macOS Tab loop. A menu `Picker` is on it only when Keyboard navigation is on in System Settings, and a menu grows to the height of the screen. The field shows every option while it is empty or holds a complete choice, and the options that match while the operator types. A value counts only when it matches an option. A checkbox stays a `Toggle`.
4. **Suggestion list height.** SwiftUI has no setting for it. Measured on macOS 26, 2026-10-15, with 200 options: the suggestion window opens on focus, is as tall as the window that owns the field, and scrolls. A 192-point window held a 4,810-point list; a 362-point window held the same list at 362 points. A sheet's height is therefore the cap.

## Register of approved bridges

| # | Where | Bridge | Why SwiftUI cannot | Approved by | Date |
|---|---|---|---|---|---|
| 1 | Site-graph cable tether, `SiteGraphView.swift` `SecondaryClick` | `NSGestureRecognizerRepresentable` wrapping `NSClickGestureRecognizer`, secondary button, attached with `.gesture`. It runs the same retract as the X on the start device. | SwiftUI tap gestures do not carry the mouse button. `.contextMenu` is a menu, and the gesture has no menu. | Leon Cassidy | 2026-10-15 |

## Tried and removed

- AppKit pop-up buttons and combo boxes on the New Device form. Writing `stringValue` back while the field editor was active selected the first character, so a typed name lost its first letter. Replaced by decision 3.

## Revision history

- 2026-10-15 - Accepted. SwiftUI only, with approved bridges. Right-click retract on the cable tether is the first entry. Form choices are typed fields with suggestions.
