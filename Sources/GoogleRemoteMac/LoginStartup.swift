import AppKit
@MainActor final class LoginStartup:ObservableObject {
    static let shared=LoginStartup()
    @Published private(set) var enabled=false
    @Published private(set) var message=""
    private let label="local.googleremote.doubao.login"
    private var url:URL{FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")}
    init(){refresh()}
    func refresh(){
        guard let data=try? Data(contentsOf:url),let plist=try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],let args=plist["ProgramArguments"] as? [String] else{enabled=false;message="未开启登录启动";return}
        enabled=(plist["RunAtLoad"] as? Bool)==true && args.contains(Bundle.main.bundleURL.path)
        message=enabled ? "登录后后台启动，自动连接上次遥控器":"启动项指向旧位置，请重新开启"
    }
    func setEnabled(_ value:Bool){
        do {
            if value {
                let plist:[String:Any]=["Label":label,"RunAtLoad":true,"LimitLoadToSessionType":"Aqua","ProcessType":"Interactive","ProgramArguments":["/usr/bin/open","-g","-j",Bundle.main.bundleURL.path]]
                let data=try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0)
                try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                try data.write(to:url,options:.atomic)
                _=run(["bootout","gui/\(getuid())/\(label)"])
                _=run(["bootstrap","gui/\(getuid())",url.path])
            } else {
                _=run(["bootout","gui/\(getuid())/\(label)"])
                if FileManager.default.fileExists(atPath:url.path){
                    let backup=url.appendingPathExtension("disabled")
                    if FileManager.default.fileExists(atPath:backup.path){try FileManager.default.removeItem(at:backup)}
                    try FileManager.default.moveItem(at:url,to:backup)
                }
            }
            refresh()
        } catch{message="启动设置失败：\(error.localizedDescription)"}
    }
    private func run(_ arguments:[String])->Int32 {
        let process=Process();process.executableURL=URL(fileURLWithPath:"/bin/launchctl");process.arguments=arguments
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        do{try process.run();process.waitUntilExit();return process.terminationStatus}catch{return -1}
    }
}
