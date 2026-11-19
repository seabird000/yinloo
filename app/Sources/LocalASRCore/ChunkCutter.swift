import Accelerate
import Foundation

/// 本机转写的切段（给 sherpa-onnx 这类一次只能吃十几二十秒的模型用）。
///
/// **不丢任何音频。** M0 第二轮实测（2026-11-18）：用人声检测（Silero VAD）把「静音」扔掉再识别，会把远处、
/// 小声的说话一起扔掉，远场录音因此漏掉一半；改成整段都送去识别、只在安静处切开后，和听悟的差异从 57% 降到 18.5%。
/// 所以音量只用来挑切点：每段最长 `maxSec` 秒，到上限时在最后 `searchSec` 秒里找最安静的 0.1 秒，从它中间切开。不重叠。
///
/// 边读边切：内存里最多留一段多一点的样本，长录音也不会整段读进内存。
public struct ChunkCutter {
    public struct Chunk: Equatable, Sendable {
        public let start: Int          // 第一个样本在整段录音里的位置
        public let samples: [Float]
        public init(start: Int, samples: [Float]) { self.start = start; self.samples = samples }
        public func startMs(rate: Int) -> Int { start * 1_000 / rate }
        public func endMs(rate: Int) -> Int { (start + samples.count) * 1_000 / rate }
    }

    public let rate: Int
    public let maxSamples: Int
    public let searchSamples: Int
    public let frame: Int
    private var buffer: [Float] = []
    private var bufferStart = 0

    /// maxSec 不要超过 30：X-ASR 实测 48 秒的一段会让底层抛异常、整个进程退出（40 秒还行）。
    public init(rate: Int = 16_000, maxSec: Double = 20, searchSec: Double = 4) {
        precondition(maxSec > 0 && maxSec <= 30, "每段太长，X-ASR 吃不下")
        self.rate = rate
        maxSamples = Int(Double(rate) * maxSec)
        searchSamples = min(Int(Double(rate) * searchSec), maxSamples)
        frame = max(rate / 10, 2)
    }

    /// 送进一批样本，返回因此凑满的段（可能是 0 段、1 段或几段）。
    public mutating func append<C: Collection>(_ samples: C) -> [Chunk] where C.Element == Float {
        buffer.append(contentsOf: samples)
        var out: [Chunk] = []
        while buffer.count > maxSamples {
            let cut = quietestCut()
            out.append(Chunk(start: bufferStart, samples: Array(buffer[0..<cut])))
            buffer.removeFirst(cut)
            bufferStart += cut
        }
        return out
    }

    /// 录音读完：剩下的不论长短都是最后一段。
    public mutating func finish() -> Chunk? {
        defer { bufferStart += buffer.count; buffer.removeAll() }
        return buffer.isEmpty ? nil : Chunk(start: bufferStart, samples: buffer)
    }

    /// 在 [maxSamples - searchSamples, maxSamples] 里按 0.1 秒一格、半格一步找平均幅度最小的一格，返回它的中点。
    private func quietestCut() -> Int {
        let lo = maxSamples - searchSamples, hi = maxSamples
        var best = hi
        var bestE = Float.greatestFiniteMagnitude
        buffer.withUnsafeBufferPointer { p in
            var f = lo
            while f < hi - frame {
                var e: Float = 0
                vDSP_meamgv(p.baseAddress! + f, 1, &e, vDSP_Length(frame))
                if e < bestE { bestE = e; best = f + frame / 2 }
                f += frame / 2
            }
        }
        return best
    }
}
