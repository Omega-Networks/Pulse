//
//  ChoiceField.swift
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

#if os(macOS)

/// One value a form can pick, with the name the operator reads. A name
/// that repeats carries its value, so a completion resolves to one record.
struct ChoiceOption<Value: Hashable>: Identifiable {
    let id: Value
    let name: String
}

extension [ChoiceOption<String>] {
    static var faces: Self { .list([("front", "Front"), ("rear", "Rear")]) }
}

extension Array {
    static func list<Value>(_ entries: [(id: Value, name: String)]) -> Self
    where Element == ChoiceOption<Value> {
        let counts = Dictionary(entries.map { ($0.name.lowercased(), 1) }, uniquingKeysWith: +)
        return entries.map { entry in
            let repeated = counts[entry.name.lowercased(), default: 0] > 1
            return ChoiceOption(id: entry.id, name: repeated ? "\(entry.name) (\(entry.id))" : entry.name)
        }
    }
}

/// Picks one value by typing or from the list. It is a text field, so Tab
/// reaches it. The list shows every match and scrolls; macOS holds it to
/// the height of the window the field is in.
struct ChoiceField<Value: Hashable>: View {
    let title: String
    let prompt: String
    @Binding var selection: Value?
    let options: [ChoiceOption<Value>]

    @State private var text = ""

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .textInputSuggestions {
                ForEach(suggestions) { option in
                    Text(option.name)
                        .textInputCompletion(option.name)
                }
            }
            .onChange(of: text) {
                selection = option(named: text)?.id
            }
            .onChange(of: selection, initial: true) {
                guard let selected = options.first(where: { $0.id == selection }),
                      option(named: text)?.id != selected.id else { return }
                text = selected.name
            }
    }

    /// Every option while the field is empty or holds a complete choice,
    /// so the list works as a menu. Otherwise the options that match.
    private var suggestions: [ChoiceOption<Value>] {
        guard let query = text.nonBlank, option(named: query) == nil else { return options }
        return options.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func option(named name: String) -> ChoiceOption<Value>? {
        options.first { $0.name.equalsIgnoringCase(name.trimmed) }
    }
}

#endif
