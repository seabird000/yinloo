import Foundation
import LocalASRCore

/// sherpa-onnx 本机转写：起一个识别子程序（yinloo-asr，和主程序放在同一个文件夹），把录音转成 16 kHz 的 WAV
/// 交给它，读它一行一行吐出来的进度和结果。录音和文字都不离开这台 Mac。
struct SherpaEngine: LocalEngine {
    let model: LocalModel
    var id: String { model.id }

    /// 测试用：指到 .build 里编出来的子程序
    nonisolated(unsafe) static var helperOverride: URL?

    static var helperURL: URL {
        helperOverride ?? Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("yinloo-asr")
    }

    /// 识别用几个线程：4 个（M0 实测 4 线程在 8 GB 的 M2 上最划算），核少的机器留 2 个给别的程序
    static var threads: Int { max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)) }

    func transcribe(_ file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        guard model.isInstalled else { throw AppError("本机模型「\(model.name)」还没下载，请到「偏好 › 转写 › 服务选项」下载") }
        guard FileManager.default.isExecutableFile(atPath: Self.helperURL.path) else {
            throw AppError("找不到本机识别程序，请重新安装音录")
        }
        // 同一时间只转一条：每个子程序要占几百兆内存，8 GB 的 Mac 上并排跑两个会很卡
        return try await LocalASRGate.shared.run {
            let wav = try await AudioPrep.monoWAV16k(file)
            defer { try? FileManager.default.removeItem(at: wav) }
            let job = ASRJob(wav: wav.path, kind: model.kind, files: model.paths, punct: model.punctPath, threads: Self.threads)
            let r = try await Self.run(job, progress: progress)
            let segs = r.segments.enumerated().map { i, s in
                Transcript.Segment(id: i, startMs: s.startMs, endMs: s.endMs, text: s.text)
            }
            var t = Transcript(provider: "sherpa", model: model.id, durationMs: r.durationMs, segments: segs,
                               features: .init(wordTimestamps: false, speakers: false, punctuation: true, numberNormalization: false))
            t.coverage = Coverage.check(levels: r.levels, window: Double(ASRResult.levelWindow) / 16000, segments: segs)
            return t
        }
    }

    /// 起子程序跑一个任务。取消（用户删掉任务、退出应用）时结束子程序。
    static func run(_ job: ASRJob, progress: @escaping @Sendable (Double) -> Void) async throws -> ASRResult {
        let p = Process()
        p.executableURL = helperURL
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        // stderr 只留最后一点，出错时帮着说明原因（onnxruntime 的报错在这里）
        let tail = ErrorTail()
        errors.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { tail.append(d) }
        }
        try p.run()
        input.fileHandleForWriting.write(try JSONEncoder().encode(job))
        try? input.fileHandleForWriting.close()

        return try await withTaskCancellationHandler {
            var result: ASRResult?
            var failure: String?
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let m = try? JSONDecoder().decode(ASRLine.self, from: Data(line.utf8)) else { continue }
                if let v = m.progress { progress(v) }
                if let d = m.done { result = d }
                if let e = m.error { failure = e }
            }
            p.waitUntilExit()
            try Task.checkCancellation()
            if let failure { throw AppError(failure) }
            if p.terminationReason == .uncaughtSignal {
                throw AppError("本机识别程序意外退出（信号 \(p.terminationStatus)），这条录音没转完。可以换一个本机模型重转。")
            }
            guard p.terminationStatus == 0, let result else {
                let why = tail.text.split(separator: "\n").last.map(String.init) ?? ""
                throw AppError("本机识别失败（退出码 \(p.terminationStatus)）" + (why.isEmpty ? "" : "：" + why.prefix(160)))
            }
            progress(1)
            return result
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
    }
}

/// 子程序 stderr 的最后 4 KB
private final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > 4096 { data = data.suffix(4096) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// 本机转写排队：同一时间只跑一个。
actor LocalASRGate {
    static let shared = LocalASRGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
