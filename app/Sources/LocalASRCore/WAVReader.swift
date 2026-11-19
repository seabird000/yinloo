import Foundation

/// 读单声道、16 位 PCM 的 WAV（应用用 afconvert 转出来的那种：fmt 可能是扩展格式，data 前可能有 FLLR 填充块）。
/// 一块一块读，长录音也不会整段读进内存。
public final class WAVReader {
    public enum Failure: Error, CustomStringConvertible {
        case notWAV, noData, unsupported(String)
        public var description: String {
            switch self {
            case .notWAV: "不是 WAV 文件"
            case .noData: "WAV 里没有音频数据"
            case .unsupported(let s): "不支持的 WAV 格式：\(s)"
            }
        }
    }

    public let sampleRate: Int
    /// 样本总数（按 data 块大小和文件实际大小取小的）
    public let totalSamples: Int
    private let handle: FileHandle
    private var remainingBytes: Int

    public init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let fileSize = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let head = [UInt8](try handle.read(upToCount: 12) ?? Data())
        guard head.count == 12, head[0..<4] == [0x52, 0x49, 0x46, 0x46], head[8..<12] == [0x57, 0x41, 0x56, 0x45] else {
            throw Failure.notWAV
        }
        func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }

        var fmt: (tag: Int, channels: Int, rate: Int, bits: Int)?
        while true {
            let h = [UInt8](try handle.read(upToCount: 8) ?? Data())
            guard h.count == 8 else { throw Failure.noData }
            let id = String(decoding: h[0..<4], as: UTF8.self)
            let size = u32(h, 4)
            let pos = Int(try handle.offset())
            if id == "fmt " {
                let b = [UInt8](try handle.read(upToCount: size) ?? Data())
                guard b.count == size, size >= 16 else { throw Failure.notWAV }
                fmt = (u16(b, 0), u16(b, 2), u32(b, 4), u16(b, 14))
                try handle.seek(toOffset: UInt64(pos + size + (size & 1)))
            } else if id == "data" {
                guard let f = fmt else { throw Failure.notWAV }
                // 1 = PCM，0xFFFE = 扩展格式（afconvert 转 AAC 来源时会写这种，里面仍是 PCM）
                guard f.tag == 1 || f.tag == 0xFFFE, f.channels == 1, f.bits == 16 else {
                    throw Failure.unsupported("\(f.channels) 声道、\(f.bits) 位、格式 \(f.tag)")
                }
                sampleRate = f.rate
                remainingBytes = min(size, fileSize - pos) & ~1
                totalSamples = remainingBytes / 2
                return
            } else {
                try handle.seek(toOffset: UInt64(pos + size + (size & 1)))
            }
        }
    }

    deinit { try? handle.close() }

    /// 读最多 count 个样本，换算成 -1…1；读完返回空数组
    public func read(_ count: Int) throws -> [Float] {
        let want = min(count * 2, remainingBytes)
        guard want > 0, let d = try handle.read(upToCount: want), !d.isEmpty else { return [] }
        remainingBytes -= d.count
        return d.withUnsafeBytes { raw in
            let n = raw.count / 2
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
            return out
        }
    }
}
