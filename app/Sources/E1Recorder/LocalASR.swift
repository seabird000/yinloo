import Accelerate
import AVFoundation
import Foundation
import Speech

/// 本机转写引擎：输入一个音频文件，输出统一转写格式。录音不离开这台 Mac。
/// 两类实现：sherpa-onnx 的开源模型（SherpaEngine，默认 X-ASR，要先下载模型）和苹果系统自带的
/// SpeechTranscriber（macOS 26 起，零下载，远场录音漏得多，见 M0 实测记录）。
protocol LocalEngine: Sendable {
    var id: String { get }
    func transcribe(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript
}

enum LocalEngines {
    /// 系统是否带苹果的本机转写（macOS 26 起）
    static var appleSupported: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// 中文语音模型是否已装好（没装要先下载一次，系统组件，来自苹果）
    static func appleChineseReady() async -> Bool {
        guard #available(macOS 26, *), appleSupported else { return false }
        guard let zh = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else { return false }
        return await SpeechTranscriber.installedLocales.contains { $0.identifier == zh.identifier }
    }

    /// 下载并安装中文语音模型。由用户在偏好设置里点按钮触发，不在转写途中自动下载。
    static func installAppleChinese(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26, *), appleSupported else { throw AppError("这台 Mac 的系统低于 macOS 26，不能用苹果自带的本机转写") }
        guard let zh = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw AppError("系统不支持中文本机转写")
        }
        let t = SpeechTranscriber(locale: zh, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            let watch = Task {
                while !Task.isCancelled {
                    progress(req.progress.fractionCompleted)
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            defer { watch.cancel() }
            try await req.downloadAndInstall()
        }
        progress(1)
    }

    static func engine(_ id: String) -> LocalEngine? {
        switch id {
        case "apple":
            if #available(macOS 26, *), appleSupported { return AppleSpeechEngine() }
            return nil
        default:
            return LocalModels.find(id).map { SherpaEngine(model: $0) }
        }
    }

    /// 选中的引擎能不能马上用：苹果引擎看中文语音模型装没装，sherpa 看模型文件在不在
    static func isReady(_ id: String) async -> Bool {
        if id == "apple" { return await appleChineseReady() }
        return LocalModels.find(id)?.isInstalled ?? false
    }

    static func name(_ id: String) -> String {
        id == "apple" ? "苹果自带" : (LocalModels.find(id)?.name ?? id)
    }

    /// 还不能用时，告诉用户差什么
    static func notReadyReason(_ id: String) -> String {
        if id == "apple" {
            return appleSupported ? "中文语音模型还没下载" : "这台 Mac 的系统低于 macOS 26，用不了苹果自带的本机转写"
        }
        return "本机模型「\(name(id))」还没下载"
    }
}

// MARK: - 苹果 SpeechTranscriber

@available(macOS 26, *)
struct AppleSpeechEngine: LocalEngine {
    let id = "apple"

    func transcribe(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        guard let zh = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw AppError("系统不支持中文本机转写")
        }
        guard await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == zh.identifier }) else {
            throw AppError("中文语音模型还没下载，请到「偏好设置 › 转写 › 服务选项」下载")
        }
        // 统一成 16 kHz 单声道 16 位 WAV（和 M0 实测一致；也方便算增益）
        let wav = try await AudioPrep.monoWAV16k(file)
        defer { try? FileManager.default.removeItem(at: wav) }

        let transcriber = SpeechTranscriber(locale: zh, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppError("本机转写无法确定音频格式")
        }
        let reader = try AudioPrep.Reader(wav)
        let total = max(reader.durationSec, 0.001)

        let collect = Task { () -> [Transcript.Segment] in
            var segs: [Transcript.Segment] = []
            for try await r in transcriber.results where r.isFinal {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                let start = r.range.start.seconds, end = r.range.end.seconds
                segs.append(.init(id: segs.count, startMs: Int(start * 1000), endMs: Int(end * 1000), text: text))
                progress(min(0.99, end / total))
            }
            return segs
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        let levels: [Float]
        do {
            levels = try reader.forEachBuffer(format: format) { cont.yield(AnalyzerInput(buffer: $0)) }
            cont.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            cont.finish()
            await analyzer.cancelAndFinishNow()
            collect.cancel()
            throw error
        }
        let segs = try await collect.value
        progress(1)
        var t = Transcript(provider: "apple", model: "SpeechTranscriber-" + zh.identifier, durationMs: Int(total * 1000),
                           segments: segs,
                           features: .init(wordTimestamps: false, speakers: false, punctuation: true, numberNormalization: true))
        t.coverage = Coverage.check(levels: levels, window: Double(AudioPrep.Reader.window) / 16000, segments: segs)
        return t
    }
}

