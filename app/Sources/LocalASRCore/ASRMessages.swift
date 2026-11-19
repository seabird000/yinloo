import Foundation

/// 应用 → 识别子程序（yinloo-asr）：一个任务，JSON，从标准输入给。
public struct ASRJob: Codable, Sendable {
    /// 16 kHz、单声道、16 位 PCM 的 WAV
    public var wav: String
    /// "transducer"（X-ASR 等）或 "paraformer"
    public var kind: String
    /// 模型文件的绝对路径：transducer 要 encoder、decoder、joiner、tokens；paraformer 要 model、tokens
    public var files: [String: String]
    /// 标点模型（模型自己不出标点时用，如 Paraformer）
    public var punct: String?
    public var threads: Int
    /// 每段最长几秒（不要超过 30，见 ChunkCutter）
    public var maxChunkSec: Double

    public init(wav: String, kind: String, files: [String: String], punct: String?, threads: Int, maxChunkSec: Double = 20) {
        self.wav = wav; self.kind = kind; self.files = files; self.punct = punct; self.threads = threads; self.maxChunkSec = maxChunkSec
    }
}

/// 识别子程序 → 应用：标准输出里一行一个，进度若干行，最后一行是结果或错误。
public struct ASRLine: Codable, Sendable {
    public var progress: Double?
    public var done: ASRResult?
    public var error: String?
    public init(progress: Double? = nil, done: ASRResult? = nil, error: String? = nil) {
        self.progress = progress; self.done = done; self.error = error
    }
}

public struct ASRResult: Codable, Sendable {
    public var durationMs: Int
    public var segments: [TimedText]
    /// 每 0.25 秒的音量（RMS，0～1），应用拿来做「漏转自检」
    public var levels: [Float]
    public var chunks: Int
    public var loadSec: Double
    public var decodeSec: Double
    public init(durationMs: Int, segments: [TimedText], levels: [Float], chunks: Int, loadSec: Double, decodeSec: Double) {
        self.durationMs = durationMs; self.segments = segments; self.levels = levels
        self.chunks = chunks; self.loadSec = loadSec; self.decodeSec = decodeSec
    }

    public static let levelWindow = 4000   // 0.25 秒（16 kHz）
}
