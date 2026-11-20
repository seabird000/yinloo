import Foundation

/// 检查更新：先读阿里云下载空间里的 latest.json（国内快、稳），读不到再问 GitHub 的最新 Release。
///
/// latest.json 发版时和安装包一起传到 `yinloo-download`，单独设成公共读，格式：
/// `{"version": "1.5.0", "date": "2026-11-20", "dmg": "Yinloo-1.5.0.dmg", "sha256": "…", "notes": "…"}`。
/// 应用现在只认 `version`，其余字段留给以后（比如应用内下载、显示更新说明）。
enum UpdateCheck {
    struct Source: Sendable {
        let url: URL
        /// JSON 里放版本号的字段
        let key: String
        var accept: String?
    }

    static let sources: [Source] = [
        Source(url: AppLinks.latestCN, key: "version"),
        Source(url: AppLinks.latestAPI, key: "tag_name", accept: "application/vnd.github+json"),
    ]

    /// 最新版本号（不带 v）；所有来源都读不到时返回 nil。
    static func latest(sources: [Source] = sources, session: URLSession = .shared) async -> String? {
        for s in sources {
            var r = URLRequest(url: s.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            AppLinks.addReferer(&r)
            if let a = s.accept { r.setValue(a, forHTTPHeaderField: "Accept") }
            guard let (data, resp) = try? await session.data(for: r),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let v = version(from: data, key: s.key) else { continue }
            return v
        }
        return nil
    }

    /// 从 JSON 里取版本号；去掉前面的 v，不像版本号（比如出错页面）就返回 nil。
    static func version(from data: Data, key: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj[key] as? String else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard v.range(of: #"^\d+(\.\d+){1,3}$"#, options: .regularExpression) != nil else { return nil }
        return v
    }

    static func isNewer(_ v: String, than current: String = AppLinks.version) -> Bool {
        v.compare(current, options: .numeric) == .orderedDescending
    }
}
