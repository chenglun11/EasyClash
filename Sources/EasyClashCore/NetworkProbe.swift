import Foundation

public struct RouteInfo: Equatable, Codable {
    public var destination:String
    public var gateway:String
    public var interface:String
    public static func parse(_ text:String) -> RouteInfo {
        var fields:[String:String]=[:]
        for line in text.split(separator:"\n") {
            let pair=line.split(separator:":",maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces) }
            if pair.count==2 { fields[pair[0]]=pair[1] }
        }
        return RouteInfo(destination:fields["destination"] ?? "",gateway:fields["gateway"] ?? "",interface:fields["interface"] ?? "")
    }
    public func isVPN(dns:String,clashDevice:String,easyConnectRunning:Bool) -> Bool {
        easyConnectRunning && destination==dns && interface.range(of:"^utun[0-9]+$",options:.regularExpression) != nil && interface != clashDevice && !gateway.hasPrefix("198.18.") && !gateway.hasPrefix("198.19.") && gateway != "" && gateway != "default"
    }
}
public struct HostDiagnostic: Codable {
    public var host:String
    public var dns:String
    public var route:String
    public var https:String
    public var reachable:Bool
}
public enum NetworkProbe {
    public static func route(_ ip:String) throws -> RouteInfo {
        guard ip.range(of:"^[0-9a-fA-F:.]+$",options:.regularExpression) != nil else { throw AppFailure("路由目标不是 IP") }
        let r=try Command.run("/sbin/route",["-n","get",ip],timeout:3)
        guard r.code==0 else { throw AppFailure("系统路由不可用") }
        return RouteInfo.parse(r.out)
    }
    public static func vpnCIDRs(interface:String) throws -> [String] {
        let result=try Command.run("/usr/sbin/netstat",["-rn","-f","inet"],timeout:3)
        guard result.code==0 else {throw AppFailure("无法读取 VPN 路由表")}
        return parseCIDRs(result.out,interface:interface)
    }
    public static func parseCIDRs(_ text:String,interface:String) -> [String] {
        var result=Set<String>()
        for line in text.split(separator:"\n") {
            let fields=line.split(whereSeparator:{$0.isWhitespace}).map(String.init)
            guard fields.count>=4,fields[3]==interface,fields[2].contains("U"),fields[2].contains("G") else {continue}
            let parts=fields[0].split(separator:"/"),octets=parts[0].split(separator:".").compactMap {Int($0)}
            guard !octets.isEmpty,octets.count<=4,octets.allSatisfy({(0...255).contains($0)}) else {continue}
            let bits=parts.count==2 ? Int(parts[1]) ?? 0 : octets.count*8
            // Do not claim a VPN default/half-default route or multicast network.
            guard (8...32).contains(bits),octets[0]>0,octets[0]<224 else {continue}
            let address=(octets+Array(repeating:0,count:4-octets.count)).map(String.init).joined(separator:".")
            result.insert(address+"/"+String(bits))
        }
        return result.sorted()
    }
    public static func easyConnectRunning() -> Bool {
        let r=try? Command.run("/bin/ps",["-axo","comm="],timeout:3)
        return r?.out.split(separator:"\n").contains { $0.contains("/EasyConnect.app/Contents/MacOS/EasyConnect") || $0.hasSuffix("/svpnservice") } ?? false
    }
    public static func proxyConflict() -> Bool {
        let r=try? Command.run("/usr/sbin/scutil",["--proxy"],timeout:3)
        return r?.out.range(of:"(?:HTTPEnable|HTTPSEnable|SOCKSEnable|ProxyAutoConfigEnable) : 1",options:.regularExpression) != nil
    }
    public static func query(_ name:String,server:String) throws -> [String] {
        // Settings/host validation is done by callers. No fallback server, no UDP race.
        let r=try Command.run("/usr/bin/dig",["+tcp","+time=2","+tries=1","@"+server,name,"A","+noall","+answer","+comments"],timeout:4)
        guard r.code==0, r.out.contains("status: NOERROR") else { throw AppFailure("公司 DNS 超时、拒绝或返回错误") }
        let answers: [String] = r.out.split(separator:"\n").compactMap { line in
            let p=line.split(whereSeparator:{$0.isWhitespace})
            guard p.count>=5,p[p.count-2]=="A" else {return nil}
            let ip=String(p.last!); return ip.hasPrefix("198.18.") || ip.hasPrefix("198.19.") ? nil : ip
        }
        guard !answers.isEmpty else {throw AppFailure("公司 DNS 未返回可用 A 记录")}
        return answers
    }
    public static func https(host:String,ip:String,path:String="/") throws -> (Int,Bool) {
        let r=try Command.run("/usr/bin/curl",["--silent","--show-error","--noproxy","*","--connect-timeout","3","--max-time","6","--resolve","\(host):443:\(ip)","-o","/dev/null","-w","%{http_code}","https://"+host+path],timeout:8)
        let status=Int(r.out) ?? 0
        return (status,r.code==0 && status>=100 && status<600)
    }
    public static func proxyHTTPS(host:String,port:Int,path:String="/") throws -> (Int,Bool) {
        guard (1...65535).contains(port) else {throw AppFailure("Clash 本地代理端口不可用")}
        let r=try Command.run("/usr/bin/curl",["--silent","--show-error","--noproxy","","--proxy","http://127.0.0.1:\(port)","--connect-timeout","3","--max-time","6","-o","/dev/null","-w","%{http_code}","https://"+host+path],timeout:8)
        let status=Int(r.out) ?? 0
        return (status,r.code==0 && status>=100 && status<600)
    }
    public static func diagnostic(host:String,settings:Settings,vpn:RouteInfo?,proxyPort:Int?=nil) -> HostDiagnostic {
        guard let vpn else {return HostDiagnostic(host:host,dns:"未发送：VPN 路由未就绪",route:"不可用",https:"未测试",reachable:false)}
        do {
            guard try route(settings.dns)==vpn else { throw AppFailure("VPN 路由变化") }
            let ips=try query(host,server:settings.dns)
            guard let ip=ips.first else {return HostDiagnostic(host:host,dns:"无 A 记录（可能为 NXDOMAIN）",route:"未测试",https:"未测试",reachable:false)}
            guard try route(settings.dns)==vpn else {throw AppFailure("VPN 路由变化")}
            let destination=try route(ip)
            let path="/"
            let (status,success)=try proxyPort.map {try proxyHTTPS(host:host,port:$0,path:path)} ?? https(host:host,ip:ip,path:path)
            return HostDiagnostic(host:host,dns:"成功 · \(ips.count) 个真实地址",route:destination.interface==vpn.interface ? "EasyConnect · \(destination.interface)" : "系统路由 · \(destination.interface)",https:success ? "\(proxyPort == nil ? "系统直连" : "经 Clash") · TLS 正常 · HTTP \(status)" : "\(proxyPort == nil ? "系统直连" : "经 Clash") · 连接或 TLS 验证失败",reachable:success)
        } catch {return HostDiagnostic(host:host,dns:"DNS / 路由检查失败",route:"请重新检测",https:"未测试",reachable:false)}
    }
}
