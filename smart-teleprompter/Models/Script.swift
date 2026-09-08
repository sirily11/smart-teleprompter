//
//  Script.swift
//  smart-teleprompter
//

import Foundation
import SwiftData

@Model
final class Script {
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    /// Nil preserves creation-date ordering until the user moves a script.
    var sortPosition: Double? = nil
    /// Last-used font size in present mode for this script.
    var fontSize: Double
    /// Last token index reached by speech sync (-1 = start). Lets a session resume.
    var lastTokenIndex: Int = -1

    init(title: String = "", body: String = "", fontSize: Double = 48) {
        let now = Date()
        self.title = title
        self.body = body
        self.createdAt = now
        self.updatedAt = now
        self.fontSize = fontSize
        self.lastTokenIndex = -1
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "Untitled Script" : firstLine
    }
}
