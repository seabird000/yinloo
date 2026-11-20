import Foundation

/// 一种 U 盘录音笔「长什么样」：怎么认、录音在哪、时间怎么取。只是数据，应用只按它去哪里读、读什么格式，
/// 不执行任何东西，也不会因此往笔里写。格式见项目的设计稿（`devices.json`）。
struct DeviceProfile: Codable, Equatable, Sendable, Identifiable {
    struct Match: Codable, Equatable, Sendable {
        var vendorID: Int
        var productID: Int?
        var productName: String?
        /// 挂上之后再核对一次：这些文件夹都在才算。
        var requiredPaths: [String]?
    }
    var id: String
    var name: String
    var match: Match
    var audioRoots: [String]?
    var exclude: [String]?
    var extensions: [String]?
    var timeFromName: String?
    var categories: [String: String]?
    var note: String?

    /// 挂载前就能比的部分（厂商号、产品号、产品名）。
    func matches(_ i: UsbRecorder.Identity) -> Bool {
        guard i.vendorID == match.vendorID else { return false }
        if let p = match.productID, p != i.productID { return false }
        if let n = match.productName,
           n.trimmingCharacters(in: .whitespaces).lowercased() != i.productName?.trimmingCharacters(in: .whitespaces).lowercased() { return false }
        return true
    }

    /// 挂上之后核对目录。
    func volumeMatches(_ volume: URL) -> Bool {
        let fm = FileManager.default
        return (match.requiredPaths ?? []).allSatisfy {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: volume.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// 档案是别人写的、从网上来的：字段都要在合理范围里，不合格的整条不用。
    var isValid: Bool {
        func okPath(_ p: String) -> Bool {
            !p.isEmpty && p.count <= 120 && !p.hasPrefix("/") && !p.split(separator: "/").contains("..") && !p.contains("\\")
        }
        func okList(_ l: [String]?, max: Int, each: (String) -> Bool) -> Bool { (l?.count ?? 0) <= max && (l ?? []).allSatisfy(each) }
        guard id.range(of: "^[a-z0-9][a-z0-9-]{0,63}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 40,
              (0...0xFFFF).contains(match.vendorID), (match.productID.map { (0...0xFFFF).contains($0) } ?? true),
              (match.productName?.count ?? 0) <= 64,
              okList(match.requiredPaths, max: 8, each: okPath),
              okList(audioRoots, max: 16, each: okPath),
              okList(exclude, max: 32, each: { !$0.isEmpty && $0.count <= 64 && !$0.contains("/") }),
              okList(extensions, max: 16, each: { $0.range(of: "^[A-Za-z0-9]{1,6}$", options: .regularExpression) != nil }),
              (categories?.count ?? 0) <= 32, (categories ?? [:]).allSatisfy({ $0.key.count <= 64 && $0.value.count <= 20 }),
              (note?.count ?? 0) <= 200
        else { return false }
        if let t = timeFromName, UsbRecorder.regex(for: t) == nil { return false }
        return true
    }
}

/// 设备档案库：应用里带的一份 + 云端的一份（阿里云优先，GitHub 兜底，存一份缓存，断网也能用上次的）。
enum DeviceProfiles {
    struct File: Codable, Equatable, Sendable {
        var schema: Int
        var updated: String?
        var profiles: [DeviceProfile]
    }

    enum Origin: String, Sendable { case builtIn = "内置", cloud = "云端" }

    struct Library: Equatable, Sendable {
        var builtIn: [DeviceProfile] = DeviceProfiles.builtIn
        var cloud: [DeviceProfile] = []
        var cloudUpdated: String?
        var fetchedAt: Date?

        /// 同一个 id 云端的覆盖内置的。
        var all: [DeviceProfile] {
            let ids = Set(cloud.map(\.id))
            return cloud + builtIn.filter { !ids.contains($0.id) }
        }
        func origin(of id: String) -> Origin? {
            cloud.contains { $0.id == id } ? .cloud : builtIn.contains { $0.id == id } ? .builtIn : nil
        }
        func profile(_ id: String?) -> DeviceProfile? { id.flatMap { i in all.first { $0.id == i } } }
        /// 挂载前认：第一份对得上的。
        func match(_ i: UsbRecorder.Identity) -> DeviceProfile? { all.first { $0.matches(i) } }
    }

    /// 应用里带的档案。除了 C1 Max（走专用代码）还没有真机验证过别的型号，所以先是空的，不编造厂商号。
    static let builtIn: [DeviceProfile] = []

    static let currentSchema = 1

    /// 解析并校验：结构不对、版本太新返回 nil；单条不合格的丢掉。
    static func parse(_ data: Data) -> File? {
        guard data.count <= 1 << 20, var f = try? JSONDecoder().decode(File.self, from: data),
              f.schema >= 1, f.schema <= currentSchema else { return nil }
        var seen = Set<String>()
        f.profiles = f.profiles.prefix(500).filter { $0.isValid && seen.insert($0.id).inserted }
        return f
    }

    // MARK: 缓存

    static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("E1Recorder/devices.json")
    }

    static func loadCached() -> Library {
        var lib = Library()
        if let d = try? Data(contentsOf: cacheURL), let f = parse(d) {
            lib.cloud = f.profiles
            lib.cloudUpdated = f.updated
            lib.fetchedAt = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return lib
    }

    // MARK: 云端

    static let sources: [URL] = [AppLinks.devicesCN, AppLinks.devicesGitHub]

    /// 从云端读一份新的；读到合格的就写进缓存并返回，都读不到返回 nil（继续用缓存）。
    static func fetch(sources: [URL] = sources, session: URLSession = .shared) async -> File? {
        for url in sources {
            var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            AppLinks.addReferer(&r)
            r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            guard let (data, resp) = try? await session.data(for: r),
                  (resp as? HTTPURLResponse)?.statusCode == 200, let f = parse(data) else { continue }
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            return f
        }
        return nil
    }
}
