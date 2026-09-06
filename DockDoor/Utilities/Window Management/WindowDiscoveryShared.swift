import ApplicationServices
import Cocoa
import Defaults
import ScreenCaptureKit

/// Minimal provider used when we only have a CGWindowID (no SCWindow available)
struct AXFallbackProvider: WindowPropertiesProviding {
    let cgID: CGWindowID
    var windowID: CGWindowID {
        cgID
    }

    var frame: CGRect {
        .zero
    }

    var title: String? {
        nil
    }

    var owningApplicationBundleIdentifier: String? {
        nil
    }

    var owningApplicationProcessID: pid_t? {
        nil
    }

    var isOnScreen: Bool {
        true
    }

    var windowLayer: Int {
        0
    }
}

struct WindowCandidateAttributes {
    let title: String?
    let role: String?
    let subrole: String?
    let size: CGSize?
    let position: CGPoint?

    init(axWindow: AXUIElement) {
        title = try? axWindow.title()
        role = try? axWindow.role()
        subrole = try? axWindow.subrole()
        size = try? axWindow.size()
        position = try? axWindow.position()
    }
}

enum WindowOwnerResolver {
    static func ownerApp(for window: SCWindow) -> NSRunningApplication? {
        guard let pid = window.owningApplication?.processID else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    static func windowBelongsToDisplayApp(_ window: SCWindow, displayApp: NSRunningApplication) -> Bool {
        guard let owner = ownerApp(for: window) else { return false }
        return ownerBelongsToDisplayApp(owner, displayApp: displayApp)
    }

    static func ownerBelongsToDisplayApp(_ owner: NSRunningApplication, displayApp: NSRunningApplication) -> Bool {
        if owner.processIdentifier == displayApp.processIdentifier {
            return true
        }

        guard canResolveThroughDisplayApp(owner) else {
            return false
        }

        if helperBundleBelongsToDisplayApp(owner.bundleIdentifier, displayApp.bundleIdentifier) {
            return true
        }

        return executableRootsMatch(owner: owner, displayApp: displayApp)
    }

    static func displayApp(forOwner owner: NSRunningApplication) -> NSRunningApplication {
        guard canResolveThroughDisplayApp(owner) else {
            return owner
        }

        let candidates = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && ownerBelongsToDisplayApp(owner, displayApp: $0)
        }

        if let parentBundleApp = candidates
            .filter({ $0.processIdentifier != owner.processIdentifier && bundleIsParent($0.bundleIdentifier, of: owner.bundleIdentifier) })
            .sorted(by: { displayAppScore($0, forOwner: owner) > displayAppScore($1, forOwner: owner) })
            .first
        {
            return parentBundleApp
        }

        return candidates.sorted { first, second in
            displayAppScore(first, forOwner: owner) > displayAppScore(second, forOwner: owner)
        }.first ?? owner
    }

    static func isAuxiliaryOwner(_ owner: NSRunningApplication) -> Bool {
        guard canResolveThroughDisplayApp(owner) else {
            return false
        }

        return displayApp(forOwner: owner).processIdentifier != owner.processIdentifier
    }

    private static func canResolveThroughDisplayApp(_ owner: NSRunningApplication) -> Bool {
        owner.activationPolicy != .regular || owner.bundleIdentifier == nil
    }

    private static func helperBundleBelongsToDisplayApp(_ ownerBundle: String?, _ displayBundle: String?) -> Bool {
        guard let ownerBundle, let displayBundle else { return false }
        return ownerBundle == displayBundle ||
            ownerBundle.hasPrefix(displayBundle + ".")
    }

    private static func bundleIsParent(_ parentBundle: String?, of childBundle: String?) -> Bool {
        guard let parentBundle, let childBundle else { return false }
        return childBundle.hasPrefix(parentBundle + ".")
    }

    private static func executableRootsMatch(owner: NSRunningApplication, displayApp: NSRunningApplication) -> Bool {
        guard let ownerPath = owner.executableURL?.standardizedFileURL.path,
              let displayPath = displayApp.executableURL?.standardizedFileURL.path
        else { return false }

        let ownerComponents = ownerPath.split(separator: "/")
        let displayComponents = displayPath.split(separator: "/")
        let commonPrefixCount = zip(ownerComponents, displayComponents).prefix { $0 == $1 }.count

        return commonPrefixCount >= 5
    }

