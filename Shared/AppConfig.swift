import Foundation

public struct ProvisioningInfo: Sendable, Equatable {
    public let teamID: String
    public let applicationIdentifier: String
    public let applicationGroups: [String]
    public let keychainAccessGroups: [String]
    public let hasEmbeddedProvision: Bool

    public init(
        teamID: String = "",
        applicationIdentifier: String = "",
        applicationGroups: [String] = [],
        keychainAccessGroups: [String] = [],
        hasEmbeddedProvision: Bool = false
    ) {
        self.teamID = teamID
        self.applicationIdentifier = applicationIdentifier
        self.applicationGroups = applicationGroups
        self.keychainAccessGroups = keychainAccessGroups
        self.hasEmbeddedProvision = hasEmbeddedProvision
    }
}

public struct AppGroupDiagnostics: Sendable, Equatable {
    public let activeGroupID: String
    public let hasValidContainer: Bool
    public let infoPlistGroupID: String?
    public let provisionGroupIDs: [String]
}

public enum AppConfig {
    private static let defaultFallbackGroupID = "group.com.flowtype.voice"

    private struct ResolvedContext: Sendable {
        let diagnostics: AppGroupDiagnostics
        let activeContainerURL: URL?
        let provisioningInfo: ProvisioningInfo
        let hostBundleID: String
    }

    private static let resolved: ResolvedContext = resolveContext()

    public static var appGroupDiagnostics: AppGroupDiagnostics {
        resolved.diagnostics
    }

    public static var appGroupID: String {
        resolved.diagnostics.activeGroupID
    }

    public static var activeContainerURL: URL? {
        resolved.activeContainerURL
    }

    public static var provisioningInfo: ProvisioningInfo {
        resolved.provisioningInfo
    }

    public static var provisionedAppGroups: [String] {
        resolved.diagnostics.provisionGroupIDs
    }

    public static var provisionedKeychainGroups: [String] {
        resolved.provisioningInfo.keychainAccessGroups
    }

    public static var teamID: String {
        resolved.provisioningInfo.teamID
    }

    public static var hostBundleIdentifier: String {
        resolved.hostBundleID
    }

