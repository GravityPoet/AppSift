import Darwin
import Foundation
import IOKit
import IOKit.ps

struct SystemVolumeSnapshot: Identifiable, Codable, Hashable, Sendable {
    let path: String
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isReadOnly: Bool

    var id: String { path }
    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

struct SystemBatterySnapshot: Codable, Hashable, Sendable {
    let percentage: Int
    let isCharging: Bool
    let isConnectedToPower: Bool
    let healthPercentage: Int?
    let cycleCount: Int?
    let condition: String?
}

struct SystemDeviceBatterySnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let percentage: Int
    let isCharging: Bool?
}

struct SystemMemorySnapshot: Codable, Hashable, Sendable {
    let usedBytes: Int64
    let totalBytes: Int64
    let swapUsedBytes: Int64

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

struct SystemTrashSnapshot: Codable, Hashable, Sendable {
    let itemCount: Int
    let oldItemCount: Int
    let oldestModificationDate: Date?
}

enum SystemTelemetryReader {
    static func mountedVolumes() -> [SystemVolumeSnapshot] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsReadOnlyKey,
            .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        var seen = Set<String>()
        return urls.compactMap { url -> SystemVolumeSnapshot? in
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted,
                  let values = try? standardized.resourceValues(forKeys: keys),
                  values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity,
                  total > 0 else { return nil }
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            return SystemVolumeSnapshot(
                path: standardized.path,
                name: values.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty ?? standardized.lastPathComponent.nilIfEmpty ?? String(localized: "Macintosh HD"),
                totalBytes: Int64(total),
                availableBytes: Int64(max(0, available)),
                isInternal: values.volumeIsInternal ?? !((values.volumeIsRemovable) ?? false),
                isRemovable: values.volumeIsRemovable ?? false,
                isReadOnly: values.volumeIsReadOnly ?? false
            )
        }
        .sorted {
            if $0.path == "/" { return true }
            if $1.path == "/" { return false }
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func internalBattery() -> SystemBatterySnapshot? {
        let powerInfo = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sourceList = IOPSCopyPowerSourcesList(powerInfo).takeRetainedValue() as [CFTypeRef]
        var percentage: Int?
        var charging = false
        var connected = false
        for source in sourceList {
            guard let raw = IOPSGetPowerSourceDescription(powerInfo, source)?.takeUnretainedValue(),
                  let description = raw as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else {
                continue
            }
            let current = number(description[kIOPSCurrentCapacityKey]) ?? 0
            let maximum = max(1, number(description[kIOPSMaxCapacityKey]) ?? 100)
            percentage = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
            connected = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            break
        }
        guard let percentage else { return nil }

        let properties = smartBatteryProperties()
        let maximumCapacity = number(properties?["AppleRawMaxCapacity"])
            ?? number(properties?["MaxCapacity"])
        let designCapacity = number(properties?["DesignCapacity"])
        let health: Int?
        if let maximumCapacity, let designCapacity, designCapacity > 0 {
            health = min(100, max(0, Int((Double(maximumCapacity) / Double(designCapacity) * 100).rounded())))
        } else {
            health = nil
        }
        let condition = sanitized(properties?["BatteryHealthCondition"] as? String)
            ?? sanitized(properties?["BatteryHealth"] as? String)
        return SystemBatterySnapshot(
            percentage: percentage,
            isCharging: charging,
            isConnectedToPower: connected,
            healthPercentage: health,
            cycleCount: number(properties?["CycleCount"]),
            condition: condition
        )
    }

    static func connectedDeviceBatteries() -> [SystemDeviceBatterySnapshot] {
        guard let matching = IOServiceMatching("AppleDeviceManagementHIDEventService") else {
            return []
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var results: [SystemDeviceBatterySnapshot] = []
        var seen = Set<String>()
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            guard let properties = registryProperties(service),
                  let percentage = number(properties["BatteryPercent"] ?? properties["BatteryLevel"]),
                  (0...100).contains(percentage) else { continue }
            let transport = sanitized(properties["Transport"] as? String)?.lowercased()
            guard transport == nil || transport?.contains("bluetooth") == true else { continue }
            let name = sanitized(properties["Product"] as? String)
                ?? sanitized(properties["ProductName"] as? String)
                ?? String(localized: "Bluetooth Device")
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            let identifier = registryID == 0 ? "\(name)|\(percentage)" : String(registryID)
            guard seen.insert(identifier).inserted else { continue }
            results.append(
                SystemDeviceBatterySnapshot(
                    id: identifier,
                    name: name,
                    percentage: percentage,
                    isCharging: properties["IsCharging"] as? Bool
                )
            )
        }
        return results.sorted {
            if $0.percentage != $1.percentage { return $0.percentage < $1.percentage }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func networkByteTotals() -> (received: UInt64, sent: UInt64)? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = pointer {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            if flags & IFF_UP != 0,
               flags & IFF_LOOPBACK == 0,
               interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
               let dataPointer = interface.ifa_data {
                let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                received &+= UInt64(data.ifi_ibytes)
                sent &+= UInt64(data.ifi_obytes)
            }
            pointer = interface.ifa_next
        }
        return (received, sent)
    }

    static func memorySnapshot() -> SystemMemorySnapshot? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride
                / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let used = (
            Int64(statistics.active_count)
                + Int64(statistics.wire_count)
                + Int64(statistics.compressor_page_count)
        ) * Int64(pageSize)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        return SystemMemorySnapshot(
            usedBytes: max(0, used),
            totalBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            swapUsedBytes: swapResult == 0 ? Int64(swap.xsu_used) : 0
        )
    }

    static func trashSnapshot(
        olderThan cutoff: Date = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    ) -> SystemTrashSnapshot? {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL
        var rootInformation = stat()
        guard lstat(root.path, &rootInformation) == 0,
              rootInformation.st_mode & S_IFMT == S_IFDIR,
              rootInformation.st_uid == getuid(),
              rootInformation.st_mode & S_IWOTH == 0 else {
            return nil
        }
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .isSymbolicLinkKey,
        ]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return nil }
        var oldCount = 0
        var oldest: Date?
        for child in children.prefix(100_000) {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  let modified = values.contentModificationDate else { continue }
            if modified < cutoff { oldCount += 1 }
            if oldest == nil || modified < oldest! { oldest = modified }
        }
        return SystemTrashSnapshot(
            itemCount: min(children.count, 100_000),
            oldItemCount: oldCount,
            oldestModificationDate: oldest
        )
    }

    private static func smartBatteryProperties() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return registryProperties(service)
    }

    private static func registryProperties(_ service: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &unmanaged,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
        let dictionary = unmanaged?.takeRetainedValue() else { return nil }
        return dictionary as? [String: Any]
    }

    private static func number(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Int { return value }
        return nil
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 256 else { return nil }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
