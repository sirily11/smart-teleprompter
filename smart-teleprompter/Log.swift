//
//  Log.swift
//  smart-teleprompter
//
//  Lightweight os.Logger categories. Filter in Console.app / Xcode console by
//  subsystem "rxlab.smart-teleprompter".
//

import Foundation
import os

enum Log {
    private static let subsystem = "rxlab.smart-teleprompter"

    static let speech = Logger(subsystem: subsystem, category: "speech")   // recognizer / audio
    static let sync   = Logger(subsystem: subsystem, category: "sync")     // word-matching engine
    static let ui     = Logger(subsystem: subsystem, category: "ui")       // present-mode / view model
}
