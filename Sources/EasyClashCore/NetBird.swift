import Foundation
import Darwin

/// One brief data-path outage must not replace a previously verified live policy.
public struct NetBirdProbeGrace {
    private var since:TimeInterval?
    private var key:String?
    public init() {}
    public mutating func reset() { since=nil;key=nil }
    public mutating func retain(fingerprint:String,installed:String,markerPresent:Bool,now:TimeInterval) -> Bool {
        guard markerPresent, fingerprint==installed else {reset();return false}
        if key != fingerprint {key=fingerprint;since=now}
        let elapsed=now-(since ?? now)
        return elapsed>=0 && elapsed<30
    }
}

public enum NetBirdConnection {
    static var executable: String? {
        ["/Applications/NetBird.app/Contents/MacOS/netbird", "/opt/homebrew/bin/netbird", "/usr/local/bin/netbird"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
    }

    public static var installationPath: String? {
        executable.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    // The CLI talks to the installed system service. Its normal SSO flow opens the browser.
    public static func connect(managementURL: String = "") throws {
        guard let executable else { throw AppFailure("请先安装镜像里的官方 NetBird 安装包") }
        try connect(managementURL: managementURL) { arguments, seconds in
            let result = try Command.run(executable, arguments, timeout: seconds)
            return (result.code, result.out)
        }
    }

    public static func validateManagementURL(_ value: String) throws {
        guard !value.isEmpty else { return }
        guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/"
        else { throw AppFailure("管理服务地址应为 HTTPS 站点，可含端口") }
    }

    package static func connect(managementURL: String, run: ([String], Double) throws -> (Int32, String)) throws {
        try validateManagementURL(managementURL)
        func status() throws -> [String: Any] {
            let (code, output) = try run(["status", "--json"], 5)
            guard code == 0, let value = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
                  value["daemonStatus"] is String else {
                throw AppFailure("无法读取 NetBird 后台服务，请检查官方安装包是否已安装")
            }
            return value
        }
        func connected(_ value: [String: Any]) -> Bool {
            value["daemonStatus"] as? String == "Connected" && !(value["netbirdIp"] as? String ?? "").isEmpty
        }
        let current = try status()
        if connected(current) {
            if !managementURL.isEmpty {
                let currentURL = (current["management"] as? [String: Any])?["url"] as? String
                guard let active = currentURL.flatMap(URLComponents.init(string:)),
                      let desired = URLComponents(string: managementURL),
                      active.host?.lowercased() == desired.host?.lowercased(),
                      (active.port ?? 443) == (desired.port ?? 443) else {
                    throw AppFailure("当前会话连接的是其他管理服务。请先确认所选 NetBird 配置")
                }
            }
            return
        }
        var args = ["up"]
        if !managementURL.isEmpty { args += ["--management-url", managementURL] }
        guard try run(args, 120).0 == 0 else {
            throw AppFailure("NetBird 连接未完成。请核对管理服务地址并完成浏览器授权，然后重试")
        }
        for attempt in 0..<5 {
            if connected(try status()) { return }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.4) }
        }
        throw AppFailure("NetBird 尚未建立隧道，请查看诊断或再次连接")
    }
}

