import AppKit

struct SpaceInfo: Identifiable, Hashable {
    let id: CGSSpaceID
    let uuid: String
    let type: Int
    let displayIdentifier: String
    /// Global Mission Control desktop number (1-based, continuous across displays
    /// in display order); 0 for fullscreen-app spaces, which are not numbered.
    let desktopNumber: Int
    let isCurrent: Bool

    /// CGS space type 4 = fullscreen app space
    var isFullscreen: Bool {
        type == 4
    }
}

struct DisplaySpaces: Identifiable {
    let identifier: String
    let screen: NSScreen?
    let currentSpaceID: CGSSpaceID?
    let spaces: [SpaceInfo]

    var id: String {
        identifier
    }
}
