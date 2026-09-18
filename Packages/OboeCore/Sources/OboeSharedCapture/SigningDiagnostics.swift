import Foundation

/// On-device signing diagnostics for the shared App Group container. The
/// share extension surfaces these when `containerURL` returns nil so a
/// self-signed install can show *why* the group is unavailable without
/// pulling the signed app back off the device.
public enum SigningDiagnostics {

    /// App Groups the embedded provisioning profile allows. Returns nil when
    /// the bundle carries no readable profile (unsigned/ad-hoc installs) or
    /// the profile cannot be parsed; an empty array means the profile was
    /// parsed but grants no App Group.
    public static func profileAllowedAppGroups(
        bundle: Bundle = .main
    ) -> [String]? {
        guard let url = bundle.url(
            forResource: "embedded", withExtension: "mobileprovision"
        ), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parseAppGroups(fromProfileData: data)
    }

    /// A one-line summary for error surfaces: what the process asked for
    /// versus what its signing profile allows.
    public static func appGroupSummary(
        requestedGroup: String,
        bundle: Bundle = .main
    ) -> String {
        guard let allowed = profileAllowedAppGroups(bundle: bundle) else {
            return "请求组：\(requestedGroup)；未找到 embedded.mobileprovision，无法读取签名授权。"
        }
        if allowed.isEmpty {
            return "请求组：\(requestedGroup)；当前签名未授予任何 App Group(application-groups 为空)。"
        }
        return "请求组：\(requestedGroup)；签名允许的组：\(allowed.joined(separator: "、"))。"
    }

    /// embedded.mobileprovision is a CMS envelope wrapping an XML plist —
    /// decode lossily so the ASCII plist survives the surrounding DER bytes.
    static func parseAppGroups(fromProfileData data: Data) -> [String]? {
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"),
              let end = text.range(
                  of: "</plist>",
                  range: start.lowerBound..<text.endIndex
              ),
              let plistData = text[start.lowerBound..<end.upperBound]
                  .data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else {
            return nil
        }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}
