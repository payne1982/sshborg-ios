// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

extension View {

    /// `onChange(of:)` that compiles clean on both sides of the 16/17 line.
    ///
    /// iOS 17 replaced `onChange(of:perform:)` with a two-parameter closure and
    /// deprecated the old one. At a 16.0 deployment target the old spelling is
    /// the only one that exists, and using it directly earns a deprecation
    /// warning at every call site — six of them, enough to bury a real warning.
    ///
    /// Only the new value is passed on: no call site here wanted the old one.
    @ViewBuilder
    func onValueChange<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, new in action(new) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }

    /// The same, for the one call site that also wants the action run once on
    /// appearance. iOS 17 spells that `initial: true`; iOS 16 has no such
    /// parameter, so it is `onAppear`.
    @ViewBuilder
    func onValueChange<V: Equatable>(
        of value: V,
        initial: Bool,
        perform action: @escaping (V) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value, initial: initial) { _, new in action(new) }
        } else {
            self.onChange(of: value, perform: action)
                .onAppear { if initial { action(value) } }
        }
    }
}
