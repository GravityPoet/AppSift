//
//  AppConstants.swift
//  AppSift
//
//  Created by Theo Sementa on 12/04/2026.
//

import Foundation

struct AppConstants {
    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
}

enum ProductIdentity {
    static let name = "AppSift"
    static let subtitle = "AppSift — Cleaner & Uninstaller"
    static let bundleIdentifier = "com.gravitypoet.appsift"
    static let schedulerLabel = "com.gravitypoet.appsift.scheduler"
    static let repositoryURL = URL(string: "https://github.com/GravityPoet/AppSift")!
    static let latestReleaseURL = repositoryURL.appendingPathComponent("releases/latest")
}
