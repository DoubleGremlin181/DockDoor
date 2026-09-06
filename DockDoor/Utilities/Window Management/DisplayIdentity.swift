import AppKit

/// Stable identity of a physical display, independent of the transient
/// `CGDirectDisplayID`. Keyed by the CoreGraphics display UUID (the same value
/// macOS writes to com.apple.spaces as "Display Identifier"), with a
/// disambiguating suffix when two attached displays share one.
struct DisplayIdentity: Codable, Hashable {
    let key: String
    let uuid: String?
    let isBuiltin: Bool
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let localizedName: String
    /// Display bounds size (points) at capture, for frame scaling on restore
    let pointSize: CGSize
}

extension DisplayIdentity {
    /// Raw facts about one online display, gathered impurely by `probe(_:)` so
    /// keying itself stays pure and testable.
    struct Probe: Hashable {
        let displayID: CGDirectDisplayID
        let uuid: String?
        let isBuiltin: Bool
        let vendor: UInt32
        let model: UInt32
        let serial: UInt32
        let localizedName: String
        /// CG global coordinates (origin top-left)
        let bounds: CGRect
    }

    static func probe(_ displayID: CGDirectDisplayID) -> Probe {
        var uuidString: String?
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            uuidString = CFUUIDCreateString(nil, uuid) as String?
        }
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        return Probe(
            displayID: displayID,
            uuid: uuidString,
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            serial: CGDisplaySerialNumber(displayID),
            localizedName: screen?.localizedName ?? "",
            bounds: CGDisplayBounds(displayID)
        )
    }

    static func onlineProbes() -> [Probe] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(probe)
    }

    /// Key before collision handling: the UUID, else vendor/model/serial, else
    /// a built-in marker.
    static func baseKey(for probe: Probe) -> String {
        if let uuid = probe.uuid, !uuid.isEmpty {
            return uuid.uppercased()
        }
        if probe.vendor != 0 || probe.model != 0 || probe.serial != 0 {
            return "vms:\(probe.vendor)-\(probe.model)-\(probe.serial)"
        }
        return probe.isBuiltin ? "builtin" : "unknown:\(Int(probe.bounds.width))x\(Int(probe.bounds.height))"
    }

    /// Identities for a set of simultaneously attached displays. Displays that
    /// share a base key (identical monitors with degenerate EDID serials) get a
    /// positional `#n` suffix ordered by arrangement (left to right, then top
    /// to bottom); a lone display never carries a suffix.
    static func identities(for probes: [Probe]) -> [CGDirectDisplayID: DisplayIdentity] {
        var groups: [String: [Probe]] = [:]
        for probe in probes {
            groups[baseKey(for: probe), default: []].append(probe)
        }

        var result: [CGDirectDisplayID: DisplayIdentity] = [:]
        for (base, members) in groups {
            let ordered = members.sorted { a, b in
                (a.bounds.minX, a.bounds.minY, a.displayID) < (b.bounds.minX, b.bounds.minY, b.displayID)
            }
            for (index, probe) in ordered.enumerated() {
                let key = ordered.count > 1 ? "\(base)#\(index)" : base
                result[probe.displayID] = DisplayIdentity(
                    key: key,
                    uuid: probe.uuid,
                    isBuiltin: probe.isBuiltin,
                    vendor: probe.vendor,
                    model: probe.model,
                    serial: probe.serial,
                    localizedName: probe.localizedName,
                    pointSize: probe.bounds.size
                )
            }
        }
        return result
    }
}