    private static func displayAppScore(_ displayApp: NSRunningApplication, forOwner owner: NSRunningApplication) -> Int {
        var score = 0
        if owner.processIdentifier == displayApp.processIdentifier {
            score += 100
        }
        if owner.bundleIdentifier == displayApp.bundleIdentifier {
            score += 80
        }
        if let ownerBundle = owner.bundleIdentifier,
           let displayBundle = displayApp.bundleIdentifier,
           ownerBundle.hasPrefix(displayBundle + ".")
        {
            score += 90
            score += max(0, 30 - (displayBundle.count / 4))
        } else if helperBundleBelongsToDisplayApp(owner.bundleIdentifier, displayApp.bundleIdentifier) {
            score += 50
        }
        if executableRootsMatch(owner: owner, displayApp: displayApp) {
            score += 10
        }
        return score
    }
}

enum WindowCandidateDiscriminator {
    private static let minimumSize = CGSize(width: 100, height: 50)
    private static let normalLevel = CGWindowLevelForKey(.normalWindow)
    private static let floatingLevel = CGWindowLevelForKey(.floatingWindow)
    private static let unknownSubrole = "AXUnknown"
    private static let documentWindowSubrole = "AXDocumentWindow"

    static func hasUsableSize(_ size: CGSize?) -> Bool {
        guard let size, size.width > 0, size.height > 0 else { return false }
        if Defaults[.disableMinWindowSizeFilter] {
            return true
        }
        return size.width >= minimumSize.width && size.height >= minimumSize.height
    }

    static func hasUsableGeometry(_ attributes: WindowCandidateAttributes) -> Bool {
        guard hasUsableSize(attributes.size) else { return false }
        if let position = attributes.position {
            return position.x.isFinite && position.y.isFinite
        }
        return true
    }

    static func isActualWindow(app: NSRunningApplication,
                               windowID: CGWindowID,
                               level: Int32,
                               attributes: WindowCandidateAttributes) -> Bool
    {
        rejectionReason(app: app, windowID: windowID, level: level, attributes: attributes) == nil
    }

    static func rejectionReason(app: NSRunningApplication,
                                windowID: CGWindowID,
                                level: Int32,
                                attributes: WindowCandidateAttributes) -> String?
    {
        guard windowID != 0 else { return "missing CGWindowID" }
        return potentialRejectionReason(app: app, level: level, attributes: attributes)
    }

    static func isPotentialAXWindow(app: NSRunningApplication,
                                    level: Int32?,
                                    attributes: WindowCandidateAttributes) -> Bool
    {
        potentialRejectionReason(app: app, level: level, attributes: attributes) == nil
    }

    private static func potentialRejectionReason(app: NSRunningApplication,
                                                 level: Int32?,
                                                 attributes: WindowCandidateAttributes) -> String?
    {
        guard hasUsableGeometry(attributes) else { return "unusable geometry" }

        let specialApp = books(app) ||
            keynote(app) ||
            preview(app, attributes.subrole) ||
            openFLStudio(app, attributes.title) ||
            (level.map { crossoverWindow(app, attributes.role, attributes.subrole, $0) } ?? false) ||
            (level.map { alwaysOnTopScrcpy(app, $0, attributes.role, attributes.subrole) } ?? false)

        // Floating panels pass the subrole check but are not switchable app windows
        // (e.g. Outlook's meeting-reminder toast is an AXDialog at floating level 3).
        // The SC discovery path already enforces windowLayer == 0; this keeps the AX
        // path consistent. Apps that legitimately float have explicit rules below.
        let isNormalLevel = level == nil || level == normalLevel
        let standardSubrole = isNormalLevel && [kAXStandardWindowSubrole, kAXDialogSubrole].contains(attributes.subrole)
        let appSpecificSubrole = openBoard(app) ||
            adobeAudition(app, attributes.subrole) ||
            adobeAfterEffects(app, attributes.subrole) ||
            steam(app, attributes.title, attributes.role) ||
            worldOfWarcraft(app, attributes.role) ||
            battleNetBootstrapper(app, attributes.role) ||
            firefox(app, attributes.role, attributes.size) ||
            vlcFullscreenVideo(app, attributes.role) ||
            sanGuoShaAirWD(app) ||
            dvdFab(app) ||
            drBetotte(app) ||
            androidEmulator(app, attributes.title, attributes.role, level) ||
            autocad(app, attributes.subrole)

        guard specialApp || standardSubrole || appSpecificSubrole else {
            return "subrole is not standard/dialog at normal level and no app-specific rule matched"
        }

        if !specialApp {
            guard mustHaveIfJetBrainsApp(app, attributes.title, attributes.subrole, attributes.size),
                  mustHaveIfSteam(app, attributes.title, attributes.role),
                  mustHaveIfFusion360(app, attributes.title),
                  mustHaveIfColorSlurp(app, attributes.subrole)
            else { return "app-specific hard requirement failed" }
        }

        return nil
    }

