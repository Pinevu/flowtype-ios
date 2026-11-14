import Foundation

public enum AppConfig {
    public static var appGroupID: String {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "FlowTypeAppGroupID") as? String,
           !raw.isEmpty,
           !raw.contains("$(") {
            return raw
        }
        return "group.com.flowtype.voice"
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
        public static var commandPosted: String { "\(appGroupID).notify.command" }
        public static var statusUpdated: String { "\(appGroupID).notify.status" }
        public static var configChanged: String { "\(appGroupID).notify.config" }
    }
}
