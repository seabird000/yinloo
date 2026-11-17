import AppKit
import AVFoundation
import Foundation
import ServiceManagement
import UserNotifications

/// 1.4.0 改名「音录」：应用文件从「E1录音助手.app」换成「音录.app」，标识（bundle id）、设置域、钥匙串条目都没变，
/// 所以设置、转写记录和密钥都沿用。但拖新版进「应用程序」不会覆盖旧文件，这里收拾改名留下的三件事。
enum AppRename {
    static let oldFileName = "E1录音助手.app"

    /// 启动的第一步：同一个应用的另一份（多半是旧版）还开着，就请它退出，免得两份同时同步、重复转写。
    static func quitOtherCopies() {
        guard !UIPreview.enabled, let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where app.processIdentifier != me {
            Log.app.info("另一份应用还开着（\(app.bundleURL?.lastPathComponent ?? "未知", privacy: .public)），请它退出")
            app.terminate()
        }
    }

    /// 开机启动是按应用文件登记的，换了文件名系统可能就不认了：老用户第一次打开改名后的版本时补登记一次。
    /// （之前手动关掉开机启动的，升级后要再关一次，更新说明里写了。）
    static func reRegisterLoginItem() {
        let d = UserDefaults.standard, key = "loginItemAfterRename"
        guard !UIPreview.enabled, Bundle.main.bundleURL.lastPathComponent != oldFileName, !d.bool(forKey: key) else { return }
        d.set(true, forKey: key)
        guard d.bool(forKey: "loginItemInitialized"), SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
            Log.app.info("改名后重新登记了开机启动")
        } catch {
            Log.app.error("改名后登记开机启动失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 旧版文件还在「应用程序」里：问要不要移到废纸篓（需要时能从废纸篓放回去）。选「以后再说」就下次启动再问。
    @MainActor static func offerToTrashOldCopy() {
        guard !UIPreview.enabled, Bundle.main.bundleURL.lastPathComponent != oldFileName else { return }
        let dirs = [URL(fileURLWithPath: "/Applications"),
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        guard let old = dirs.map({ $0.appendingPathComponent(oldFileName) })
            .first(where: { Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier }) else { return }
        let a = NSAlert()
        a.messageText = "旧版「E1录音助手」还在"
        a.informativeText = "这个应用已经改名叫「音录」，设置、转写记录和密钥都已沿用。旧版留着用不上，还可能被误打开。"
            + "要把它移到废纸篓吗？需要时可以从废纸篓放回去。"
        a.addButton(withTitle: "移到废纸篓")
        a.addButton(withTitle: "以后再说")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.recycle([old]) { _, error in
            guard let error else { Log.app.info("旧版已移到废纸篓"); return }
            Log.app.error("旧版移到废纸篓失败：\(error.localizedDescription, privacy: .public)")
            DispatchQueue.main.async {
                let e = NSAlert()
                e.messageText = "没能移走旧版"
                e.informativeText = "请在访达里打开「应用程序」文件夹，把「E1录音助手」拖到废纸篓。"
                e.runModal()
            }
        }
    }
}

/// One-time changes to existing data, each guarded by its own key and logged.
extension Pipeline {
    // MARK: one-time migrations (run once each, on launch)

    /// Every change to existing data, in order. Each one remembers that it ran (its own key) and logs what it renamed
    /// to renamed-notes.log next to the job list, so nothing is changed twice and every rename can be undone by hand.
    func runMigrations() {
        relocateMovedNotes()                  // every launch: follow notes the user moved inside the vault
        renameNotesToCurrentScheme()          // 1.2: "yyMMdd - 标题" names, date property with time
        retitleNotesNamedAfterRecording()     // 1.3: titles by the shared rule (无实质内容 instead of the recording's name)
    }

    /// Once: notes this app wrote get the "261110 - 标题" name (only those still in the notes folder; moved ones are the
    /// user's to name), and their `date` property gains the time ("2026-11-10" → "2026-11-10T17:25") so Obsidian
    /// can sort by when the meeting was. The old → new names are kept in renamed-notes.log next to the job list.
    func renameNotesToCurrentScheme() {
        let key = "notesScheme-yyMMdd-v3"
        guard !UIPreview.enabled, !UserDefaults.standard.bool(forKey: key) else { return }
        let notesDir = URL(fileURLWithPath: settings.notesFolder).standardizedFileURL.path
        var log = "", changed = false
        for i in jobs.indices {
            guard jobs[i].state == .done, let old = jobs[i].notePath, FileManager.default.fileExists(atPath: old) else { continue }
            var url = URL(fileURLWithPath: old)
            Self.addTimeToDateProperty(url, jobs[i].created)
            let folder = url.deletingLastPathComponent()
            guard folder.standardizedFileURL.path == notesDir else { continue }
            let target = Self.freeNoteURL(in: folder, created: jobs[i].created, title: jobs[i].topic ?? jobs[i].title,
                                          ext: url.pathExtension.isEmpty ? "md" : url.pathExtension, except: url)
            guard target.standardizedFileURL != url.standardizedFileURL else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: target)
                url = target
                jobs[i].notePath = url.path
                log += "\(old)\t->\t\(url.path)\n"
                changed = true
            } catch {
                Log.notes.error("改名失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        Log.notes.info("命名迁移：\(self.jobs.count, privacy: .public) 条记录，\(changed ? "有改名" : "无改名", privacy: .public)")
        if changed {
            save()
            let f = storeURL.deletingLastPathComponent().appendingPathComponent("renamed-notes.log")
            if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(log.utf8)); try? h.close() }
            else { try? log.write(to: f, atomically: true, encoding: .utf8) }
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// "date: 2026-11-10" in a note's front matter → "date: 2026-11-10T17:25". Nothing else in the note changes.
    static func addTimeToDateProperty(_ url: URL, _ start: Date) {
        guard var text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("---\n"),
              let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else { return }
        let day = DateFormatter.cached("yyyy-MM-dd").string(from: start)
        guard let r = text.range(of: "\ndate: " + day + "\n", range: text.startIndex..<text.index(after: end.lowerBound)) else { return }
        text.replaceSubrange(r, with: "\ndate: " + DateFormatter.cached("yyyy-MM-dd'T'HH:mm").string(from: start) + "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Once: notes that got the recording's own name as their title (no AI title — usually nothing was said) are
    /// renamed by the current rule, e.g. 「261112 - 11月12日12点46分的录音」 → 「261112 - 无语音内容（1246）」.
    /// Only notes in the notes folder; the heading inside changes with it, nothing else in the note does.
    func retitleNotesNamedAfterRecording() {
        let key = "notesRetitled-v3"
        guard !UIPreview.enabled, !UserDefaults.standard.bool(forKey: key) else { return }
        let notesDir = URL(fileURLWithPath: settings.notesFolder).standardizedFileURL.path
        var log = ""
        for i in jobs.indices {
            let j = jobs[i]
            guard j.state == .done, let old = j.notePath, FileManager.default.fileExists(atPath: old),
                  let id = j.dataId, let b = loadResults(id) else { continue }
            let url = URL(fileURLWithPath: old)
            let current = j.topic ?? j.title
            let base = url.deletingPathExtension().lastPathComponent
            guard url.deletingLastPathComponent().standardizedFileURL.path == notesDir,
                  base.hasPrefix(Self.noteBase(j.created, current)) || base.hasPrefix(Self.noteBase(j.created, j.title)) else { continue }
            let title = MarkdownRenderer.title(results: b)
            // Compare with the file's name, not the stored title (the title may already have been updated on launch).
            guard !base.hasPrefix(Self.noteBase(j.created, title)) else { continue }
            let target = Self.freeNoteURL(in: url.deletingLastPathComponent(), created: j.created, title: title,
                                          ext: url.pathExtension.isEmpty ? "md" : url.pathExtension, except: url)
            do {
                try FileManager.default.moveItem(at: url, to: target)
                if target.pathExtension.lowercased() == "md", var text = try? String(contentsOf: target, encoding: .utf8) {
                    let day = DateFormatter.cached("yyMMdd").string(from: j.created)
                    if let r = text.range(of: "# \(day) - \(current) ") ?? text.range(of: "# \(day) - \(j.title) ") {
                        text.replaceSubrange(r, with: "# \(day) - \(title) ")
                        try? text.write(to: target, atomically: true, encoding: .utf8)
                    }
                }
                jobs[i].notePath = target.path
                jobs[i].topic = title
                log += "\(old)\t->\t\(target.path)\n"
            } catch {
                Log.notes.error("标题迁移失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        if !log.isEmpty {
            save()
            let f = storeURL.deletingLastPathComponent().appendingPathComponent("renamed-notes.log")
            if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(log.utf8)); try? h.close() }
        }
        UserDefaults.standard.set(true, forKey: key)
    }
}
