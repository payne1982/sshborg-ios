// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
import SwiftTerm
import UIKit

@testable import SSHBorg

/// Holding backspace on the software keyboard keeps deleting.
///
/// The keyboard repeats the delete key only while the view says `hasText`, and
/// SwiftTerm says no at an empty prompt. These check the answer UIKit actually
/// gets — through the Objective-C protocol, which is how the keyboard asks —
/// since a finger holding a key is not something a unit test can supply.
@MainActor
final class BackspaceRepeatTests: XCTestCase {

    private var database: AppDatabase!

    override func setUpWithError() throws {
        database = try AppDatabase.makeInMemory()
    }

    func testTheSessionTerminalTellsTheKeyboardThereIsTextToDelete() {
        let session = TerminalSession(
            host: Host(label: "somewhere", hostname: "example.invalid", username: "someone"),
            hosts: HostRepository(database),
            keys: SSHKeyRepository(database)
        )
        XCTAssertTrue(session.terminalView is ShellTerminalView)
        XCTAssertTrue((session.terminalView as UIKeyInput).hasText, "the keyboard would stop repeating delete")
    }

    /// The problem this works around, pinned so its removal is noticed: when a
    /// SwiftTerm update answers yes by itself — or makes `hasText` overridable —
    /// this fails, and ShellTerminalView can become a plain override or go.
    func testPlainSwiftTermStillAnswersNoAtAnEmptyPrompt() {
        let plain = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse((plain as UIKeyInput).hasText)
    }

    /// Adding the method to the subclass must leave SwiftTerm's own class alone.
    func testTheAnswerIsNotInstalledOnTerminalViewItself() {
        _ = ShellTerminalView(frame: .zero)
        let plain = TerminalView(frame: .zero)
        XCTAssertFalse((plain as UIKeyInput).hasText)
    }
}
