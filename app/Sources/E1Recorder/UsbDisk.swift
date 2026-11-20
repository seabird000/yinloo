import DiskArbitration
import Foundation
import IOKit

/// 一块插着的 USB 盘（C1 Max 除外，它归 `C1MaxDisk` 管）。
struct UsbDiskInfo: Equatable, Sendable, Identifiable {
    var bsd: String
    var id: String { bsd }
    var identity: UsbRecorder.Identity
    var volumeName: String?
    var fileSystem: String?
    var sizeBytes: Int64?
    var path: URL?
    var readOnly = false
    /// 是认出来的录音笔（添加过，或档案里有）：本应用只让它以只读方式挂上。
    var guarded = false
    var mounting = false
    var problem: String?
    /// 能读了：是录音笔、已以只读方式挂好。
    var ready: Bool { guarded && path != nil && readOnly && !mounting }
    /// 列表里给人看的名字。
    var label: String {
        if let v = volumeName, !v.isEmpty { return v }
        return identity.productName ?? "USB 盘"
    }
}

/// 盯着 USB 盘插拔。普通 U 盘只记下来（「添加」页要列出来），不拦、不碰；
/// 认出来的录音笔（添加过的，或档案里有的）照 `C1MaxDisk` 的办法只读挂载：系统要挂时拦下，再由本应用以 rdonly 挂上；
/// 已经按读写挂好的（本应用没开着时插上的，或刚添加的），卸下来改成只读重挂。
///
/// 回调都在自己的串行队列上跑，状态只在这个队列上改；每次有变化把整份快照交给主线程的 Pipeline。
final class UsbDisk: @unchecked Sendable {
    static let shared = UsbDisk()

    private let queue = DispatchQueue(label: "app.e1recorder.usb-disk")
    private var session: DASession?
    private var disks: [String: UsbDiskInfo] = [:]
    private var entries: [UsbRecorder.Entry] = []
    private var profiles: [DeviceProfile] = []
    /// 正由本应用发起挂载的盘：审批时放行。
    private var ownMounts: Set<String> = []

    private var ctx: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    private static func me(_ p: UnsafeMutableRawPointer?) -> UsbDisk { Unmanaged<UsbDisk>.fromOpaque(p!).takeUnretainedValue() }

    func start() {
        queue.async { [self] in
            guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
            session = s
            DARegisterDiskAppearedCallback(s, nil, { disk, p in UsbDisk.me(p).appeared(disk) }, ctx)
            DARegisterDiskDisappearedCallback(s, nil, { disk, p in UsbDisk.me(p).disappeared(disk) }, ctx)
            DARegisterDiskDescriptionChangedCallback(s, nil, [kDADiskDescriptionVolumePathKey] as CFArray,
                                                     { disk, _, p in UsbDisk.me(p).pathChanged(disk) }, ctx)
            DARegisterDiskMountApprovalCallback(s, nil, { disk, p in UsbDisk.me(p).approveMount(disk) }, ctx)
            DASessionSetDispatchQueue(s, queue)
        }
    }

