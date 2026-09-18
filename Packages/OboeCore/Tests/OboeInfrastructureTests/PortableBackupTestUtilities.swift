import CryptoKit
import Foundation
import XCTest

/// Parses an export into ordered JSON objects, applies `transform`, then
/// rewrites the file with sorted keys and a recomputed SHA-256 footer.
func rewriteBackup(
    _ sourceURL: URL,
    to destinationURL: URL,
    transform: (inout [[String: Any]]) -> Void
) throws {
    let source = try Data(contentsOf: sourceURL)
    var objects = try source.split(separator: 0x0A).map { line -> [String: Any] in
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        )
    }
    XCTAssertEqual(objects.removeLast()["recordType"] as? String, "footer")
    transform(&objects)

    var output = Data()
    var hasher = SHA256()
    for object in objects {
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(0x0A)
        output.append(line)
        hasher.update(data: line)
    }
    let checksum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    var footer = try JSONSerialization.data(
        withJSONObject: [
            "recordType": "footer",
            "checksumAlgorithm": "sha256",
            "checksum": checksum
        ],
        options: [.sortedKeys]
    )
    footer.append(0x0A)
    output.append(footer)
    try output.write(to: destinationURL)
}

/// Reshapes a v3 export into a restorable older format for fixture tests:
/// strips v3-only records/keys and (for v1) the note source_ref column.
func downgradeBackupToLegacyFormat(_ objects: inout [[String: Any]], version: Int) {
    let legacyTypes = [
        "deck", "note", "example", "tag", "noteTag", "profile", "card",
        "studyDay", "dailyTask", "review", "draft", "settings"
    ]
    objects[0]["formatVersion"] = version
    objects[0].removeValue(forKey: "excludedScopes")
    objects[0]["recordOrder"] = legacyTypes
    if var counts = objects[0]["counts"] as? [String: Any] {
        for key in counts.keys where !legacyTypes.contains(key) {
            counts.removeValue(forKey: key)
        }
        objects[0]["counts"] = counts
    }
    objects.removeAll { object in
        guard let type = object["recordType"] as? String, type != "manifest" else {
            return false
        }
        return !legacyTypes.contains(type)
    }
    if version == 1 {
        for index in objects.indices where objects[index]["recordType"] as? String == "note" {
            objects[index].removeValue(forKey: "source_ref")
        }
    }
}