    private static func hasNonEmptyTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func mustHaveIfFusion360(_ app: NSRunningApplication, _ title: String?) -> Bool {
        app.bundleIdentifier != "com.autodesk.fusion360" || hasNonEmptyTitle(title)
    }

    private static func mustHaveIfJetBrainsApp(_ app: NSRunningApplication, _ title: String?, _ subrole: String?, _ size: CGSize?) -> Bool {
        guard let bundleIdentifier = app.bundleIdentifier,
              bundleIdentifier.hasPrefix("com.jetbrains.") || bundleIdentifier.hasPrefix("com.google.android.studio")
        else { return true }

        return (subrole == kAXStandardWindowSubrole || hasNonEmptyTitle(title)) &&
            (size?.width ?? 0) > 100 &&
            (size?.height ?? 0) > 100
    }

    private static func mustHaveIfColorSlurp(_ app: NSRunningApplication, _ subrole: String?) -> Bool {
        app.bundleIdentifier != "com.IdeaPunch.ColorSlurp" || subrole == kAXStandardWindowSubrole
    }

    private static func keynote(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.apple.iWork.Keynote"
    }

    private static func preview(_ app: NSRunningApplication, _ subrole: String?) -> Bool {
        app.bundleIdentifier == "com.apple.Preview" && [kAXStandardWindowSubrole, kAXDialogSubrole].contains(subrole)
    }

    private static func openFLStudio(_ app: NSRunningApplication, _ title: String?) -> Bool {
        app.bundleIdentifier == "com.image-line.flstudio" && hasNonEmptyTitle(title)
    }

    private static func openBoard(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "org.oe-f.OpenBoard"
    }

    private static func adobeAudition(_ app: NSRunningApplication, _ subrole: String?) -> Bool {
        app.bundleIdentifier == "com.adobe.Audition" && subrole == kAXFloatingWindowSubrole
    }

    private static func adobeAfterEffects(_ app: NSRunningApplication, _ subrole: String?) -> Bool {
        app.bundleIdentifier == "com.adobe.AfterEffects" && subrole == kAXFloatingWindowSubrole
    }

    private static func books(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.apple.iBooksX"
    }

    private static func worldOfWarcraft(_ app: NSRunningApplication, _ role: String?) -> Bool {
        app.bundleIdentifier == "com.blizzard.worldofwarcraft" && role == kAXWindowRole
    }

    private static func battleNetBootstrapper(_ app: NSRunningApplication, _ role: String?) -> Bool {
        app.bundleIdentifier == "net.battle.bootstrapper" && role == kAXWindowRole
    }

    private static func drBetotte(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.ssworks.drbetotte"
    }

    private static func dvdFab(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.goland.dvdfab.macos"
    }

    private static func sanGuoShaAirWD(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "SanGuoShaAirWD"
    }

    private static func steam(_ app: NSRunningApplication, _ title: String?, _ role: String?) -> Bool {
        app.bundleIdentifier == "com.valvesoftware.steam" && hasNonEmptyTitle(title) && role != nil
    }

    private static func mustHaveIfSteam(_ app: NSRunningApplication, _ title: String?, _ role: String?) -> Bool {
        app.bundleIdentifier != "com.valvesoftware.steam" || (hasNonEmptyTitle(title) && role != nil)
    }

    private static func firefox(_ app: NSRunningApplication, _ role: String?, _ size: CGSize?) -> Bool {
        (app.bundleIdentifier?.hasPrefix("org.mozilla.firefox") ?? false) &&
            role == kAXWindowRole &&
            (size?.height ?? 0) > 400
    }

    private static func vlcFullscreenVideo(_ app: NSRunningApplication, _ role: String?) -> Bool {
        (app.bundleIdentifier?.hasPrefix("org.videolan.vlc") ?? false) && role == kAXWindowRole
    }

