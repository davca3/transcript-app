import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.skribent.app"

    static let app         = Logger(subsystem: subsystem, category: "app")
    static let pipeline    = Logger(subsystem: subsystem, category: "pipeline")
    static let recorder    = Logger(subsystem: subsystem, category: "recorder")
    static let transcriber = Logger(subsystem: subsystem, category: "transcriber")
    static let diarizer    = Logger(subsystem: subsystem, category: "diarizer")
    static let refiner     = Logger(subsystem: subsystem, category: "refiner")
    static let store       = Logger(subsystem: subsystem, category: "store")
    static let speaker     = Logger(subsystem: subsystem, category: "speaker")
    static let player      = Logger(subsystem: subsystem, category: "player")
    static let systemAudio = Logger(subsystem: subsystem, category: "systemAudio")
}