    /// 哪些算录音笔（主线程在添加、移除、档案更新后调）。新认出来、正以读写方式挂着的，马上改成只读。
    func setRules(entries: [UsbRecorder.Entry], profiles: [DeviceProfile]) {
        queue.async { [self] in
            self.entries = entries
            self.profiles = profiles
            for (bsd, var info) in disks {
                let g = isGuarded(info.identity)
                guard g != info.guarded else { continue }
                info.guarded = g
                disks[bsd] = info
                if g, let s = session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, s, bsd) {
                    if let path = volumePath(disk) { settle(disk, bsd, path) } else { mountReadOnly(disk, bsd) }
                }
            }
            publish()
        }
    }

    /// 「推出」：卸下并弹出，之后可以直接拔线。
    func eject(_ bsd: String) {
        queue.async { [self] in
            guard let s = session, disks[bsd] != nil, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, s, bsd) else { return }
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { disk, dissenter, p in
                let me = UsbDisk.me(p)
                guard let bsd = me.bsdName(disk) else { return }
                if let dissenter { me.fail(bsd, me.reason(dissenter, "推出失败")); return }
                let whole = DADiskCopyWholeDisk(disk) ?? disk
                DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { whole, dissenter, p in
                    let me = UsbDisk.me(p)
                    guard let dissenter, let w = me.bsdName(whole) else { return }
                    // 推出的是整块盘（disk7），记录里的是分区（disk7s1）
                    for b in me.disks.keys where b == w || b.hasPrefix(w + "s") { me.fail(b, me.reason(dissenter, "推出失败")) }
                }, p)
            }, ctx)
        }
    }

    // MARK: 认设备

    private func isGuarded(_ i: UsbRecorder.Identity) -> Bool {
        entries.contains { $0.matches(i) } || profiles.contains { $0.matches(i) }
    }

    /// USB 接口、能挂载的卷，读出厂商号、产品号等；C1 Max 和非 USB 的盘返回 nil。
    private func describe(_ disk: DADisk) -> UsbDiskInfo? {
        guard let bsd = bsdName(disk), let desc = DADiskCopyDescription(disk) as? [String: Any],
              desc[kDADiskDescriptionDeviceProtocolKey as String] as? String == "USB",
              desc[kDADiskDescriptionVolumeMountableKey as String] as? Bool == true,
              desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool != true else { return nil }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        let opts = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func prop(_ key: String) -> Any? { IORegistryEntrySearchCFProperty(media, kIOServicePlane, key as CFString, kCFAllocatorDefault, opts) }
        let name = (prop("USB Product Name") as? String)?.trimmingCharacters(in: .whitespaces)
        guard let vid = (prop("idVendor") as? NSNumber)?.intValue, let pid = (prop("idProduct") as? NSNumber)?.intValue,
              !C1Max.matches(productName: name, vendorID: vid) else { return nil }
        let identity = UsbRecorder.Identity(vendorID: vid, productID: pid, productName: name,
                                            manufacturer: (prop("USB Vendor Name") as? String)?.trimmingCharacters(in: .whitespaces),
                                            serialHash: UsbRecorder.Identity.hash(serial: prop("USB Serial Number") as? String))
        var info = UsbDiskInfo(bsd: bsd, identity: identity)
        info.volumeName = desc[kDADiskDescriptionVolumeNameKey as String] as? String
        info.fileSystem = desc[kDADiskDescriptionVolumeKindKey as String] as? String
        info.sizeBytes = (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value
        info.guarded = isGuarded(identity)
        return info
    }

    private func bsdName(_ disk: DADisk) -> String? { DADiskGetBSDName(disk).map { String(cString: $0) } }

    /// 现在挂在哪里（按 BSD 名重新取一份描述，回调里带的可能是旧的）。
    private func volumePath(_ disk: DADisk) -> URL? {
        guard let s = session, let bsd = bsdName(disk), let fresh = DADiskCreateFromBSDName(kCFAllocatorDefault, s, bsd) else { return nil }
        return (DADiskCopyDescription(fresh) as? [String: Any])?[kDADiskDescriptionVolumePathKey as String] as? URL
    }

    private static func isReadOnly(_ url: URL) -> Bool {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return false }
        return st.f_flags & UInt32(MNT_RDONLY) != 0
    }

    private func reason(_ d: DADissenter, _ prefix: String) -> String {
        let s = DADissenterGetStatusString(d) as String?
        return prefix + "（" + (s?.isEmpty == false ? s! : String(format: "0x%08x", DADissenterGetStatus(d))) + "）"
    }

    private func publish() {
        let snap = disks.values.sorted { $0.bsd < $1.bsd }
        Task { @MainActor in Pipeline.shared.usbDisksChanged(snap) }
    }

    private func fail(_ bsd: String, _ why: String) {
        Log.sync.error("U 盘录音笔：\(why, privacy: .public)")
        disks[bsd]?.mounting = false
        disks[bsd]?.problem = why
        publish()
    }

    /// 记下现在的挂载位置和是否只读。
    private func refresh(_ disk: DADisk, _ bsd: String) {
        let path = volumePath(disk)
        disks[bsd]?.path = path
        disks[bsd]?.readOnly = path.map(Self.isReadOnly) ?? false
    }

    // MARK: 回调（都在 queue 上）

    private func appeared(_ disk: DADisk) {
        guard var info = describe(disk) else { return }
        let bsd = info.bsd
        if let old = disks[bsd] { info.mounting = old.mounting }
        disks[bsd] = info
        refresh(disk, bsd)
        if info.guarded {
            Log.sync.notice("U 盘录音笔已插上")
            if let path = disks[bsd]?.path {
                settle(disk, bsd, path)
            } else {
                // 系统马上会来要求挂载（审批时拦下并改成只读）；万一没有，过一会儿自己挂。
                queue.asyncAfter(deadline: .now() + 3) { [self] in
                    guard let i = disks[bsd], i.guarded, !i.mounting, volumePath(disk) == nil else { return }
                    mountReadOnly(disk, bsd)
                }
            }
        }
        publish()
    }

    private func disappeared(_ disk: DADisk) {
        guard let bsd = bsdName(disk), let info = disks.removeValue(forKey: bsd) else { return }
        ownMounts.remove(bsd)
        if info.guarded { Log.sync.notice("U 盘录音笔已拔下") }
        publish()
    }

    private func pathChanged(_ disk: DADisk) {
        guard let bsd = bsdName(disk), let info = disks[bsd] else { return }
        refresh(disk, bsd)
        if info.guarded, let path = disks[bsd]?.path { settle(disk, bsd, path) }
        publish()
    }

    /// 录音笔挂上了：只读就好；是读写的，卸下来改成只读。
    private func settle(_ disk: DADisk, _ bsd: String, _ path: URL) {
        guard let info = disks[bsd], info.guarded else { return }
        if Self.isReadOnly(path) {
            disks[bsd]?.readOnly = true
            disks[bsd]?.problem = nil
            return
        }
        guard !info.mounting else { return }
        disks[bsd]?.mounting = true
        Log.sync.notice("U 盘录音笔以读写方式挂着，改成只读")
        publish()
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), { disk, dissenter, p in
            let me = UsbDisk.me(p)
            guard let bsd = me.bsdName(disk) else { return }
            me.disks[bsd]?.mounting = false
            if let dissenter {
                me.fail(bsd, me.reason(dissenter, "没能改成只读：卸不下来，请在访达里推出后重新插上"))
                return
            }
            me.mountReadOnly(disk, bsd)
        }, ctx)
    }

    /// 以只读方式挂上（相当于 `diskutil mount readOnly`）。
    private func mountReadOnly(_ disk: DADisk, _ bsd: String) {
        guard let info = disks[bsd], info.guarded, !info.mounting else { return }
        disks[bsd]?.mounting = true
        ownMounts.insert(bsd)
        publish()
        var args: [Unmanaged<CFString>?] = [Unmanaged.passUnretained("rdonly" as CFString), nil]
        args.withUnsafeMutableBufferPointer { argv in
            DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), { disk, dissenter, p in
                let me = UsbDisk.me(p)
                guard let bsd = me.bsdName(disk) else { return }
                me.disks[bsd]?.mounting = false
                me.ownMounts.remove(bsd)
                me.refresh(disk, bsd)
                if me.disks[bsd]?.readOnly == true {
                    me.disks[bsd]?.problem = nil
                    Log.sync.notice("U 盘录音笔已以只读方式挂上")
                    me.publish()
                } else if let dissenter {
                    me.fail(bsd, me.reason(dissenter, "没能以只读方式挂上") + "，请拔下数据线重新插上")
                } else {
                    me.publish()
                }
            }, ctx, argv.baseAddress)
        }
    }

    /// 系统要挂载某块盘时问我们：认出来的录音笔拦下，再由本应用以只读方式挂上；其他盘不管。
    private func approveMount(_ disk: DADisk) -> Unmanaged<DADissenter>? {
        guard let bsd = bsdName(disk), !ownMounts.contains(bsd) else { return nil }
        if disks[bsd] == nil, let info = describe(disk) { disks[bsd] = info }
        guard disks[bsd]?.guarded == true else { return nil }
        queue.asyncAfter(deadline: .now() + 0.5) { [self] in
            if disks[bsd]?.mounting != true, volumePath(disk) == nil { mountReadOnly(disk, bsd) }
        }
        let d = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), "音录会以只读方式挂载录音笔" as CFString)
        return Unmanaged.passRetained(d)
    }
}