// MARK: - 音频准备

enum AudioPrep {
    /// 任意 Core Audio 能读的文件 → 临时的 16 kHz 单声道 16 位 WAV
    static func monoWAV16k(_ src: URL) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src.path, out.path]
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { p.terminationHandler = nil; cont.resume(throwing: error) }
        }
        guard status == 0, FileManager.default.fileExists(atPath: out.path) else {
            try? FileManager.default.removeItem(at: out)
            throw AppError("读不了这个录音文件的格式")
        }
        return out
    }

    /// 分块读 16 kHz 单声道文件，转成识别器要的格式；顺带记下每 0.25 秒的音量（漏转自检用）。长录音也只占几兆内存。
    struct Reader {
        let file: AVAudioFile
        static let window: AVAudioFrameCount = 4000   // 0.25 秒（16 kHz）

        var durationSec: Double { Double(file.length) / file.processingFormat.sampleRate }

        init(_ url: URL) throws {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        /// 逐块转成 format 交给 body；返回每块的音量（RMS，0～1）。
        @discardableResult
        func forEachBuffer(format: AVAudioFormat, _ body: (AVAudioPCMBuffer) -> Void) throws -> [Float] {
            file.framePosition = 0
            let inFormat = file.processingFormat
            guard let converter = AVAudioConverter(from: inFormat, to: format),
                  let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: Self.window) else {
                throw AppError("本机转写无法转换音频格式")
            }
            let ratio = format.sampleRate / inFormat.sampleRate
            var levels: [Float] = []
            while file.framePosition < file.length {
                try file.read(into: buf, frameCount: Self.window)
                guard buf.frameLength > 0 else { break }
                if let ch = buf.floatChannelData?[0] {
                    var r: Float = 0
                    vDSP_rmsqv(ch, 1, &r, vDSP_Length(buf.frameLength))
                    levels.append(r)
                }
                let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
                guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { continue }
                var fed = false
                var err: NSError?
                converter.convert(to: out, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buf
                }
                if let err { throw err }
                if out.frameLength > 0 { body(out) }
            }
            return levels
        }
    }
}

// MARK: - 接进转写队列

/// 本机转写走现有队列，做法和「自定义接口」一样：upload 原样返回路径；createTask 在本机转完，结果存进 local/<编号>.json；
/// poll 读回来，有整理模型就让大模型出摘要、待办、章节（大模型只收到文字）。
struct LocalClient: TranscriptionService {
    let engineId: String
    let note: NoteWriter?
    var hotwords: [String] = []

    private var store: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("E1Recorder/local", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func upload(_ file: URL) async throws -> String { file.path }

    func createTask(fileURL: String) async throws -> String {
        guard let engine = LocalEngines.engine(engineId) else { throw AppError("这台 Mac 上用不了所选的本机转写引擎") }
        let report = UploadProgress.report
        let t = try await engine.transcribe(URL(fileURLWithPath: fileURL)) { report?($0) }
        let id = "local-" + UUID().uuidString
        try t.write(to: store.appendingPathComponent(id + ".json"))
        return id
    }

    func poll(_ id: String) async throws -> PollResult {
        let u = store.appendingPathComponent(id + ".json")
        guard let t = try? Transcript.read(from: u) else { return .failed("本机转写结果丢失，请重试") }
        var b = TranscriptBundle(transcription: t.tingwuParagraphs())
        b.transcript = t
        if let c = t.coverage, c.shouldWarn { b.notices.append(c.notice) }
        try await note?.write(t.promptLines(), hotwords: hotwords, into: &b)
        try? FileManager.default.removeItem(at: u)
        return .done(b)
    }

    func testConnection() async throws {
        guard LocalEngines.engine(engineId) != nil else { throw AppError("这台 Mac 上用不了所选的本机转写引擎") }
        guard await LocalEngines.isReady(engineId) else { throw AppError(LocalEngines.notReadyReason(engineId)) }
    }
}
