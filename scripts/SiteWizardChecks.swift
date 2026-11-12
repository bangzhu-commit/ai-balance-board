import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Darwin
import BalanceCore

@main
struct SiteWizardChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }; count += 1
        }
        func rejects(_ message: String, _ work: () throws -> Void) {
            do { try work(); fatalError(message) } catch { count += 1 }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("site-wizard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configText = CustomSiteAgentGuide.example(name: "示例额度", origin: "https://relay.example.com")
        let file = directory.appendingPathComponent("quota.json")
        try Data(configText.utf8).write(to: file)
        check((try? CustomSiteConfigurationFile.read(file)) == configText, "Local JSON file round-trips")
        check((try? CustomSiteConfigurationFile.url(from: file.dataRepresentation)) == file, "Dropped file URL decodes")
        rejects("Remote file URL must be rejected") { _ = try CustomSiteConfigurationFile.url(from: Data("https://relay.example.com/quota.json?secret=private".utf8)) }
        rejects("Remote file share must be rejected") { _ = try CustomSiteConfigurationFile.read(URL(string: "file://server.example.com/tmp/quota.json")!) }
        rejects("URL credentials must be rejected") { _ = try CustomSiteConfigurationFile.url(from: Data("file://user:password@localhost/tmp/quota.json".utf8)) }
        rejects("Non JSON files rejected") { _ = try CustomSiteConfigurationFile.read(directory.appendingPathComponent("quota.txt")) }
        let folder = directory.appendingPathComponent("folder.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        rejects("Directory must not be read") { _ = try CustomSiteConfigurationFile.read(folder) }
        let symbolic = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: file)
        rejects("Final symlink must not be followed") { _ = try CustomSiteConfigurationFile.read(symbolic) }
        let fifo = directory.appendingPathComponent("pipe.json")
        check(mkfifo(fifo.path, 0o600) == 0, "FIFO fixture created")
        rejects("Special files rejected without blocking") { _ = try CustomSiteConfigurationFile.read(fifo) }
        let tooBig = directory.appendingPathComponent("large.json")
        try Data(repeating: 65, count: 65_537).write(to: tooBig)
        rejects("Oversize input bounded") { _ = try CustomSiteConfigurationFile.read(tooBig) }
        let invalidUTF8 = directory.appendingPathComponent("invalid.json")
        try Data([0xFF, 0xFE]).write(to: invalidUTF8)
        rejects("Binary data rejected") { _ = try CustomSiteConfigurationFile.read(invalidUTF8) }

        let website = CustomSiteEditorModel(record: nil, kind: .website)
        check(!website.canPrepareTask && !website.canSave && !website.showAdvanced, "Empty website wizard requires only URL, advanced hidden")
        website.setTargetURL("https://relay.example.com/dashboard/private?token=DO_NOT_COPY#secret")
        check(website.canPrepareTask && website.taskName == "relay.example.com", "Pasted URL supplies default name")
        check(website.normalizedTarget?.origin == "https://relay.example.com", "Prompt target is normalized")
        check(website.agentTask?.contains("DO_NOT_COPY") == false && website.agentTask?.contains("/dashboard/private") == false, "Sensitive path/query/fragment not copied")
        check(website.agentTask?.contains("可下载的 .json") == true && website.agentTask?.contains("不能只交付这一次") == true, "Task requests reusable downloadable config")
        let ticket = website.beginImport()
        website.finishImport(.success(configText), generation: ticket)
        check(website.reviewedConfig?.origin == "https://relay.example.com" && !website.isImporting, "Import auto-validates before showing preview")
        check(!website.canSave, "Source must be explicitly confirmed")
        website.sourceConfirmed = true
        check(website.canSave, "Confirmed valid source may be saved")
        website.setTargetName("我的站点")
        check(website.reviewedConfig?.name == "我的站点" && !website.canSave, "Renaming preserves rules but invalidates confirmation")
        website.setTargetURL("https://other.example.com/dashboard")
        check(website.reviewedConfig == nil && !website.canSave, "Mismatched domain cannot save")
        check(website.message.contains("另一个站点"), "Mismatch provides actionable error")
        website.setTargetURL("http://relay.example.com?secret=hidden")
        check(!website.canPrepareTask && website.agentTask == nil, "Invalid protocol never produces task")
        check(website.targetError?.contains("hidden") == false, "Invalid URL error never echoes secret")
        website.setTargetURL("https://relay.example.com:443/login")
        check(website.reviewedConfig != nil, "Canonical equivalent origin matches")
        website.sourceConfirmed = true
        website.setConfigurationText("{not JSON}")
        check(website.reviewedConfig == nil && !website.canSave, "Editing raw text revokes previous result synchronously")
        website.validate()
        check(website.reviewedConfig == nil && !website.message.isEmpty, "Bad JSON has an error, not a successful preview")

        let direct = CustomSiteEditorModel(record: nil, kind: .website)
        direct.finishImport(.success(configText), generation: direct.beginImport())
        check(direct.reviewedConfig != nil && !direct.canSave && direct.targetURL.isEmpty, "Existing config can be imported without URL but needs source confirmation")
        direct.sourceConfirmed = true
        check(direct.canSave, "Direct import works after explicit source confirmation")
        let old = direct.beginImport()
        direct.setTargetURL("https://other.example.com")
        direct.finishImport(.success(configText), generation: old)
        check(direct.reviewedConfig == nil && !direct.canSave, "Late import cannot overwrite newly edited target")
        let old2 = direct.beginImport()
        let current = direct.beginImport()
        direct.finishImport(.success(configText), generation: old2)
        check(direct.isImporting, "Old completion cannot finish newer import")
        direct.finishImport(.failure(CustomSiteConfigurationFile.Failure.unreadable), generation: current)
        check(!direct.isImporting && direct.reviewedConfig == nil, "Current import failure completes cleanly")
        direct.setTargetURL("")
        let closing = direct.beginImport()
        direct.deactivate()
        direct.finishImport(.success(configText), generation: closing)
        check(direct.reviewedConfig == nil && !direct.canSave && !direct.isImporting, "Closing editor cancels pending completion")

        let ai = CustomSiteEditorModel(record: nil, seedName: "Muse", kind: .aiTool)
        check(ai.canPrepareTask && ai.agentTask?.contains("目标名称：Muse") == true, "Tool-only flow preserved")
        let existingConfig = try CustomSiteConfig.decode(data: Data(configText.utf8))
        let editing = CustomSiteEditorModel(record: CustomSiteRecord(config: existingConfig))
        check(editing.reviewedConfig == existingConfig && !editing.canSave, "Existing config previews without silently approving edit")

        let dropped = CustomSiteEditorModel(record: nil, kind: .website)
        let item = NSItemProvider()
        item.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(file.dataRepresentation, nil); return nil
        }
        check(dropped.acceptDrop([item]), "Native item provider accepted without frontmost UI")
        let deadline = Date().addingTimeInterval(5)
        while dropped.isImporting && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        check(dropped.reviewedConfig == existingConfig && !dropped.isImporting, "Native provider payload loaded and parsed automatically")
        dropped.sourceConfirmed = true
        check(!dropped.acceptDrop([item, item]) && !dropped.canSave, "Multiple file drop rejected and old approval removed")
        let remote = NSItemProvider()
        remote.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(Data("https://relay.example.com/config.json?secret=no".utf8), nil); return nil
        }
        check(dropped.acceptDrop([remote]), "File representation enters validator")
        let remoteDeadline = Date().addingTimeInterval(5)
        while dropped.isImporting && Date() < remoteDeadline { try await Task.sleep(for: .milliseconds(20)) }
        check(dropped.reviewedConfig == nil && !dropped.isImporting && !dropped.message.contains("secret"), "Remote URL disguised as file cannot be read")
        check(!NSApplication.shared.windows.contains(where: \.isVisible) && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground, "All fixture operations preserve foreground and show no window")
        print("Site wizard: \(count) checks passed; no network, clipboard, file panel or visible window")
    }
}