/// Match network resources to the resolver owned by the live VPN interface.
public struct NetBirdPlan {
    public var device: String
    public var localIP: String
    public var servers: [String:String] // exact domain or *.domain
    public init(device:String,localIP:String,servers:[String:String]) {self.device=device;self.localIP=localIP;self.servers=servers}
    public static func assigned(_ listing:String) -> Set<String> {
        var domains=[String](), result=Set<String>()
        for raw in listing.components(separatedBy:.newlines) {
            let line=raw.trimmingCharacters(in:.whitespacesAndNewlines)
            if line.hasPrefix("- ID:") { domains=[] }
            if line.hasPrefix("Domains:") {domains=line.dropFirst(8).lowercased().split(whereSeparator:{ $0=="," || $0.isWhitespace }).map(String.init)}
            if line=="Status: Selected" {result.formUnion(domains)}
        }
        return result
    }
    public static func scoped(_ listing:String, selected:Set<String>, domains:[String], ownsDNS:(String)->Bool) -> [String:String] {
        var result=[String:String]()
        for section in listing.components(separatedBy:"resolver #").dropFirst() {
            var name="",servers=[String](),port="53"
            for line in section.split(separator:"\n") {
                let p=line.split(separator:":",maxSplits:1).map{$0.trimmingCharacters(in:.whitespaces)}
                guard p.count==2 else {continue}
                if p[0]=="domain" {name=p[1].lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))}
                if p[0].hasPrefix("nameserver[") {servers.append(p[1])}
                if p[0]=="port" {port=p[1]}
            }
            guard port=="53",servers.count==1,name.range(of:"^[a-z0-9-]+(?:\\.[a-z0-9-]+)+$",options:.regularExpression) != nil,
                domains.contains(where:{name==$0 || name.hasSuffix("."+$0)}),
                selected.contains(name) || selected.contains("*."+name), ownsDNS(servers[0]) else {continue}
            if selected.contains(name) { result[name] = servers[0] }
            if selected.contains("*."+name) { result["*."+name] = servers[0] }
        }
        return result
    }
    public static func recentPeerLoss(_ status:[String:Any],now:Date=Date()) -> String? {
        let fmt=ISO8601DateFormatter();fmt.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let events=status["events"] as? [[String:Any]] ?? []
        let latest=events.filter{$0["message"] as? String=="No routing peer available"}
            .compactMap{($0["timestamp"] as? String).flatMap{fmt.date(from:$0) ?? ISO8601DateFormatter().date(from:$0)}}.max()
        guard let latest,(0..<900).contains(now.timeIntervalSince(latest)) else {return nil}
        let minutes=Int(now.timeIntervalSince(latest)/60)
        return (minutes==0 ? "刚才" : "约"+String(minutes)+"分钟前")+"有资源无可用路由节点"
    }
    public static func discover(domains:[String]) -> (String,NetBirdPlan?) {
        guard let cli=NetBirdConnection.executable else {return ("未安装 CLI",nil)}
        guard let raw=try? Command.run(cli,["status","--json"],timeout:4),raw.code==0,
              let j=(try? JSONSerialization.jsonObject(with:Data(raw.out.utf8))) as? [String:Any] else {return ("状态不可读",nil)}
        let managed=(j["management"] as? [String:Any])?["connected"] as? Bool==true
        guard (managed || j["daemonStatus"] as? String=="Connected"),
              let ip=(j["netbirdIp"] as? String)?.split(separator:"/").first.map(String.init) else {return ("未连接",nil)}
        var list:UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list)==0,let first=list else {return ("已连接 · 接口未知",nil)}
        defer {freeifaddrs(first)}
        var device:String?
        for p in sequence(first:first,next:{$0.pointee.ifa_next}) {
            guard let addr=p.pointee.ifa_addr,addr.pointee.sa_family==AF_INET else {continue}
            var buf=[CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(addr,socklen_t(addr.pointee.sa_len),&buf,socklen_t(buf.count),nil,0,NI_NUMERICHOST)==0,String(cString:buf)==ip {device=String(cString:p.pointee.ifa_name);break}
        }
        guard let device,device.range(of:"^utun[0-9]+$",options:.regularExpression) != nil else {return ("已连接 · 隧道接口未就绪",nil)}
        let resources=try? Command.run(cli,["networks","list"],timeout:4)
        let resolvers=try? Command.run("/usr/sbin/scutil",["--dns"],timeout:3)
        var checked=[String:Bool]()
        let eligible=scoped(resolvers?.out ?? "",selected:assigned(resources?.out ?? ""),domains:domains) { server in
            if let seen=checked[server] {return seen}
            var address=in_addr()
            let valid=inet_pton(AF_INET,server,&address)==1 && (try? NetworkProbe.route(server).interface)==device
            checked[server]=valid;return valid
        }
        let status=[managed ? "已连接" : "管理连接中断", "\(eligible.count) 项公司资源", recentPeerLoss(j)].compactMap{$0}.joined(separator:" · ")
        return (status,NetBirdPlan(device:device,localIP:ip,servers:eligible))
    }
    public func resolver(for host: String) -> String? {
        if let server = servers[host] { return server }
        let wildcard = servers.keys.filter {
            $0.hasPrefix("*.") && host.hasSuffix(String($0.dropFirst())) &&
                !host.dropLast($0.count - 1).contains(".")
        }.max { $0.count < $1.count }
        return wildcard.flatMap { servers[$0] }
    }

    public func overlay(_ base:[String:Any],marker:String) throws -> [String:Any] {
        var b=base
        guard !servers.isEmpty,var dns=b["dns"] as? [String:Any],dns["enable"] as? Bool==true,(dns["fake-ip-filter-mode"] as? String ?? "blacklist")=="blacklist" else {throw AppFailure("NetBird 资源或 Clash DNS 模式不可用")}
        var policies=dns["nameserver-policy"] as? [String:Any] ?? [:], filters=dns["fake-ip-filter"] as? [String] ?? []
        var proxies=b["proxies"] as? [[String:Any]] ?? []
        guard !(proxies+(b["proxy-groups"] as? [[String:Any]] ?? [])).contains(where:{$0["name"] as? String==Configuration.vpnProxy}) else {throw AppFailure("VPN 出口名称已被占用")}
        proxies.append(["name":Configuration.vpnProxy,"type":"direct","interface-name":device,"ip-version":"ipv4"])
        var rules=["DOMAIN,"+marker+",REJECT"]
        for name in servers.keys.sorted(by:{$0.hasPrefix("*.") != $1.hasPrefix("*.") ? !$0.hasPrefix("*.") : $0.count != $1.count ? $0.count > $1.count : $0 < $1}) {
            let wildcard=name.hasPrefix("*.")
            // Use a subdomain wildcard (not +.) so a wildcard grant does not claim the apex.
            policies[name]=["tcp://"+servers[name]!+":53#"+device]
            if !filters.contains(name) {filters.append(name)}
            rules.append((wildcard ? "DOMAIN-WILDCARD," : "DOMAIN,")+name+","+Configuration.vpnProxy)
        }
        dns["fake-ip-filter"]=filters;dns["nameserver-policy"]=policies;dns["direct-nameserver-follow-policy"]=true
        b["dns"]=dns;b["rules"]=rules+(base["rules"] as? [String] ?? []);b["proxies"]=proxies
        return b
    }
}
