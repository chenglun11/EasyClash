import Foundation
import Darwin

public struct Lease: Codable {
    public var owner:Int32
    public var updated:Date
    public var settings:Settings
    public var marker:String
    public var appPath:String?
    public init(settings:Settings,appPath:String?=nil) {
        owner=getpid();updated=Date();self.settings=settings;marker="easyclash-"+UUID().uuidString.lowercased()+".invalid";self.appPath=appPath
    }
    public func expired(now:Date=Date(),ownerAlive:Bool) -> Bool {
        !ownerAlive || now.timeIntervalSince(updated)>45 || now.timeIntervalSince(updated)<(-5) || appPath.map { !FileManager.default.fileExists(atPath:$0) } == true
    }
}
public enum Recovery {
    public static func markerPresent(_ marker:String,api:ClashAPI) throws -> Bool {
        let rules=try api.request("/rules")["rules"] as? [[String:Any]] ?? []
        return rules.contains { $0["type"] as? String == "Domain" && $0["payload"] as? String == marker && $0["proxy"] as? String == "REJECT" }
    }
    @discardableResult public static func restore(root:URL,force:Bool=false,explicitSocket:String?=nil) throws -> Bool {
        let url=root.appendingPathComponent("lease.json")
        guard FileManager.default.fileExists(atPath:url.path) else {return true}
        let lock=try FileLock(root.appendingPathComponent("transaction.lock"));defer {withExtendedLifetime(lock){}}
        let lease=try Files.read(Lease.self,url)
        if !force && !lease.expired(ownerAlive:kill(lease.owner,0)==0) {return false}
        let directory=URL(fileURLWithPath:lease.settings.clashDirectory)
        let api=try ClashAPI(directory:directory,client:lease.settings.client,explicitSocket:explicitSocket)
        if try markerPresent(lease.marker,api:api) {
            let source=lease.settings.configURL
            let before=try Data(contentsOf:source)
            let base=try Files.yaml(source)
            guard try Data(contentsOf:source)==before else {throw AppFailure("恢复时 Clash 正在更新配置，稍后重试")}
            try api.reload(base,requireTun:false)
            guard try !markerPresent(lease.marker,api:api) else {throw AppFailure("恢复后仍检测到本应用规则")}
        }
        // Absence of the marker means Clash has independently replaced the overlay. Do not overwrite it.
        try FileManager.default.removeItem(at:url)
        Audit(root:root).event("runtime_restored")
        return true
    }
    public static func installHelper(root:URL,binary:URL) throws {
        try Files.prepare(root)
        let target=root.appendingPathComponent("EasyClashRecovery")
        let changed=(try? Data(contentsOf:target)) != (try Data(contentsOf:binary))
        if changed {
            let bytes=try Data(contentsOf:binary);try Files.write(bytes,to:target)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:target.path)
        }
        let plist=Files.home.appendingPathComponent("Library/LaunchAgents/com.easyclash.recovery.plist")
        let spec:[String:Any]=["Label":"com.easyclash.recovery","ProgramArguments":[target.path,"watch","--state",root.path],"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":5,"ProcessType":"Background"]
        let data=try PropertyListSerialization.data(fromPropertyList:spec,format:.xml,options:0)
        try Files.write(data,to:plist)
        let label="gui/\(getuid())/com.easyclash.recovery"
        let loaded=(try Command.run("/bin/launchctl",["print",label])).code==0
        if changed && loaded {
            guard try Command.run("/bin/launchctl",["kickstart","-k",label]).code==0 else {throw AppFailure("恢复守护更新失败")}
        }
        if !loaded {
            guard try Command.run("/bin/launchctl",["bootstrap","gui/\(getuid())",plist.path]).code==0 else {throw AppFailure("恢复守护程序无法加载；尚未启用协同配置")}
        }
        guard try Command.run("/bin/launchctl",["print",label]).code==0 else {throw AppFailure("恢复守护程序不可用")}
    }
    public static func uninstall(root:URL) throws {
        let appLock=try FileLock(root.appendingPathComponent("app.lock"));defer{withExtendedLifetime(appLock){}}
        guard try restore(root:root,force:true) else {throw AppFailure("请先完成运行时恢复")}
        _ = try Command.run("/bin/launchctl",["bootout","gui/\(getuid())/com.easyclash.recovery"])
        for url in [Files.home.appendingPathComponent("Library/LaunchAgents/com.easyclash.recovery.plist"),root.appendingPathComponent("EasyClashRecovery")] where FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
        Audit(root:root).event("helper_uninstalled")
    }
}
