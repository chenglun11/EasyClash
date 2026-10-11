import Foundation

public enum ProxyClient:String,Codable,CaseIterable,Identifiable {
    case verge, flclash
    public var id:String {rawValue}
    public var name:String {self == .verge ? "Clash Verge Rev" : "FlClash"}
    public var directory:URL {self == .verge ? Files.clash : Files.home.appendingPathComponent("Library/Application Support/com.follow.clash")}
    public var configName:String {self == .verge ? "clash-verge.yaml" : "config.yaml"}
}

public enum ClientIdentity {
    public static func loopbackPort(_ address:String) throws -> (String,Int) {
        guard let u=URL(string:"http://"+address),["127.0.0.1","localhost","[::1]","::1"].contains(u.host ?? ""), let port=u.port,(1...65535).contains(port),u.user==nil,u.password==nil,u.path.isEmpty,u.query==nil,u.fragment==nil else {throw AppFailure("FlClash 控制接口必须绑定回环地址")}
        return ((u.host ?? "").contains(":") ? "[::1]" : "127.0.0.1",port)
    }
    public static func listeningPIDs(_ table:String,port:Int) -> Set<Int32> {
        var result=Set<Int32>()
        for line in table.split(separator:"\n") {
            let f=line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            guard f.count>5,f[0].hasPrefix("tcp"),f[3].hasSuffix(".\(port)"),f[5]=="LISTEN" else {continue}
            // macOS netstat exposes the process:pid even for a root-owned core.
            for item in f.dropFirst(6) where item.contains(":") {
                if let pid=Int32(item.split(separator:":").last ?? ""),pid>0 {result.insert(pid)}
            }
        }
        return result
    }
    public static func flClashOwner(port:Int) throws -> Int32 {
        let table=try Command.run("/usr/sbin/netstat",["-anv","-p","tcp"],timeout:3)
        let pids=listeningPIDs(table.out,port:port)
        guard table.code==0,pids.count==1,let pid=pids.first else {throw AppFailure("FlClash 控制接口未就绪或端口归属不明确；不会连接其他客户端")}
        let process=try Command.run("/bin/ps",["-p",String(pid),"-o","comm="],timeout:3)
        guard process.code==0,process.out.trimmingCharacters(in:.whitespacesAndNewlines).hasSuffix("/FlClash.app/Contents/MacOS/FlClashCore") else {throw AppFailure("控制端口不属于 FlClash；未修改任何客户端")}
        return pid
    }
}
