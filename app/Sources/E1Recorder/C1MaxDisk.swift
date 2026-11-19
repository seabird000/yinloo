import DiskArbitration
import Foundation
import IOKit

/// 盯着 C1 Max 插拔，并且只让它以只读方式挂上。
///
/// macOS 自动挂载 U 盘时是可读写的，一挂上就会往里写 .fseventsd、.Spotlight-V100 这些隐藏文件夹，违背「对录音笔先只读」。
/// 所以这里登记一个「挂载审批」：系统要挂 C1 Max 时先拦下，再由本应用以只读方式（rdonly）挂上。
/// 本应用没开着时插上的，系统已经按读写挂好了：发现后卸下来、改成只读重挂。
/// 认设备靠 USB 产品名「C1 Max」和厂商号，挂载前就能认出来；不是 C1 Max 的盘一概不管。
///
/// 所有回调都在自己的串行队列上跑，状态只在这个队列上改；结果交给主线程的 Pipeline。
final class C1MaxDisk: @unchecked Sendable {
    static let shared = C1MaxDisk()

    private let queue = DispatchQueue(label: "app.e1recorder.c1max-disk")
    private var session: DASession?
    /// 现在插着的 C1 Max（BSD 名，如 disk7）。
    private var present: Set<String> = []
    /// 正由本应用发起挂载的盘：审批时放行。
    private var ownMounts: Set<String> = []
    /// 已经安排了只读挂载、还没完成的盘（避免重复挂）。
    private var mounting: Set<String> = []
    /// 已经以只读方式挂好的盘。
    private var mounted: Set<String> = []

    private var ctx: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    private static func me(_ p: UnsafeMutableRawPointer?) -> C1MaxDisk { Unmanaged<C1MaxDisk>.fromOpaque(p!).takeUnretainedValue() }

    func start() {
        queue.async { [self] in
            guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
            session = s
            DARegisterDiskAppearedCallback(s, nil, { disk, p in C1MaxDisk.me(p).appeared(disk) }, ctx)
            DARegisterDiskDisappearedCallback(s, nil, { disk, p in C1MaxDisk.me(p).disappeared(disk) }, ctx)
            DARegisterDiskDescriptionChangedCallback(s, nil, [kDADiskDescriptionVolumePathKey] as CFArray,
                                                     { disk, _, p in C1MaxDisk.me(p).pathChanged(disk) }, ctx)
            DARegisterDiskMountApprovalCallback(s, nil, { disk, p in C1MaxDisk.me(p).approveMount(disk) }, ctx)
            DASessionSetDispatchQueue(s, queue)
        }
    }