    private static func androidEmulator(_ app: NSRunningApplication, _ title: String?, _ role: String?, _ level: Int32?) -> Bool {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard app.bundleIdentifier == nil,
              role == kAXWindowRole,
              let title,
              !title.isEmpty,
              title != "Window",
              level == nil || level == normalLevel
        else { return false }
        return app.executableURL?.lastPathComponent.range(of: "qemu-system[^/]*$", options: .regularExpression) != nil
    }

    private static func crossoverWindow(_ app: NSRunningApplication, _ role: String?, _ subrole: String?, _ level: Int32) -> Bool {
        app.bundleIdentifier == nil &&
            role == kAXWindowRole &&
            subrole == unknownSubrole &&
            level == normalLevel &&
            (app.executableURL?.lastPathComponent == "wine64-preloader" || (app.executableURL?.absoluteString.contains("/winetemp-") ?? false))
    }

    private static func alwaysOnTopScrcpy(_ app: NSRunningApplication, _ level: Int32, _ role: String?, _ subrole: String?) -> Bool {
        app.executableURL?.lastPathComponent == "scrcpy" &&
            level == floatingLevel &&
            role == kAXWindowRole &&
            subrole == kAXStandardWindowSubrole
    }

    private static func autocad(_ app: NSRunningApplication, _ subrole: String?) -> Bool {
        (app.bundleIdentifier?.hasPrefix("com.autodesk.AutoCAD") ?? false) && subrole == documentWindowSubrole
    }
}

