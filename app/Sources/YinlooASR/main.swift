// yinloo-asr：音录的本机识别子程序（sherpa-onnx）。
//
// 应用每转一条录音起一个，转完就退出：模型占的几百兆内存随进程还给系统；万一底层崩了（X-ASR 实测一段 48 秒的
// 音频会让 onnxruntime 抛异常、整个进程退出），也只是这个子程序退出，应用照常运行。
//
// 输入：标准输入一个 ASRJob（JSON）。输出：标准输出一行一个 ASRLine（进度若干行，最后是结果或错误）。
// 录音不离开这台 Mac：这个程序不联网。
import CSherpaOnnx
import Foundation
import LocalASRCore

func emit(_ line: ASRLine) {
    guard var d = try? JSONEncoder().encode(line) else { return }
    d.append(0x0A)
    FileHandle.standardOutput.write(d)
}

func fail(_ message: String) -> Never {
    emit(ASRLine(error: message))
    exit(1)
}

// C 字符串要在识别器活着的期间一直有效；进程转完就退出，不必释放
func c(_ s: String) -> UnsafePointer<CChar> { UnsafePointer(strdup(s)!) }

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let job = try? JSONDecoder().decode(ASRJob.self, from: input) else { fail("识别任务的格式不对") }

func file(_ role: String) -> UnsafePointer<CChar> {
    guard let p = job.files[role], FileManager.default.fileExists(atPath: p) else {
        fail("模型文件不全（缺 \(role)），请到「偏好 › 转写 › 服务选项」重新下载模型")
    }
    return c(p)
}

// ---- 加载模型
var cfg = SherpaOnnxOfflineRecognizerConfig()
cfg.feat_config.sample_rate = 16_000
cfg.feat_config.feature_dim = 80
cfg.model_config.num_threads = Int32(max(1, job.threads))
cfg.model_config.provider = c("cpu")
cfg.model_config.tokens = file("tokens")
cfg.decoding_method = c("greedy_search")
switch job.kind {
case "transducer":
    cfg.model_config.transducer.encoder = file("encoder")
    cfg.model_config.transducer.decoder = file("decoder")
    cfg.model_config.transducer.joiner = file("joiner")
case "paraformer":
    cfg.model_config.paraformer.model = file("model")
default:
    fail("不认识的模型类型：\(job.kind)")
}
let loadStart = Date()
guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&cfg) else { fail("模型加载失败，文件可能损坏，请重新下载模型") }
var punctuation: OpaquePointer?
if let p = job.punct {
    guard FileManager.default.fileExists(atPath: p) else { fail("标点模型文件不在，请重新下载模型") }
    var pc = SherpaOnnxOfflinePunctuationConfig()
    pc.model.ct_transformer = c(p)
    pc.model.num_threads = Int32(max(1, job.threads))
    pc.model.provider = c("cpu")
    punctuation = SherpaOnnxCreateOfflinePunctuation(&pc)
    if punctuation == nil { fail("标点模型加载失败，文件可能损坏，请重新下载模型") }
}
let loadSec = Date().timeIntervalSince(loadStart)

// ---- 读音频、切段、逐段识别
let reader: WAVReader
do { reader = try WAVReader(url: URL(fileURLWithPath: job.wav)) } catch { fail("读不了音频：\(error)") }
guard reader.sampleRate == 16_000 else { fail("音频不是 16 kHz（\(reader.sampleRate) Hz）") }

let rate = 16_000
var cutter = ChunkCutter(rate: rate, maxSec: min(job.maxChunkSec, 30), searchSec: 4)
var segments: [TimedText] = []
var levels: [Float] = []
var chunks = 0
var decoded = 0
let total = max(reader.totalSamples, 1)
let decodeStart = Date()

func decode(_ chunk: ChunkCutter.Chunk) {
    chunks += 1
    let stream = SherpaOnnxCreateOfflineStream(recognizer)
    chunk.samples.withUnsafeBufferPointer {
        SherpaOnnxAcceptWaveformOffline(stream, Int32(rate), $0.baseAddress, Int32($0.count))
    }
    SherpaOnnxDecodeOfflineStream(recognizer, stream)
    let startMs = chunk.startMs(rate: rate), endMs = chunk.endMs(rate: rate)
    if let r = SherpaOnnxGetOfflineStreamResult(stream) {
        var text = r.pointee.text.map { String(cString: $0) } ?? ""
        var tokens: [String] = [], times: [Int] = []
        if r.pointee.count > 0, let arr = r.pointee.tokens_arr, let ts = r.pointee.timestamps {
            for i in 0..<Int(r.pointee.count) {
                tokens.append(arr[i].map { String(cString: $0) } ?? "")
                times.append(startMs + Int(ts[i] * 1000))
            }
        }
        SherpaOnnxDestroyOfflineRecognizerResult(r)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = punctuation, !text.isEmpty, let out = SherpaOfflinePunctuationAddPunct(p, text) {
            text = String(cString: out)
            SherpaOfflinePunctuationFreeText(out)
        }
        for var s in Sentencer.split(text: text, tokens: tokens, times: times, chunkStartMs: startMs, chunkEndMs: endMs) {
            s.text = RepeatGuard.clean(s.text)
            if !s.text.isEmpty { segments.append(s) }
        }
    }
    SherpaOnnxDestroyOfflineStream(stream)
    decoded += chunk.samples.count
    emit(ASRLine(progress: min(0.99, Double(decoded) / Double(total))))
}

let window = ASRResult.levelWindow
do {
    while true {
        let block = try reader.read(window * 20)   // 5 秒一块
        if block.isEmpty { break }
        var i = 0
        while i < block.count {
            let w = block[i..<min(i + window, block.count)]
            levels.append(sqrt(w.reduce(0) { $0 + $1 * $1 } / Float(w.count)))
            i += window
        }
        for chunk in cutter.append(block) { decode(chunk) }
    }
} catch {
    fail("读音频出错：\(error)")
}
if let last = cutter.finish() { decode(last) }

emit(ASRLine(done: ASRResult(durationMs: reader.totalSamples * 1000 / rate, segments: segments, levels: levels, chunks: chunks,
                             loadSec: (loadSec * 10).rounded() / 10, decodeSec: (Date().timeIntervalSince(decodeStart) * 10).rounded() / 10)))
if let p = punctuation { SherpaOnnxDestroyOfflinePunctuation(p) }
SherpaOnnxDestroyOfflineRecognizer(recognizer)
exit(0)