    public static var urlScheme: String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "FlowTypeURLScheme") as? String,
           !raw.isEmpty,
           !raw.contains("$(") {
            return raw
        }
        return "flowtype"
    }

    public static func deepLinkURL(action: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = action
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    public enum Notify {
        private static var channelPrefix: String {
            if activeContainerURL != nil {
                return appGroupID
            }
            if !teamID.isEmpty {
                return "team.\(teamID).flowtype"
            }
            if !hostBundleIdentifier.isEmpty {
                return "bundle.\(hostBundleIdentifier).flowtype"
            }
            return appGroupID
        }

        public static var commandPosted: String { "\(channelPrefix).notify.command" }
        public static var statusUpdated: String { "\(channelPrefix).notify.status" }
        public static var configChanged: String { "\(channelPrefix).notify.config" }
        public static var onlineLexiconChanged: String { "\(channelPrefix).notify.online_lexicon" }
    }

    // MARK: - Provisioning Inspection Helpers

    public static func deriveHostBundleID(from bundleID: String) -> String {
        let suffixes = [".keyboard", ".FlowTypeKeyboard"]
        for suffix in suffixes where bundleID.hasSuffix(suffix) {
            return String(bundleID.dropLast(suffix.count))
        }
        return bundleID
    }

    /// Parses `Entitlements -> com.apple.security.application-groups` from a CMS-signed `.mobileprovision` file.
    public static func extractProvisionAppGroups(from provisionURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: provisionURL),
              let info = extractProvisioningInfo(from: data) else {
            return []
        }
        return info.applicationGroups
    }

    public static func extractProvisioningInfo(from data: Data) -> ProvisioningInfo? {
        let startMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let startRange = data.range(of: startMarker),
              let endRange = data.range(of: endMarker, options: [], in: startRange.lowerBound..<data.endIndex),
              startRange.lowerBound < endRange.upperBound else {
            return nil
        }

        let plistData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let dict = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let entitlements = dict["Entitlements"] as? [String: Any] ?? [:]
        let teamIDs = dict["TeamIdentifier"] as? [String] ?? []
        let appID = entitlements["application-identifier"] as? String ?? ""
        var teamID = teamIDs.first ?? ""
        if teamID.isEmpty, let dot = appID.firstIndex(of: ".") {
            teamID = String(appID[..<dot])
        }

        let rawAppGroups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
        let appGroups = rawAppGroups
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let rawKeychainGroups = entitlements["keychain-access-groups"] as? [String] ?? []
        let keychainGroups = rawKeychainGroups
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return ProvisioningInfo(
            teamID: teamID,
            applicationIdentifier: appID,
            applicationGroups: appGroups,
            keychainAccessGroups: keychainGroups,
            hasEmbeddedProvision: true
        )
    }

    public static func candidateAppGroupIDs(
        infoPlistGroupID: String?,
        hostBundleID: String,
        provisioning: ProvisioningInfo,
        prioritizedGroups: [String]? = nil
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func appendUnique(_ raw: String?) {
            guard let s = raw?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                  !s.isEmpty,
                  !s.contains("$("),
                  !s.contains("*") else {
                return
            }
            if seen.insert(s).inserted {
                ordered.append(s)
            }
        }

        // 1. Explicit Info.plist value (populated during Xcode build / CI)
        appendUnique(infoPlistGroupID)

        // 2. Concrete App Groups authorized in embedded.mobileprovision (shared intersection first, sorted deterministically)
        let sourceGroups = prioritizedGroups ?? provisioning.applicationGroups.sorted()
        for gid in sourceGroups where !gid.contains("*") {
            appendUnique(gid)
        }

        // 3. Wildcard App Group templates in provisioning profile (e.g., "group.*" or "group.com.demo.*")
        for pattern in sourceGroups where pattern.contains("*") {
            let prefix = pattern.replacingOccurrences(of: "*", with: "")
            if prefix == "group." {
                appendUnique(defaultFallbackGroupID)
                if !hostBundleID.isEmpty {
                    appendUnique("group.\(hostBundleID)")
                }
            } else {
                let normalizedPrefix = prefix.hasSuffix(".") ? prefix : prefix + "."
                appendUnique(normalizedPrefix + "flowtype.voice")
                appendUnique(normalizedPrefix + "flowtype")
            }
        }

        // 4. Conventional fallbacks
        if !hostBundleID.isEmpty {
            appendUnique("group.\(hostBundleID)")
        }
        appendUnique(defaultFallbackGroupID)

        return ordered
    }

    private static func resolveContext() -> ResolvedContext {
        let bundle = Bundle.main
        let rawPlist = (bundle.object(forInfoDictionaryKey: "FlowTypeAppGroupID") as? String)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let infoGroup = (rawPlist?.isEmpty == false && rawPlist?.contains("$(") == false) ? rawPlist : nil
        let hostBundleID = deriveHostBundleID(from: bundle.bundleIdentifier ?? "")

        // Locate both host `.app` and keyboard `.appex` bundles so both processes inspect the exact same profiles.
        let currentBundleURL = bundle.bundleURL
        let isExtension = currentBundleURL.pathExtension.lowercased() == "appex"
        let hostAppURL = isExtension
            ? currentBundleURL.deletingLastPathComponent().deletingLastPathComponent()
            : currentBundleURL
        let extAppURL = isExtension
            ? currentBundleURL
            : currentBundleURL.appendingPathComponent("PlugIns/FlowTypeKeyboard.appex", isDirectory: true)

        let hostProvURL = hostAppURL.appendingPathComponent("embedded.mobileprovision", isDirectory: false)
        let extProvURL = extAppURL.appendingPathComponent("embedded.mobileprovision", isDirectory: false)

        let hostInfo = (try? Data(contentsOf: hostProvURL)).flatMap { extractProvisioningInfo(from: $0) }
        let extInfo = (try? Data(contentsOf: extProvURL)).flatMap { extractProvisioningInfo(from: $0) }

        let hostGroups = hostInfo?.applicationGroups ?? []
        let extGroups = extInfo?.applicationGroups ?? []

        var orderedProvisionGroups: [String] = []
        var seenProvision = Set<String>()
        func appendProvision(_ items: [String]) {
            for item in items where seenProvision.insert(item).inserted {
                orderedProvisionGroups.append(item)
            }
        }

        if !hostGroups.isEmpty && !extGroups.isEmpty {
            let shared = Set(hostGroups).intersection(extGroups).sorted()
            appendProvision(shared)
        }
        appendProvision(hostGroups.sorted())
        appendProvision(extGroups.sorted())

        var mergedKeychain: [String] = []
        var seenKeychain = Set<String>()
        for k in (hostInfo?.keychainAccessGroups ?? []) + (extInfo?.keychainAccessGroups ?? []) {
            if seenKeychain.insert(k).inserted {
                mergedKeychain.append(k)
            }
        }

        let mergedInfo = ProvisioningInfo(
            teamID: (hostInfo?.teamID.isEmpty == false ? hostInfo?.teamID : extInfo?.teamID) ?? "",
            applicationIdentifier: (hostInfo?.applicationIdentifier.isEmpty == false ? hostInfo?.applicationIdentifier : extInfo?.applicationIdentifier) ?? "",
            applicationGroups: orderedProvisionGroups,
            keychainAccessGroups: mergedKeychain,
            hasEmbeddedProvision: (hostInfo?.hasEmbeddedProvision ?? false) || (extInfo?.hasEmbeddedProvision ?? false)
        )

        let candidates = candidateAppGroupIDs(
            infoPlistGroupID: infoGroup,
            hostBundleID: hostBundleID,
            provisioning: mergedInfo,
            prioritizedGroups: orderedProvisionGroups
        )

        for gid in candidates {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: gid) {
                let sharedDir = url.appendingPathComponent("FlowTypeShared", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
                    let diagnostics = AppGroupDiagnostics(
                        activeGroupID: gid,
                        hasValidContainer: true,
                        infoPlistGroupID: infoGroup,
                        provisionGroupIDs: orderedProvisionGroups
                    )
                    return ResolvedContext(
                        diagnostics: diagnostics,
                        activeContainerURL: url,
                        provisioningInfo: mergedInfo,
                        hostBundleID: hostBundleID
                    )
                } catch {
                    continue
                }
            }
        }

        let fallbackGroup = infoGroup
            ?? orderedProvisionGroups.first(where: { !$0.contains("*") })
            ?? defaultFallbackGroupID
        let diagnostics = AppGroupDiagnostics(
            activeGroupID: fallbackGroup,
            hasValidContainer: false,
            infoPlistGroupID: infoGroup,
            provisionGroupIDs: orderedProvisionGroups
        )
        return ResolvedContext(
            diagnostics: diagnostics,
            activeContainerURL: nil,
            provisioningInfo: mergedInfo,
            hostBundleID: hostBundleID
        )
    }
}