/// Heuristic mapping from AX window to CG window when _AXUIElementGetWindow fails
func mapAXToCG(attributes: WindowCandidateAttributes, candidates: [[String: AnyObject]], excluding: Set<CGWindowID>) -> CGWindowID? {
    let axTitle = attributes.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let axPos = attributes.position
    let axSize = attributes.size

    // 1) Exact title match among unused candidates
    if !axTitle.isEmpty {
        if let match = candidates.first(where: { desc in
            let title = (desc[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            return title == axTitle && !excluding.contains(wid)
        }) {
            return CGWindowID((match[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }
    }

    // 2) Geometry match within tolerance
    if let p = axPos, let s = axSize, s != .zero {
        let tol: CGFloat = 2.0
        if let match = candidates.first(where: { desc in
            let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            if excluding.contains(wid) {
                return false
            }
            let bounds = desc[kCGWindowBounds as String] as? [String: AnyObject]
            let rx = CGFloat((bounds?["X"] as? NSNumber)?.doubleValue ?? .infinity)
            let ry = CGFloat((bounds?["Y"] as? NSNumber)?.doubleValue ?? .infinity)
            let rw = CGFloat((bounds?["Width"] as? NSNumber)?.doubleValue ?? .infinity)
            let rh = CGFloat((bounds?["Height"] as? NSNumber)?.doubleValue ?? .infinity)
            let r = CGRect(x: rx, y: ry, width: rw, height: rh)
            let posMatch = abs(r.origin.x - p.x) <= tol && abs(r.origin.y - p.y) <= tol
            let sizeMatch = abs(r.size.width - s.width) <= tol && abs(r.size.height - s.height) <= tol
            return posMatch && sizeMatch
        }) {
            return CGWindowID((match[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }
    }

    // 3) Fuzzy title contains
    if !axTitle.isEmpty {
        if let match = candidates.first(where: { desc in
            let title = ((desc[kCGWindowName as String] as? String) ?? "").lowercased()
            let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            return !excluding.contains(wid) && title.contains(axTitle.lowercased())
        }) {
            return CGWindowID((match[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        }
    }

    return nil
}

// MARK: - Shared Helper Functions

/// Returns CG window candidates for a given PID.
func getCGWindowCandidates(for pid: pid_t) -> [[String: AnyObject]] {
    let cgAll = (CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]]) ?? []
    return cgAll.filter { desc in
        let owner = (desc[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
        return owner == pid
    }.sorted { first, second in
        let firstLayer = (first[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let secondLayer = (second[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        return firstLayer == 0 && secondLayer != 0
    }
}

/// Finds the CG window entry matching a given window ID in the candidates list
func findCGEntry(for windowID: CGWindowID, in candidates: [[String: AnyObject]]) -> [String: AnyObject]? {
    candidates.first { desc in
        let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        return wid == windowID
    }
}

// MARK: - Shared Validation

let AXMinWindowSize: CGSize = .init(width: 100, height: 100)

func isValidCGWindowCandidate(_ id: CGWindowID, in candidates: [[String: AnyObject]]) -> Bool {
    guard let match = candidates.first(where: { desc -> Bool in
        let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        return wid == id
    }) else { return false }

    let bounds = match[kCGWindowBounds as String] as? [String: AnyObject]
    let rw = CGFloat((bounds?["Width"] as? NSNumber)?.doubleValue ?? 0)
    let rh = CGFloat((bounds?["Height"] as? NSNumber)?.doubleValue ?? 0)
    let alpha = CGFloat((match[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0)
    if !WindowCandidateDiscriminator.hasUsableSize(CGSize(width: rw, height: rh)) {
        return false
    }
    if alpha <= 0.01 {
        return false
    }
    return true
}

/// Returns the set of currently active Space IDs across all displays.
func currentActiveSpaceIDs() -> Set<Int> {
    // Primary: ask macOS directly for the current space per display
    if let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: AnyObject]] {
        var result = Set<Int>()
        for display in displays {
            if let currentSpace = display["Current Space"] as? [String: AnyObject],
               let spaceID = (currentSpace["ManagedSpaceID"] as? NSNumber)?.intValue
            {
                result.insert(spaceID)
            }
        }
        if !result.isEmpty {
            return result
        }
    }

    // Fallback: infer from on-screen windows
    var result = Set<Int>()
    guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: AnyObject]] else { return result }
    for desc in list {
        let layer = (desc[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        let isOnscreen = (desc[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        guard layer == 0, isOnscreen else { continue }
        let wid = CGWindowID((desc[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
        for space in wid.cgsSpaces() {
            result.insert(Int(space))
        }
    }
    return result
}

enum WindowSpaces {
    private struct ManagedDisplay {
        let identifier: String
        let currentSpaceID: CGSSpaceID?
        let spaceIDs: Set<CGSSpaceID>
    }

    private static func spaceID(from dictionary: [String: AnyObject]?) -> CGSSpaceID? {
        if let managedSpaceID = dictionary?["ManagedSpaceID"] as? NSNumber {
            return managedSpaceID.uint64Value
        }
        if let id64 = dictionary?["id64"] as? NSNumber {
            return id64.uint64Value
        }
        return nil
    }

    private static func managedDisplays() -> [ManagedDisplay] {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: AnyObject]] else {
            return []
        }

        return displays.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let currentSpace = display["Current Space"] as? [String: AnyObject]
            let spaces = display["Spaces"] as? [[String: AnyObject]] ?? []

            return ManagedDisplay(
                identifier: identifier,
                currentSpaceID: spaceID(from: currentSpace),
                spaceIDs: Set(spaces.compactMap { spaceID(from: $0) })
            )
        }
    }

    private static func displayIdentifiers(for screen: NSScreen) -> Set<String> {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return []
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        var identifiers: Set<String> = [String(displayID)]

        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let uuidString = CFUUIDCreateString(nil, uuid) as String?
        {
            identifiers.insert(uuidString)
        }

        return identifiers
    }

    private static func screenContainingMouse(_ mouseLocation: CGPoint) -> NSScreen? {
        NSScreen.screens.first { screen in
            NSPointInRect(mouseLocation, screen.frame)
        }
    }

    static func currentManagedSpaceID(mouseLocation: CGPoint = NSEvent.mouseLocation) -> CGSSpaceID? {
        let displays = managedDisplays()
        guard !displays.isEmpty else { return nil }

        if let mouseScreen = screenContainingMouse(mouseLocation) {
            let screenIdentifiers = displayIdentifiers(for: mouseScreen)
                .map { $0.lowercased() }

            if let display = displays.first(where: { display in
                screenIdentifiers.contains(display.identifier.lowercased())
            }) {
                return display.currentSpaceID
            }
        }

        return displays.first?.currentSpaceID
    }

    @discardableResult
    static func move(windowID: CGWindowID, toManagedSpace targetSpaceID: CGSSpaceID) -> Bool {
        if windowID.cgsSpaces().contains(targetSpaceID) {
            return true
        }
        return move(windowIDs: [windowID], toManagedSpace: targetSpaceID)
    }

    /// Batched move; the target must be a managed space on some display.
    @discardableResult
    static func move(windowIDs: [CGWindowID], toManagedSpace targetSpaceID: CGSSpaceID) -> Bool {
        guard !windowIDs.isEmpty else { return true }
        let displays = managedDisplays()
        guard displays.contains(where: { display in
            display.currentSpaceID == targetSpaceID || display.spaceIDs.contains(targetSpaceID)
        }) else {
            DebugLogger.log("WindowSpaces.move", details: "Target Space \(targetSpaceID) not found")
            return false
        }
        return SLSMoveWindowsToManagedSpace(windowIDs, targetSpaceID)
    }

    /// True while Mission Control (or App Exposé) is showing: the Dock then owns
    /// screen-sized on-screen windows at layer 18, which never exist otherwise.
    static func isMissionControlActive() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in list where (window[kCGWindowOwnerName as String] as? String) == "Dock" {
            guard (window[kCGWindowLayer as String] as? Int) == 18,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"]
            else { continue }
            if NSScreen.screens.contains(where: { abs($0.frame.width - width) < 2 && abs($0.frame.height - height) < 2 }) {
                return true
            }
        }
        return false
    }

    /// Full ordered snapshot of every display's spaces, for the Space Switcher.
    /// Desktop numbers always follow Mission Control (main display first, then
    /// left to right); `order` only affects how the display rows are stacked.
    static func displaySpacesSnapshot(order: SpaceSwitcherDisplayOrder = .mainDisplayFirst) -> [DisplaySpaces] {
        guard let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: AnyObject]] else {
            return []
        }

        let parsed: [(identifier: String, screen: NSScreen?, currentSpaceID: CGSSpaceID?, spaceDicts: [[String: AnyObject]])] = displays.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            return (
                identifier: identifier,
                screen: screen(forDisplayIdentifier: identifier),
                currentSpaceID: spaceID(from: display["Current Space"] as? [String: AnyObject]),
                spaceDicts: display["Spaces"] as? [[String: AnyObject]] ?? []
            )
        }

        // Main screen's display first, remaining rows left-to-right; unresolved displays last.
        let ordered = parsed.sorted { a, b in
            switch (a.screen, b.screen) {
            case let (sa?, sb?):
                let mainA = sa == NSScreen.screens.first
                let mainB = sb == NSScreen.screens.first
                if mainA != mainB {
                    return mainA
                }
                return sa.frame.minX < sb.frame.minX
            case (nil, nil): return a.identifier < b.identifier
            case (nil, _): return false
            case (_, nil): return true
            }
        }

        // Desktop numbering is global and continuous across displays, matching
        // Mission Control (fullscreen-app spaces are unnumbered).
        var desktopCounter = 0
        let numbered = ordered.map { display in
            let spaces: [SpaceInfo] = display.spaceDicts.compactMap { dict in
                guard let id = spaceID(from: dict) else { return nil }
                let type = (dict["type"] as? NSNumber)?.intValue ?? 0
                if type != 4 {
                    desktopCounter += 1
                }
                return SpaceInfo(
                    id: id,
                    uuid: dict["uuid"] as? String ?? "",
                    type: type,
                    displayIdentifier: display.identifier,
                    desktopNumber: type == 4 ? 0 : desktopCounter,
                    isCurrent: id == display.currentSpaceID
                )
            }

            return DisplaySpaces(
                identifier: display.identifier,
                screen: display.screen,
                currentSpaceID: display.currentSpaceID,
                spaces: spaces
            )
        }
        var frames: [String: CGRect] = [:]
        for display in numbered {
            if let screen = display.screen {
                frames[display.identifier] = screen.frame
            }
        }
        let leadScreen: NSScreen? = switch order {
        case .displayWithMouseFirst: NSScreen.screenFromQuartzPoint(DockObserver.getMousePosition())
        case .displayWithActiveWindowFirst: SwitcherScreenPlacement.screenOfFocusedWindow()
            ?? NSScreen.screenFromQuartzPoint(DockObserver.getMousePosition())
        default: nil
        }
        let leadIdentifier = numbered.first { $0.screen != nil && $0.screen == leadScreen }?.identifier
        return reorderRows(numbered, order: order, frames: frames, leadIdentifier: leadIdentifier)
    }

    /// Applies the display-row order setting to a main-first, left-to-right
    /// list. `frames` holds AppKit screen frames by display identifier; displays
    /// without one keep their trailing position. `leadIdentifier` is the display
    /// promoted to the first row for the "… first" orders.
    static func reorderRows(
        _ displays: [DisplaySpaces],
        order: SpaceSwitcherDisplayOrder,
        frames: [String: CGRect],
        leadIdentifier: String? = nil
    ) -> [DisplaySpaces] {
        let resolved = displays.filter { frames[$0.identifier] != nil }
        let unresolved = displays.filter { frames[$0.identifier] == nil }
        func frame(_ d: DisplaySpaces) -> CGRect {
            frames[d.identifier] ?? .zero
        }

        func leftToRight(_ list: [DisplaySpaces]) -> [DisplaySpaces] {
            list.sorted { (frame($0).minX, -frame($0).maxY) < (frame($1).minX, -frame($1).maxY) }
        }

        func lead(_ list: [DisplaySpaces]) -> [DisplaySpaces] {
            guard let leadIdentifier, let index = list.firstIndex(where: { $0.identifier == leadIdentifier }) else { return list }
            var rest = list
            let head = rest.remove(at: index)
            return [head] + rest
        }

        let rows: [DisplaySpaces] = switch order {
        case .mainDisplayFirst:
            resolved
        case .leftToRight:
            leftToRight(resolved)
        case .topToBottom:
            // AppKit y grows upward; a higher maxY is physically higher.
            resolved.sorted { (frame($0).maxY, -frame($0).minX) > (frame($1).maxY, -frame($1).minX) }
        case .displayWithMouseFirst, .displayWithActiveWindowFirst:
            lead(leftToRight(resolved))
        }
        return rows + unresolved
    }

    static func screen(forDisplayIdentifier identifier: String) -> NSScreen? {
        let lowered = identifier.lowercased()
        return NSScreen.screens.first { screen in
            displayIdentifiers(for: screen).contains { $0.lowercased() == lowered }
        }
            // "Main" appears when displays don't have separate Spaces
            ?? (lowered == "main" ? NSScreen.screens.first : nil)
    }

    // MARK: - Dock-swipe gesture switching

    /// Undocumented CGEvent gesture fields, as used by yabai's SIP-on fallback
    /// (space_manager_focus_space_using_gesture) and InstantSpaceSwitcher.
    private enum DockGesture {
        static let eventType = CGEventField(rawValue: 55)! // kCGSEventTypeField
        static let hidType = CGEventField(rawValue: 110)! // kCGEventGestureHIDType
        static let swipeMotion = CGEventField(rawValue: 123)! // kCGEventGestureSwipeMotion
        static let swipeProgress = CGEventField(rawValue: 124)! // kCGEventGestureSwipeProgress
        static let swipeVelocityX = CGEventField(rawValue: 129)! // kCGEventGestureSwipeVelocityX
        static let gesturePhase = CGEventField(rawValue: 132)! // kCGEventGesturePhase

        static let dockControl: Int64 = 30 // kCGSEventDockControl
        static let dockSwipe: Int64 = 23 // kIOHIDEventTypeDockSwipe
        static let horizontal: Int64 = 1 // kCGGestureMotionHorizontal
        static let phaseBegan: Int64 = 1
        static let phaseEnded: Int64 = 4
    }

    /// Switches to a space by synthesizing Mission Control dock-swipe gestures.
    /// The Dock performs the actual switch, so Mission Control stays in sync —
    /// unlike calling CGSManagedDisplaySetCurrentSpace from outside the Dock.
    /// The gesture applies to the display under the cursor, so the cursor is
    /// warped to the target display first and restored unless `keepCursor`.
    @discardableResult
    static func switchViaDockGesture(to space: SpaceInfo, on display: DisplaySpaces, keepCursor: Bool) -> Bool {
        guard let currentID = display.currentSpaceID,
              let currentIndex = display.spaces.firstIndex(where: { $0.id == currentID }),
              let targetIndex = display.spaces.firstIndex(where: { $0.id == space.id }),
              currentIndex != targetIndex
        else { return false }

        guard !CGSManagedDisplayIsAnimating(CGSMainConnectionID(), display.identifier) else {
            DebugLogger.log("WindowSpaces.switchViaDockGesture", details: "display \(display.identifier) is animating")
            return false
        }

        // Warp the cursor to the target display when it's elsewhere
        var restorePoint: CGPoint?
        if let screen = display.screen,
           let primaryMaxY = NSScreen.screens.first?.frame.maxY,
           let cursor = CGEvent(source: nil)?.location
        {
            let screenCG = CGRect(
                x: screen.frame.origin.x,
                y: primaryMaxY - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            if !screenCG.contains(cursor) {
                restorePoint = cursor
                CGWarpMouseCursorPosition(CGPoint(x: screenCG.midX, y: screenCG.midY))
            }
        }

        let steps = abs(targetIndex - currentIndex)
        let sign: Double = targetIndex > currentIndex ? 1.0 : -1.0

        // Stagger multi-step swipes slightly so the Dock doesn't drop swipes
        // that arrive mid-animation on longer jumps.
        for step in 0 ..< steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.12) {
                postDockSwipe(sign: sign)
            }
        }

        if let restorePoint, !keepCursor {
            scheduleCursorRestore(to: restorePoint, delay: 0.35 + Double(steps - 1) * 0.12)
        }
        return true
    }

    private static func postDockSwipe(sign: Double) {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(DockGesture.eventType, value: DockGesture.dockControl)
        event.setIntegerValueField(DockGesture.hidType, value: DockGesture.dockSwipe)
        event.setIntegerValueField(DockGesture.swipeMotion, value: DockGesture.horizontal)
        event.setDoubleValueField(DockGesture.swipeProgress, value: sign)
        event.setDoubleValueField(DockGesture.swipeVelocityX, value: sign * 9999.0)
        event.setIntegerValueField(DockGesture.gesturePhase, value: DockGesture.phaseBegan)
        event.post(tap: .cgSessionEventTap)
        event.setIntegerValueField(DockGesture.gesturePhase, value: DockGesture.phaseEnded)
        event.post(tap: .cgSessionEventTap)
    }

    private static var cursorRestoreWork: DispatchWorkItem?

    /// Restores the cursor after a warp, unless the user has moved it since —
    /// and coalesces with any pending restore from a rapid earlier switch.
    private static func scheduleCursorRestore(to restorePoint: CGPoint, delay: TimeInterval) {
        cursorRestoreWork?.cancel()
        let warpedTo = CGEvent(source: nil)?.location
        let work = DispatchWorkItem {
            guard let warpedTo,
                  let current = CGEvent(source: nil)?.location,
                  abs(current.x - warpedTo.x) < 20, abs(current.y - warpedTo.y) < 20
            else { return }
            CGWarpMouseCursorPosition(restorePoint)
        }
        cursorRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @discardableResult
    static func setCurrentSpace(_ targetSpaceID: CGSSpaceID, onDisplay displayIdentifier: String) -> Bool {
        let displays = displaySpacesSnapshot()
        guard let display = displays.first(where: { $0.identifier == displayIdentifier }),
              display.spaces.contains(where: { $0.id == targetSpaceID })
        else {
            DebugLogger.log("WindowSpaces.setCurrentSpace", details: "Space \(targetSpaceID) not found on display \(displayIdentifier)")
            return false
        }

        guard display.currentSpaceID != targetSpaceID else { return true }
        return CGSManagedDisplaySetCurrentSpace(CGSMainConnectionID(), displayIdentifier, targetSpaceID)
    }
}

/// Decide if a window should be accepted considering on-screen state,
/// ScreenCaptureKit presence, multi-Space, and window/app state.
func shouldAcceptWindow(axWindow: AXUIElement,
                        windowID: CGWindowID,
                        cgEntry: [String: AnyObject],
                        app: NSRunningApplication,
                        activeSpaceIDs: Set<Int>,
                        scBacked: Bool) -> Bool
{
    // Base: role/subrole, level, size/alpha checks already enforced by caller
    let isOnscreen = (cgEntry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    let axIsFullscreen = (try? axWindow.isFullscreen()) ?? false
    let axIsMinimized = (try? axWindow.isMinimized()) ?? false
    let windowSpaces = Set(windowID.cgsSpaces().map { Int($0) })

    let isOnActiveSpace = !windowSpaces.isEmpty && !windowSpaces.isDisjoint(with: activeSpaceIDs)
    let isGhostWindow = !isOnscreen && isOnActiveSpace && !axIsMinimized && !axIsFullscreen && !app.isHidden
    if isGhostWindow {
        return false
    }

    if isOnscreen || scBacked {
        return true
    }

    if app.isHidden || axIsFullscreen || axIsMinimized {
        return true
    }

    // Window on different Space — but reject if not onscreen and not minimized/fullscreen/hidden (ghost with stale space ID)
    if !windowSpaces.isEmpty, windowSpaces.isDisjoint(with: activeSpaceIDs) {
        if !isOnscreen, !axIsMinimized, !axIsFullscreen, !app.isHidden {
            return false
        }
        return true
    }

    // Fallback: if AX marks it as main, consider it significant and include.
    // This helps when CGS space mapping is unreliable or empty for other-Spaces windows.
    if (try? axWindow.attribute(kAXMainAttribute, Bool.self)) == true {
        return true
    }

    return false
}
