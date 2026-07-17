import Foundation

struct CLI {
    private final class BlockingResult<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func store(_ value: Value) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func take() -> Value {
            lock.lock()
            defer { lock.unlock() }
            guard let value else {
                preconditionFailure("Async CLI operation completed without a result")
            }
            return value
        }
    }

    private static let knownCommands: Set<String> = [
        "scan", "disk-info", "list", "extensions", "default-apps",
        "app-updates", "app-usage", "installation-files", "app-permissions",
        "app-relationships",
        "help", "--help", "-h",
        "version", "--version", "-v",
    ]

    static func isKnownCommand(_ arg: String) -> Bool {
        knownCommands.contains(arg)
    }

    static func run() -> Never {
        let args = Array(CommandLine.arguments.dropFirst())

        guard let command = args.first else {
            printUsage()
            exit(0)
        }

        switch command {
        case "scan":
            handleScan(args: Array(args.dropFirst()))
        case "disk-info":
            handleDiskInfo()
        case "list":
            handleList()
        case "extensions":
            handleExtensions(args: Array(args.dropFirst()))
        case "default-apps":
            handleDefaultApplications(args: Array(args.dropFirst()))
        case "app-updates":
            handleAppUpdates(args: Array(args.dropFirst()))
        case "app-usage":
            handleAppUsage(args: Array(args.dropFirst()))
        case "installation-files":
            handleInstallationFiles(args: Array(args.dropFirst()))
        case "app-permissions":
            handleAppPermissions(args: Array(args.dropFirst()))
        case "app-relationships":
            handleAppRelationships(args: Array(args.dropFirst()))
        case "help", "--help", "-h":
            printUsage()
        case "version", "--version", "-v":
            printVersion()
        default:
            printError("Unknown command: \(command)")
            printUsage()
            exit(1)
        }
        exit(0)
    }

    // MARK: - Commands

    private static func handleScan(args: [String]) {
        let json = args.contains("--json")
        let categoryFilter = extractValue(for: "--category", in: args)

        let engine = ScanEngine()
        let categories: [CleaningCategory]

        if let filter = categoryFilter {
            guard let cat = CleaningCategory.scannable.first(where: {
                $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") ==
                filter.lowercased().replacingOccurrences(of: " ", with: "")
            }) else {
                printError("Unknown category: \(filter)")
                print("Available: \(CleaningCategory.scannable.map(\.rawValue).joined(separator: ", "))")
                exit(1)
            }
            categories = [cat]
        } else {
            categories = CleaningCategory.scannable
        }

        let allResults: [(String, Int, Int64)] = waitForAsync {
            await withTaskGroup(
                of: (String, Int, Int64).self,
                returning: [(String, Int, Int64)].self
            ) { group in
                for category in categories {
                    group.addTask {
                        let result = await engine.scanCategory(category)
                        return (category.rawValue, result.itemCount, result.totalSize)
                    }
                }

                var results: [(String, Int, Int64)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
        }

        if json {
            printJSON(allResults)
        } else {
            printTable(allResults)
        }
    }

    private static func handleDiskInfo() {
        let engine = ScanEngine()
        let info: DiskInfo = waitForAsync {
            await engine.getDiskInfo()
        }

        print("Disk Usage:")
        print("  Total:     \(info.formattedTotal)")
        print("  Used:      \(info.formattedUsed)")
        print("  Free:      \(info.formattedFree)")
        if info.purgeableSpace > 0 {
            print("  Purgeable: \(info.formattedPurgeable)")
        }
    }

    private static func handleList() {
        let apps = AppInfoFetcher.shared.fetchInstalledApps()
        print("Installed Apps (\(apps.count)):")
        for app in apps {
            let size = ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file)
            print("  \(app.appName.padding(toLength: 35, withPad: " ", startingAt: 0)) \(size.padding(toLength: 12, withPad: " ", startingAt: 0)) \(app.bundleIdentifier)")
        }
    }

    private static func handleExtensions(args: [String]) {
        let json = args.contains("--json")
        let apps = AppInfoFetcher.shared.discoverInstalledApps()
        let result = ManagedExtensionScanner.scan(
            ownerApps: apps.map(ExtensionOwnerApp.init(app:))
        )

        if json {
            let rows: [[String: Any]] = result.items.map { item in
                [
                    "name": item.name,
                    "identifier": item.identifier,
                    "version": item.version as Any? ?? NSNull(),
                    "kind": item.kind.rawValue,
                    "state": item.state.rawValue,
                    "scope": item.scope.rawValue,
                    "owner": item.owner?.name as Any? ?? NSNull(),
                    "teamIdentifier": item.teamIdentifier as Any? ?? NSNull(),
                    "developer": item.developerName as Any? ?? NSNull(),
                    "profile": item.profileName as Any? ?? NSNull(),
                    "path": item.url?.path as Any? ?? NSNull(),
                    "permissionCount": item.permissionCount as Any? ?? NSNull(),
                    "evidence": item.evidence.map(\.rawValue).sorted(),
                ]
            }
            guard JSONSerialization.isValidJSONObject(rows),
                  let data = try? JSONSerialization.data(
                    withJSONObject: rows,
                    options: [.prettyPrinted, .sortedKeys]
                  ),
                  let output = String(data: data, encoding: .utf8) else {
                printError("Could not encode extension inventory")
                exit(1)
            }
            print(output)
        } else {
            print("Extensions (\(result.items.count)):")
            for item in result.items {
                let name = terminalSafe(item.name)
                let owner = item.owner.map { terminalSafe($0.name) } ?? "—"
                print(
                    "  [\(item.state.rawValue)] "
                        + "\(item.kind.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)) "
                        + "\(name.isEmpty ? "—" : name) · \(owner.isEmpty ? "—" : owner)"
                )
            }
        }

        if !result.incompleteSources.isEmpty {
            let sources = result.incompleteSources.map(\.rawValue).sorted()
                .joined(separator: ", ")
            FileHandle.standardError.write(
                Data("Warning: incomplete extension sources: \(sources)\n".utf8)
            )
        }
    }

    private static func handleDefaultApplications(args: [String]) {
        let json = args.contains("--json")
        let apps = AppInfoFetcher.shared.discoverInstalledApps()
        let result = DefaultApplicationScanner.scan(
            applicationURLs: apps.map(\.path)
        )

        if json {
            let rows: [[String: Any]] = result.items.map { item in
                [
                    "name": item.displayName,
                    "contentType": item.contentTypeIdentifier,
                    "extensions": item.filenameExtensions,
                    "category": item.category.rawValue,
                    "defaultApplication": [
                        "name": item.currentApplication.name,
                        "bundleIdentifier": item.currentApplication.bundleIdentifier,
                        "path": item.currentApplication.url.path,
                    ],
                    "candidateApplications": item.candidateApplications.map {
                        [
                            "name": $0.name,
                            "bundleIdentifier": $0.bundleIdentifier,
                            "path": $0.url.path,
                        ]
                    },
                    "evidence": item.evidence.map(\.rawValue).sorted(),
                ]
            }
            guard JSONSerialization.isValidJSONObject(rows),
                  let data = try? JSONSerialization.data(
                    withJSONObject: rows,
                    options: [.prettyPrinted, .sortedKeys]
                  ),
                  let output = String(data: data, encoding: .utf8) else {
                printError("Could not encode default application inventory")
                exit(1)
            }
            print(output)
        } else {
            print("Default Applications (\(result.items.count)):")
            for item in result.items {
                let extensions = item.filenameExtensions
                    .prefix(4)
                    .map { ".\($0)" }
                    .joined(separator: ", ")
                let extensionSummary = extensions.isEmpty ? "—" : extensions
                print(
                    "  \(extensionSummary) "
                        + "\(terminalSafe(item.displayName)) → "
                        + terminalSafe(item.currentApplication.name)
                )
            }
        }

        if result.unreadableApplicationDeclarationCount > 0
            || result.wasTruncated {
            let warning = "Warning: default application inventory may be incomplete "
                + "(unreadable app declarations: "
                + "\(result.unreadableApplicationDeclarationCount), "
                + "truncated: \(result.wasTruncated))\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
    }

    private static func handleInstallationFiles(args: [String]) {
        let json = args.contains("--json")
        let apps = AppInfoFetcher.shared.discoverInstalledApps()
            .map(InstallationFileApplicationReference.init(app:))
        let result: InstallationFileScanResult = waitForAsync {
            await InstallationFileScanner.discover(installedApps: apps)
        }

        if json {
            let formatter = ISO8601DateFormatter()
            let rows: [[String: Any]] = result.items.map { item in
                let protectionReason: Any
                switch item.removalEligibility {
                case .eligible:
                    protectionReason = NSNull()
                case .protected(let reason):
                    protectionReason = reason.rawValue
                }
                return [
                    "name": item.name,
                    "path": item.url.path,
                    "kind": item.kind.rawValue,
                    "bytes": item.size,
                    "createdAt": item.createdAt.map(formatter.string(from:)) as Any? ?? NSNull(),
                    "modifiedAt": item.modifiedAt.map(formatter.string(from:)) as Any? ?? NSNull(),
                    "quarantineOrigin": item.quarantineOriginURL?.absoluteString as Any? ?? NSNull(),
                    "quarantineAgent": item.quarantineAgentName as Any? ?? NSNull(),
                    "signature": [
                        "status": item.signature.status.rawValue,
                        "teamIdentifier": item.signature.teamIdentifier as Any? ?? NSNull(),
                        "developer": item.signature.developerName as Any? ?? NSNull(),
                        "notarization": item.signature.notarizationStatus.rawValue,
                    ],
                    "relatedApplication": item.relatedApplication.map {
                        [
                            "name": $0.name,
                            "bundleIdentifier": $0.bundleIdentifier,
                            "path": $0.url.path,
                        ]
                    } as Any? ?? NSNull(),
                    "containedApplication": item.containedApplicationName
                        as Any? ?? NSNull(),
                    "removable": item.isRemovable,
                    "protectionReason": protectionReason,
                    "evidence": item.evidence.map(\.rawValue).sorted(),
                ]
            }
            let payload: [String: Any] = [
                "items": rows,
                "ignoredPathCount": result.ignoredPathCount,
                "inaccessibleCandidateCount": result.inaccessibleCandidateCount,
                "wasTruncated": result.wasTruncated,
                "wasCancelled": result.wasCancelled,
                "scannedAt": formatter.string(from: result.scannedAt),
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                  ),
                  let output = String(data: data, encoding: .utf8) else {
                printError("Could not encode installation file inventory")
                exit(1)
            }
            print(output)
        } else {
            print("Installation Files (\(result.items.count)):")
            for item in result.items {
                let size = ByteCountFormatter.string(
                    fromByteCount: item.size,
                    countStyle: .file
                )
                let protection: String
                switch item.removalEligibility {
                case .eligible:
                    protection = "removable"
                case .protected(let reason):
                    protection = "protected: \(reason.rawValue)"
                }
                print(
                    "  [\(item.kind.rawValue)] \(terminalSafe(item.name)) "
                        + "· \(size) · \(protection)"
                )
                print("      \(terminalSafe(item.url.path))")
                if let applicationName = item.containedApplicationName {
                    print("      contains: \(terminalSafe(applicationName)).app")
                }
            }
            let removableSize = ByteCountFormatter.string(
                fromByteCount: result.removableSize,
                countStyle: .file
            )
            print(
                "Removable: \(removableSize) · protected: \(result.protectedCount) "
                    + "· ignored: \(result.ignoredPathCount)"
            )
        }

        if result.wasTruncated || result.wasCancelled
            || result.inaccessibleCandidateCount > 0 {
            let warning = "Warning: installation file inventory may be incomplete "
                + "(inaccessible: \(result.inaccessibleCandidateCount), "
                + "truncated: \(result.wasTruncated), "
                + "cancelled: \(result.wasCancelled))\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
    }

    private static func handleAppUpdates(args: [String]) {
        let json = args.contains("--json")
        let apps = AppInfoFetcher.shared.discoverInstalledApps()
        let result: AppUpdateScanResult = waitForAsync {
            await AppUpdateScanner.scan(apps: apps)
        }

        if json {
            let formatter = ISO8601DateFormatter()
            let rows: [[String: Any]] = result.items.map { item in
                [
                    "name": item.appName,
                    "bundleIdentifier": item.bundleIdentifier,
                    "path": item.appURL.path,
                    "currentVersion": item.currentVersion as Any? ?? NSNull(),
                    "currentBuild": item.currentBuild as Any? ?? NSNull(),
                    "availableVersion": item.availableVersion as Any? ?? NSNull(),
                    "status": item.status.rawValue,
                    "source": appUpdateSourcePayload(item.source),
                    "evidence": item.evidence.map(\.rawValue).sorted(),
                    "releaseNotesURL": item.releaseNotesURL?.absoluteString
                        as Any? ?? NSNull(),
                    "failureReason": item.failureReason?.rawValue
                        as Any? ?? NSNull(),
                    "checkedAt": formatter.string(from: item.checkedAt),
                ]
            }
            let payload: [String: Any] = [
                "items": rows,
                "availableUpdateCount": result.availableUpdateCount,
                "unsupportedAppCount": result.unsupportedAppCount,
                "checkedAt": formatter.string(from: result.checkedAt),
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                  ),
                  let output = String(data: data, encoding: .utf8) else {
                printError("Could not encode app update inventory")
                exit(1)
            }
            print(output)
        } else {
            print(
                "Application Updates (\(result.items.count) checked, "
                    + "\(result.availableUpdateCount) available):"
            )
            for item in result.items {
                let current = terminalSafe(item.currentVersion ?? "unknown")
                let available = item.availableVersion.map {
                    " → \(terminalSafe($0))"
                } ?? ""
                let failure = item.failureReason.map {
                    " · \(terminalSafe($0.rawValue))"
                } ?? ""
                print(
                    "  [\(item.status.rawValue)] "
                        + "\(terminalSafe(item.appName)) "
                        + "\(current)\(available) · "
                        + "\(appUpdateSourceDescription(item.source))\(failure)"
                )
            }
            print("Unsupported applications: \(result.unsupportedAppCount)")
        }
    }

    private static func handleAppUsage(args: [String]) {
        guard let options = AppUsageCLIOptions.parse(args) else {
            printError("Usage: app-usage [--days 30|90|180] [--json]")
            exit(1)
        }

        let apps = AppInfoFetcher.shared.fetchInstalledApps()
        let report = AppUsageReport.make(
            applications: apps,
            thresholdDays: options.thresholdDays
        )

        if options.outputsJSON {
            guard let data = try? report.encodedJSON(),
                  let output = String(data: data, encoding: .utf8) else {
                printError("Could not encode application usage inventory")
                exit(1)
            }
            print(output)
            return
        }

        print(
            "Application Usage (\(report.summary.total) apps, "
                + "threshold: \(report.thresholdDays) days):"
        )
        print(
            "  Unused: \(report.summary.unused) · "
                + "recently used: \(report.summary.recentlyUsed) · "
                + "no reliable record: \(report.summary.unknown)"
        )
        let formatter = ISO8601DateFormatter()
        for item in report.applications {
            let lastUsed = item.lastUsedAt.map(formatter.string(from:)) ?? "no reliable record"
            print(
                "  [\(item.status.rawValue)] \(terminalSafe(item.name)) "
                    + "· last opened: \(lastUsed) · \(terminalSafe(item.path))"
            )
        }
    }

    private static func appUpdateSourcePayload(
        _ source: AppUpdateSource
    ) -> [String: Any] {
        switch source {
        case .macAppStore(let productIdentifier):
            return [
                "type": "macAppStore",
                "productIdentifier": productIdentifier as Any? ?? NSNull(),
            ]
        case .homebrewCask(let token, let executable):
            return [
                "type": "homebrewCask",
                "token": token,
                "executable": executable?.path as Any? ?? NSNull(),
            ]
        case .sparkle(let feedURL):
            return [
                "type": "sparkle",
                "feedURL": feedURL?.absoluteString as Any? ?? NSNull(),
            ]
        case .electronUpdater(let provider, let channel):
            switch provider {
            case .generic(let baseURL):
                return [
                    "type": "electronGeneric",
                    "baseURL": baseURL.absoluteString,
                    "channel": channel,
                ]
            case .github(let owner, let repo):
                return [
                    "type": "electronGitHub",
                    "owner": owner,
                    "repository": repo,
                    "channel": channel,
                ]
            }
        }
    }

    private static func appUpdateSourceDescription(
        _ source: AppUpdateSource
    ) -> String {
        switch source {
        case .macAppStore:
            return "Mac App Store"
        case .homebrewCask(let token, _):
            return "Homebrew \(terminalSafe(token))"
        case .sparkle:
            return "Sparkle"
        case .electronUpdater(let provider, _):
            switch provider {
            case .generic:
                return "Electron generic"
            case .github(let owner, let repo):
                return "GitHub \(terminalSafe(owner))/\(terminalSafe(repo))"
            }
        }
    }

    private static func handleAppPermissions(args: [String]) {
        let json = args.contains("--json")
        let applications = AppInfoFetcher.shared.discoverInstalledApps()
            .map(AppPermissionApplicationReference.init(app:))
        let result = AppPermissionScanner.scan(applications: applications)
        let formatter = ISO8601DateFormatter()

        if json {
            let clients: [[String: Any]] = result.clients.map { client in
                [
                    "name": client.name,
                    "clientIdentifier": client.clientIdentifier,
                    "clientType": client.clientType,
                    "bundleIdentifier": client.bundleIdentifier as Any? ?? NSNull(),
                    "applicationPath": client.applicationURL?.path as Any? ?? NSNull(),
                    "version": client.version as Any? ?? NSNull(),
                    "installed": client.isInstalled,
                    "stale": client.isStale,
                    "records": client.records.map { record in
                        [
                            "service": record.service.rawValue,
                            "name": record.service.displayNameKey,
                            "category": record.service.category.rawValue,
                            "scope": record.scope.rawValue,
                            "decision": record.decision.rawValue,
                            "authorizationValue": record.authorizationValue,
                            "authorizationReason": record.authorizationReason as Any? ?? NSNull(),
                            "indirectObjectIdentifier": record.indirectObjectIdentifier as Any? ?? NSNull(),
                            "lastModified": record.lastModified.map(formatter.string(from:)) as Any? ?? NSNull(),
                            "resetSupported": record.service.resetServiceName != nil,
                        ] as [String: Any]
                    },
                    "declarations": client.declarations.map { declaration in
                        [
                            "service": declaration.service.rawValue,
                            "name": declaration.service.displayNameKey,
                            "propertyListKey": declaration.propertyListKey,
                            "purpose": declaration.purpose,
                        ]
                    },
                ]
            }
            let sources: [[String: Any]] = result.sources.map { source in
                [
                    "scope": source.scope.rawValue,
                    "path": source.path,
                    "status": source.status.rawValue,
                    "rowCount": source.rowCount,
                    "sqliteResultCode": source.sqliteResultCode as Any? ?? NSNull(),
                ]
            }
            let payload: [String: Any] = [
                "clients": clients,
                "sources": sources,
                "recordCount": result.recordCount,
                "allowedCount": result.allowedCount,
                "deniedCount": result.deniedCount,
                "highImpactAllowedCount": result.highImpactAllowedCount,
                "staleClientCount": result.staleClientCount,
                "wasTruncated": result.wasTruncated,
                "wasCancelled": result.wasCancelled,
                "scannedAt": formatter.string(from: result.scannedAt),
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                  ),
                  let output = String(data: data, encoding: .utf8) else {
                printError("Could not encode privacy permission inventory")
                exit(1)
            }
            print(output)
        } else {
            print("Privacy Permissions (\(result.clients.count) clients, \(result.recordCount) decisions):")
            for client in result.clients {
                let identity = terminalSafe(client.bundleIdentifier ?? client.clientIdentifier)
                print("  \(terminalSafe(client.name)) · \(identity)")
                for record in client.records {
                    print(
                        "      [\(record.decision.rawValue)] "
                            + "\(terminalSafe(record.service.displayNameKey)) "
                            + "· \(record.scope.rawValue)"
                    )
                }
                if client.records.isEmpty, !client.declarations.isEmpty {
                    print("      declared only · \(client.declarations.count) usage descriptions")
                }
            }
            print(
                "Allowed: \(result.allowedCount) · denied: \(result.deniedCount) "
                    + "· high-impact allowed: \(result.highImpactAllowedCount) "
                    + "· stale clients: \(result.staleClientCount)"
            )
        }

        if !result.hasReadableDatabase || result.wasTruncated || result.wasCancelled {
            let sourceSummary = result.sources
                .map { "\($0.scope.rawValue)=\($0.status.rawValue)" }
                .joined(separator: ", ")
            let warning = "Warning: privacy permission inventory may be incomplete "
                + "(sources: \(sourceSummary), truncated: \(result.wasTruncated), "
                + "cancelled: \(result.wasCancelled))\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
    }

    private static func handleAppRelationships(args: [String]) {
        let json = args.contains("--json")
        let applications = AppInfoFetcher.shared.discoverInstalledApps()
            .map(AppRelationshipApplicationReference.init(app:))
        let result = AppRelationshipScanner.scan(applications: applications)

        if json {
            let formatter = ISO8601DateFormatter()
            let groups: [[String: Any]] = result.groups.map { group in
                [
                    "identifier": group.identifier,
                    "teamIdentifier": group.teamIdentifier,
                    "shared": group.isShared,
                    "applications": group.applications.map { application in
                        [
                            "name": application.name,
                            "bundleIdentifier": application.bundleIdentifier,
                            "path": application.url.path,
                        ]
                    },
                    "locations": group.locations.map { location in
                        [
                            "kind": location.kind.rawValue,
                            "path": location.url.path,
                            "status": location.status.rawValue,
                        ]
                    },
                ]
            }
            let payload: [String: Any] = [
                "groups": groups,
                "groupCount": result.groups.count,
                "sharedGroupCount": result.groups.count(where: \.isShared),
                "scannedApplicationCount": result.scannedApplicationCount,
                "ignoredUnsignedApplicationCount": result.ignoredUnsignedApplicationCount,
                "invalidGroupIdentifierCount": result.invalidGroupIdentifierCount,
                "wasTruncated": result.wasTruncated,
                "wasCancelled": result.wasCancelled,
                "scannedAt": formatter.string(from: result.scannedAt),
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(
                    withJSONObject: payload,
                    options: [.prettyPrinted, .sortedKeys]
                  ),
                  let output = String(data: data, encoding: .utf8) else {
                printError("Could not encode app relationship inventory")
                exit(1)
            }
            print(output)
        } else {
            let sharedCount = result.groups.count(where: \.isShared)
            print(
                "App Group Relationships (\(result.groups.count) groups, "
                    + "\(sharedCount) shared):"
            )
            for group in result.groups {
                let state = group.isShared
                    ? "shared by \(group.applications.count) apps"
                    : "single declaration"
                print(
                    "  [\(state)] \(terminalSafe(group.identifier)) "
                        + "· Team \(terminalSafe(group.teamIdentifier))"
                )
                let applicationNames = group.applications
                    .map { terminalSafe($0.name) }
                    .joined(separator: ", ")
                print("      \(applicationNames)")
                for location in group.locations where location.status != .notFound {
                    print(
                        "      [\(location.status.rawValue)] "
                            + terminalSafe(location.url.path)
                    )
                }
            }
        }

        if result.wasTruncated || result.wasCancelled
            || result.invalidGroupIdentifierCount > 0 {
            let warning = "Warning: app relationship inventory may be incomplete "
                + "(invalid declarations: \(result.invalidGroupIdentifierCount), "
                + "truncated: \(result.wasTruncated), "
                + "cancelled: \(result.wasCancelled))\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
    }

    private static func waitForAsync<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) -> Value {
        let result = BlockingResult<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            result.store(await operation())
            semaphore.signal()
        }
        semaphore.wait()
        return result.take()
    }

    // MARK: - Output

    static func terminalSafe(_ value: String) -> String {
        value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func printTable(_ results: [(String, Int, Int64)]) {
        var totalSize: Int64 = 0
        var totalItems = 0

        print("Category                Items     Size")
        print("----------------------  -----     --------")
        for (name, count, size) in results {
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            print("\(name.padding(toLength: 22, withPad: " ", startingAt: 0))  \(String(count).padding(toLength: 5, withPad: " ", startingAt: 0))     \(sizeStr)")
            totalSize += size
            totalItems += count
        }
        print("----------------------  -----     --------")
        let totalStr = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
        print("Total                   \(String(totalItems).padding(toLength: 5, withPad: " ", startingAt: 0))     \(totalStr)")
    }

    private static func printJSON(_ results: [(String, Int, Int64)]) {
        var entries: [String] = []
        for (name, count, size) in results {
            entries.append("    {\"category\": \"\(name)\", \"items\": \(count), \"bytes\": \(size)}")
        }
        print("[\n\(entries.joined(separator: ",\n"))\n]")
    }

    private static func printUsage() {
        print("""
        AppSift CLI

        Usage: appsift <command> [options]

        Commands:
          scan                    Scan all categories
          scan --category <name>  Scan a specific category
          scan --json             Output as JSON
          disk-info               Show disk usage
          list                    List installed apps
          extensions              List locally verified third-party extensions
          extensions --json       Output extension inventory as JSON
          default-apps            List file types and their current default apps
          default-apps --json     Output default application inventory as JSON
          app-updates             Check verified local application update sources
          app-updates --json      Output application update inventory as JSON
          app-usage               Show evidence-backed app usage (30/90/180 days)
          app-usage --json        Output app usage inventory as JSON
          app-usage --days 90     Set the unused threshold (30, 90, or 180)
          installation-files      List local DMG, PKG, MPKG, XIP, and verified App ZIPs
          installation-files --json
                                  Output installation file inventory as JSON
          app-permissions         List local privacy permission decisions
          app-permissions --json  Output permission decisions and declarations as JSON
          app-relationships       List signed App Group relationships and local paths
          app-relationships --json
                                  Output signed relationship evidence as JSON
          version                 Show version
          help                    Show this help

        Categories:
          \(CleaningCategory.scannable.map(\.rawValue).joined(separator: ", "))
        """)
    }

    private static func printVersion() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        print("AppSift \(version)")
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }

    private static func extractValue(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
