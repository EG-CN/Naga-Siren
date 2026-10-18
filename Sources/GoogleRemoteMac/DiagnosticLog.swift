import Foundation
import Combine

// Temporary diagnostics: delete this module and DiagnosticLog.record call sites
// after stability acceptance. Never pass audio, transcript or keyboard contents.
@MainActor final class DiagnosticLog: ObservableObject {
    static let shared = DiagnosticLog()
    @Published private(set) var problem = ""
    @Published var enabled: Bool {
        didSet {
            if persistent { UserDefaults.standard.set(enabled,forKey:"naga.diagnostics.enabled") }
            if enabled { record("logging.enabled") }
        }
    }
    let directory: URL
    private let persistent: Bool
    private let maximumBytes: Int
    private let maximumFiles: Int
    private let retention: TimeInterval
    private let launch = UUID().uuidString
    private let encoder = JSONEncoder()
    private struct Entry: Encodable {
        let time: String
        let launch: String
        let event: String
        let session: String?
        let fields: [String:String]
    }
    init(directory: URL? = nil, maximumBytes: Int = 512*1024, maximumFiles: Int = 4, retention: TimeInterval = 7*86400) {
        self.persistent = directory == nil
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("NagaSiren/Diagnostics",isDirectory:true)
        self.maximumBytes=maximumBytes;self.maximumFiles=maximumFiles;self.retention=retention
        enabled = directory == nil ? (UserDefaults.standard.object(forKey:"naga.diagnostics.enabled") as? Bool ?? true) : true
        encoder.outputFormatting = [.sortedKeys]
        record("app.start",fields:["version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "test","routePolicy":"builtin-unless-remote"])
    }
    static func record(_ event: String, session: UUID? = nil, fields: [String:String] = [:]) {
        shared.record(event,session:session?.uuidString,fields:fields)
    }
    func record(_ event:String,session:String?=nil,fields:[String:String]=[:]) {
        guard enabled else{return}
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try prune()
            let entry=Entry(time:Date().ISO8601Format(),launch:launch,event:event,session:session,fields:fields)
            var line=try encoder.encode(entry);line.append(10)
            guard line.count<=maximumBytes else {throw Failure()}
            let current=file(0)
            let size=(try? current.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            if size+line.count>maximumBytes {
                if FileManager.default.fileExists(atPath:file(maximumFiles-1).path) {try FileManager.default.removeItem(at:file(maximumFiles-1))}
                if maximumFiles>1 {
                    for n in stride(from:maximumFiles-2,through:0,by:-1) where FileManager.default.fileExists(atPath:file(n).path) {
                        try FileManager.default.moveItem(at:file(n),to:file(n+1))
                    }
                }
            }
            if !FileManager.default.fileExists(atPath:current.path) {
                FileManager.default.createFile(atPath:current.path,contents:nil,attributes:[.posixPermissions:0o600])
            }
            let handle=try FileHandle(forWritingTo:current)
            defer {try? handle.close()}
            try handle.seekToEnd();try handle.write(contentsOf:line)
            problem=""
        } catch {problem="诊断日志写入失败，请检查可用磁盘空间或目录权限"}
    }
    private func file(_ n:Int)->URL{directory.appendingPathComponent("diagnostic-\(n).jsonl")}
    private func prune() throws {
        for n in 0..<maximumFiles {
            let url=file(n)
            if let date=try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,Date().timeIntervalSince(date)>retention {try FileManager.default.removeItem(at:url)}
        }
    }
    func contents() throws -> Data {
        try prune()
        var result=Data()
        for n in stride(from:maximumFiles-1,through:0,by:-1) {
            if FileManager.default.fileExists(atPath:file(n).path) {result.append(try Data(contentsOf:file(n)))}
        }
        return result
    }
    func clear() throws {
        for n in 0..<maximumFiles where FileManager.default.fileExists(atPath:file(n).path) {try FileManager.default.removeItem(at:file(n))}
        problem=""
    }
    struct Failure:Error{}
}
