// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// What a server says before it lets anyone in, above the field the password
/// goes into.
///
/// A banner is a legal notice as often as it is a greeting, and either way it is
/// worth nothing after the fact: it has to be readable *before* anything is
/// typed. That is why it comes with the prompt, and why the prompt itself is now
/// raised from inside the connection — see ``SSHAuth/deferred``.
///
/// Shown as it arrived. Monospaced, because banners are drawn with spaces and a
/// proportional font takes their frames apart; never wrapped, because a banner
/// is laid out for eighty columns and this box is narrower than that, so wrapped
/// it would break its own rules in half and put a centred title on two lines.
/// It scrolls both ways instead, and stops at ``maxHeight`` so that sixty lines
/// of policy cannot push the password field off the screen. Selectable, because
/// a banner sometimes carries a reference number somebody has to write down.
///
/// Android's `ServerBanner` is the same box with one part this does not need: a
/// television has no finger to drag with, so there the box takes focus and the
/// D-pad scrolls it.
struct ServerBannerView: View {

    /// Carries the laid-out height of the banner out of the scroll view.
    private struct BannerHeight: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    let text: String

    /// Five or six lines of a banner, after which it scrolls. Android's 150dp.
    var maxHeight: CGFloat = 150

    /// How tall the banner is once it is laid out, which is what the box is
    /// made as tall as — up to ``maxHeight``.
    ///
    /// Measured and not worked out from the line count. That was tried first,
    /// with `UIFont`'s line height for a monospaced caption, and it came out
    /// short: SwiftUI lays the same text out at 15.8 points a line where the
    /// font reports 14.3, so an eight-line banner lost its last line behind a
    /// scroll bar. The height of the thing itself cannot be wrong, and it
    /// follows Dynamic Type without being asked to.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(.passwordServerBanner)
                .font(.caption2)
                .foregroundStyle(Color(.secondaryLabel))

            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(Color(.label))
                    .textSelection(.enabled)
                    // The one that does the work: without it the text takes the
                    // scroll view's width and wraps inside it, and the sideways
                    // scrolling has nothing to scroll.
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: BannerHeight.self, value: proxy.size.height)
                        }
                    )
            }
            .onPreferenceChange(BannerHeight.self) { contentHeight = $0 }
            // A height and not a ceiling. A `ScrollView` takes whatever it is
            // offered, and in this panel that is the whole screen, so a
            // `maxHeight` alone would leave a one-line banner sitting in a box
            // five lines deep. Compose shrinks to its content for free; here
            // the content is measured and the box follows it, up to the cap.
            // (Android: `heightIn(max = 150.dp)`.)
            //
            // Before the first measurement it is the cap, so a banner that is
            // about to be tall does not start as a sliver and grow.
            .frame(height: contentHeight == 0 ? maxHeight : min(contentHeight, maxHeight))
            .background(Color(.tertiarySystemBackground), in: .rect(cornerRadius: 4))
            .accessibilityIdentifier("server-banner")
        }
    }
}