    /// 「推出」：卸下并弹出，之后可以直接拔线。
    func eject() {
        queue.async { [self] in
            guard let s = session, let bsd = present.first, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, s, bsd) else { return }
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { disk, dissenter, p in
                let me = C1MaxDisk.me(p)
                if let dissenter {
                    let why = me.reason(dissenter, "推出失败")
                    Task { @MainActor in Pipeline.shared.c1Failed(why) }
                    return
                }
                let whole = DADiskCopyWholeDisk(disk) ?? disk
                DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, dissenter, p in
                    if let dissenter {
                        let why = C1MaxDisk.me(p).reason(dissenter, "推出失败")
                        Task { @MainActor in Pipeline.shared.c1Failed(why) }
                    } else {
                        Task { @MainActor in Pipeline.shared.c1Ejected() }
                    }
                }, p)
            }, ctx)
        }
    }

    // MARK: 认设备

    private func isC1Max(_ disk: DADisk) -> Bool {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              desc[kDADiskDescriptionDeviceProtocolKey as String] as? String == "USB",
              desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool == true else { return false }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return false }
        defer { IOObjectRelease(media) }
        let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let name = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "USB Product Name" as CFString, kCFAllocatorDefault, opts) as? String
        let vid = (IORegistryEntrySearchCFProperty(media, kIOServicePlane, "idVendor" as CFString, kCFAllocatorDefault, opts) as? NSNumber)?.intValue
        return C1Max.matches(productName: name, vendorID: vid)
    }

    private func bsdName(_ disk: DADisk) -> String? { DADiskGetBSDName(disk).map { String(cString: $0) } }

    /// 现在挂在哪里。回调里拿到的 DADisk 带的描述可能是旧的（刚挂好时还显示没挂），所以按 BSD 名重新取一份。
    private func volumePath(_ disk: DADisk) -> URL? {
        guard let s = session, let bsd = bsdName(disk), let fresh = DADiskCreateFromBSDName(kCFAllocatorDefault, s, bsd) else { return nil }
        return (DADiskCopyDescription(fresh) as? [String: Any])?[kDADiskDescriptionVolumePathKey as String] as? URL
    }

    /// 已以只读方式挂好：记下来，交给 Pipeline。
    private func reportMounted(_ bsd: String, _ path: URL) {
        mounted.insert(bsd)
        Task { @MainActor in Pipeline.shared.c1Mounted(path) }
    }

    private static func isReadOnly(_ url: URL) -> Bool {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return false }
        return st.f_flags & UInt32(MNT_RDONLY) != 0
    }

    private func reason(_ d: DADissenter, _ prefix: String) -> String {
        let s = DADissenterGetStatusString(d) as String?
        let code = DADissenterGetStatus(d)
        return prefix + "（" + (s?.isEmpty == false ? s! : String(format: "0x%08x", code)) + "）"
    }

    // MARK: 回调（都在 queue 上）

    private func appeared(_ disk: DADisk) {
        guard let bsd = bsdName(disk), isC1Max(disk) else { return }
        present.insert(bsd)
        Log.sync.notice("C1 Max 已插上")
        Task { @MainActor in Pipeline.shared.c1Attached() }
        if let path = volumePath(disk) {
            settle(disk, bsd, path)
        } else {
            // 系统马上会来要求挂载（审批时拦下并改成只读）；万一没有（比如之前被卸下过），过一会儿自己挂。
            queue.asyncAfter(deadline: .now() + 3) { [self] in
                guard present.contains(bsd), !mounting.contains(bsd), !mounted.contains(bsd), volumePath(disk) == nil else { return }
                mountReadOnly(disk, bsd)
            }
        }
    }

    private func disappeared(_ disk: DADisk) {
        guard let bsd = bsdName(disk), present.remove(bsd) != nil else { return }
        mounting.remove(bsd); ownMounts.remove(bsd); mounted.remove(bsd)
        Log.sync.notice("C1 Max 已拔下")
        Task { @MainActor in Pipeline.shared.c1Detached() }
    }

    private func pathChanged(_ disk: DADisk) {
        guard let bsd = bsdName(disk), present.contains(bsd) else { return }
        if let path = volumePath(disk) {
            settle(disk, bsd, path)
        } else if !mounting.contains(bsd) {
            mounted.remove(bsd)
            Task { @MainActor in Pipeline.shared.c1Unmounted() }
        }
    }

    /// 挂上了：只读就交给 Pipeline；是读写的（本应用没开着时插上的），卸下来改成只读。
    private func settle(_ disk: DADisk, _ bsd: String, _ path: URL) {
        if Self.isReadOnly(path) {
            reportMounted(bsd, path)
            return
        }
        guard !mounting.contains(bsd) else { return }
        mounting.insert(bsd)
        Log.sync.notice("C1 Max 以读写方式挂着，改成只读")
        Task { @MainActor in Pipeline.shared.c1Attached() }
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { disk, dissenter, p in
            let me = C1MaxDisk.me(p)
            guard let bsd = me.bsdName(disk) else { return }
            if let dissenter {
                me.mounting.remove(bsd)
                let why = me.reason(dissenter, "没能改成只读：卸不下来，请在访达里推出后重新插上")
                Log.sync.error("\(why, privacy: .public)")
                Task { @MainActor in Pipeline.shared.c1Failed(why) }
                return
            }
            me.mounting.remove(bsd)
            me.mountReadOnly(disk, bsd)
        }, ctx)
    }

    /// 以只读方式挂上（相当于 `diskutil mount readOnly`）。
    private func mountReadOnly(_ disk: DADisk, _ bsd: String) {
        guard present.contains(bsd), !mounting.contains(bsd), !mounted.contains(bsd) else { return }
        mounting.insert(bsd)
        ownMounts.insert(bsd)
        var args: [Unmanaged<CFString>?] = [Unmanaged.passUnretained("rdonly" as CFString), nil]
        args.withUnsafeMutableBufferPointer { argv in
            DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { disk, dissenter, p in
                let me = C1MaxDisk.me(p)
                guard let bsd = me.bsdName(disk) else { return }
                me.mounting.remove(bsd)
                me.ownMounts.remove(bsd)
                if let path = me.volumePath(disk), C1MaxDisk.isReadOnly(path) {
                    // 挂好了（有时是别的请求先挂上、这次报「忙」，也算成功）
                    if dissenter == nil { Log.sync.notice("C1 Max 已以只读方式挂上") }
                    me.reportMounted(bsd, path)
                } else if let dissenter {
                    let why = me.reason(dissenter, "没能以只读方式挂上")
                    Log.sync.error("C1 Max \(why, privacy: .public)")
                    Task { @MainActor in Pipeline.shared.c1Failed(why + "，请拔下数据线重新插上") }
                }
            }, ctx, argv.baseAddress)
        }
    }

    /// 系统要挂载某块盘时问我们：C1 Max 一律拦下，再由本应用以只读方式挂上；其他盘不管。
    private func approveMount(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        guard let bsd = bsdName(disk), !ownMounts.contains(bsd), isC1Max(disk) else { return nil }
        present.insert(bsd)
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            if !mounted.contains(bsd), volumePath(disk) == nil { mountReadOnly(disk, bsd) }
        }
        let d = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), "音录会以只读方式挂载录音笔" as CFString)
        return Unmanaged.passRetained(d)
    }
}
