import Foundation

public struct AppGroupDiagnostics: Sendable {
    public let activeGroupID: String
    public let hasValidContainer: Bool
    public let infoPlistGroupID: String?
    public let provisionGroupIDs: [String]
}

public enum AppConfig {
    private static let defaultFallbackGroupID = "group.com.flowtype.voice"

    public static let appGroupDiagnostics: AppGroupDiagnostics = resolveAppGroupDiagnostics()

    public static var appGroupID: String {
        appGroupDiagnostics.activeGroupID
    }

    public static var urlScheme: String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "FlowTypeURLScheme") as? String,
           !raw.isEmpty,
           !raw.contains("$(") {
            return raw
        }
        return "flowtype"
    }

    /// Parses `Entitlements -> com.apple.security.application-groups` from a CMS-signed `.mobileprovision` file.
    public static func extractProvisionAppGroups(from provisionURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: provisionURL) else { return [] }
        let startMarker = Data("<plist".utf8)
        let endMarker = Data("</plist>".utf8)
        guard let startRange = data.range(of: startMarker),
              let endRange = data.range(of: endMarker, range: startRange.lowerBound..<data.endIndex),
              startRange.lowerBound < endRange.upperBound else {
            return []
        }

        let plistData = data.subdata(in: startRange.lowerBound..<endRange.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return groups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func resolveAppGroupDiagnostics() -> AppGroupDiagnostics {
        let rawPlist = (Bundle.main.object(forInfoDictionaryKey: "FlowTypeAppGroupID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let infoGroup = (rawPlist?.isEmpty == false && rawPlist?.contains("$(") == false) ? rawPlist : nil

        // Locate both the host `.app` bundle and the `.appex` bundle so both processes examine the exact same sets.
        let currentBundleURL = Bundle.main.bundleURL
        let isExtension = currentBundleURL.pathExtension.lowercased() == "appex"
        let hostAppURL = isExtension
            ? currentBundleURL.deletingLastPathComponent().deletingLastPathComponent()
            : currentBundleURL
        let extAppURL = isExtension
            ? currentBundleURL
            : currentBundleURL.appendingPathComponent("PlugIns/FlowTypeKeyboard.appex", isDirectory: true)

        let hostProvisionGroups = extractProvisionAppGroups(
            from: hostAppURL.appendingPathComponent("embedded.mobileprovision", isDirectory: false)
        )
        let extProvisionGroups = extractProvisionAppGroups(
            from: extAppURL.appendingPathComponent("embedded.mobileprovision", isDirectory: false)
        )

        // Order shared groups first (sorted deterministically) so main app & extension pick the identical ID.
        var orderedProvisionGroups: [String] = []
        var seenProvision = Set<String>()
        func appendUnique(_ list: [String]) {
            for item in list where seenProvision.insert(item).inserted {
                orderedProvisionGroups.append(item)
            }
        }

        if !hostProvisionGroups.isEmpty && !extProvisionGroups.isEmpty {
            let shared = Set(hostProvisionGroups).intersection(extProvisionGroups).sorted()
            appendUnique(shared)
        }
        appendUnique(hostProvisionGroups.sorted())
        appendUnique(extProvisionGroups.sorted())

        var candidates: [String] = []
        var seenCand = Set<String>()
        func addCandidate(_ gid: String?) {
            guard let gid, !gid.isEmpty, !gid.contains("*"), seenCand.insert(gid).inserted else { return }
            candidates.append(gid)
        }

        addCandidate(infoGroup)
        for gid in orderedProvisionGroups {
            addCandidate(gid)
        }
        addCandidate(defaultFallbackGroupID)

        for gid in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: gid) != nil {
                return AppGroupDiagnostics(
                    activeGroupID: gid,
                    hasValidContainer: true,
                    infoPlistGroupID: infoGroup,
                    provisionGroupIDs: orderedProvisionGroups
                )
            }
        }

        return AppGroupDiagnostics(
            activeGroupID: infoGroup ?? defaultFallbackGroupID,
            hasValidContainer: false,
            infoPlistGroupID: infoGroup,
            provisionGroupIDs: orderedProvisionGroups
        )
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
        public static var commandPosted: String { "\(appGroupID).notify.command" }
        public static var statusUpdated: String { "\(appGroupID).notify.status" }
        public static var configChanged: String { "\(appGroupID).notify.config" }
    }
}
