// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// Wraps the backup bytes so `fileExporter` can write them.
///
/// `FileDocument` is the only way to hand SwiftUI's exporter a file, and it
/// insists on being able to read one back as well. Reading is never used here —
/// importing goes through `fileImporter` and ``BackupArchive/decode(_:)``, which
/// reports what is wrong with a bad file — so the initialiser exists only to
/// satisfy the protocol.
struct BackupDocument: FileDocument {

    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
