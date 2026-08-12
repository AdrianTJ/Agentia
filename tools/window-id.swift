#!/usr/bin/env swift
//
// Prints the window ID of the running app, for capturing just its window:
//
//   screencapture -o -x -l$(tools/window-id.swift) shot.png
//
// Layout tests assert that a frame is where it should be. They cannot say
// whether the result looks right, and checking logs instead of pixels is how a
// sidebar came to be drawn on top of the traffic lights with a green suite. This
// is the other half of that: look at the thing.
//
// Only this app's window, deliberately. Capturing the whole screen would take
// in whatever else the person at this Mac happens to have open.

import CoreGraphics
import Foundation

let appName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Agentia"

guard let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("cannot list windows\n".utf8))
    exit(1)
}

for window in windows {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner == appName,
          let number = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double
    else { continue }

    // WebKit keeps a small off-screen host window in the process; it is not the
    // document window and capturing it would produce a blank image.
    if width < 200 || height < 200 { continue }

    print(number)
    exit(0)
}

FileHandle.standardError.write(Data("no window found for \(appName)\n".utf8))
exit(1)
