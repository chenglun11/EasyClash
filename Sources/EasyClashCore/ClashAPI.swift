import Foundation
import Darwin

public final class ClashAPI {
    public let socket: String
    private let baseURL:String
    private let secret:String
    private let httpPort:Int?
    private let owner:Int32?
    public init(directory: URL, client:ProxyClient = .verge, explicitSocket:String? = nil) throws {
        if let explicitSocket {socket=explicitSocket;baseURL="http://localhost";secret="";httpPort=nil;owner=nil;return}
        if client == .flclash {
            let config=try Files.yaml(directory.appendingPathComponent(client.configName))
            let address=config["external-controller"] as? String ?? ""
            guard !address.isEmpty else {throw AppFailure("FlClash 尚未加载本地控制接口；已准备支持时，请正常启动 FlClash")}
            let (host,port)=try ClientIdentity.loopbackPort(address)
            owner=try ClientIdentity.flClashOwner(port:port);httpPort=port
            socket="";baseURL="http://\(host):\(port)";secret=config["secret"] as? String ?? ""
            guard !secret.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else {throw AppFailure("控制接口密钥格式无效")}
        } else {
            var candidates = ["/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock"]
            if let c=try? Files.yaml(directory.appendingPathComponent("config.yaml")), let s=c["external-controller-unix"] as? String,!s.isEmpty {candidates.append(s)}
            guard let s=candidates.first(where:{FileManager.default.fileExists(atPath:$0)}) else {throw AppFailure("未找到 Clash Verge 控制 socket，请启动所选客户端")}
            socket=s;baseURL="http://localhost";secret="";httpPort=nil;owner=nil
        }
    }
    private static func quoted(_ value:String) -> String {
        "\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r")+"\""
    }
    @discardableResult public func request(_ endpoint:String, method:String="GET", body:[String:Any]?=nil) throws -> [String:Any] {
        if method != "GET",let port=httpPort {guard try ClientIdentity.flClashOwner(port:port)==owner else {throw AppFailure("FlClash 控制进程变化，本次修改已取消")}}
        var input=try body.map {try JSONSerialization.data(withJSONObject:$0,options:[.sortedKeys])}
        var args=["--silent","--show-error","--noproxy","*","--max-time","12","-X",method,"-w","\n%{http_code}",baseURL+endpoint]
        if !socket.isEmpty {args += ["--unix-socket",socket]}
        if httpPort != nil {
            // Credentials and full config travel over stdin, never process arguments or logs.
            var lines:[String]=[]
            if !secret.isEmpty {lines.append("header = "+Self.quoted("Authorization: Bearer "+secret))}
            if let data=input {lines.append("header = "+Self.quoted("Content-Type: application/json"));lines.append("data-binary = "+Self.quoted(String(data:data,encoding:.utf8)!))}
            args += ["--config","-"];input=Data((lines.joined(separator:"\n")+"\n").utf8)
        } else if input != nil {args += ["-H","Content-Type: application/json","--data-binary","@-"]}
        let r=try Command.run("/usr/bin/curl",args,input:input,timeout:14)
        guard let split=r.out.lastIndex(of:"\n"), let status=Int(r.out[r.out.index(after:split)...]), r.code==0, (200..<300).contains(status) else { throw AppFailure("Clash API \(method) 请求失败（curl \(r.code)，未输出响应内容）") }
        let data=Data(r.out[..<split].utf8)
        if data.isEmpty { return [:] }
        guard let result=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw AppFailure("Clash API 响应格式异常") }
        return result
    }
    public func configs() throws -> [String:Any] { try request("/configs") }
    public func hasRules(_ domains:[String]) throws -> Bool {
        let rules=try request("/rules")["rules"] as? [[String:Any]] ?? []
        // Require the leading rules, so a subscription's earlier MATCH cannot shadow them.
        let offset=rules.first?["proxy"] as? String == Configuration.vpnProxy ? domains.count : 0
        if offset>0 && !domains.enumerated().allSatisfy({ i,d in i<rules.count && rules[i]["proxy"] as? String == Configuration.vpnProxy && (rules[i]["payload"] as? String ?? "").contains(d) }) {return false}
        return domains.enumerated().allSatisfy { i,d in let n=i+offset;return n < rules.count && (rules[n]["type"] as? String)=="DomainSuffix" && (rules[n]["payload"] as? String)==d && (rules[n]["proxy"] as? String)=="DIRECT" }
    }
    public func dns(_ name:String) throws -> [String] {
        let r=try request("/dns/query?name=\(name)&type=A")
        guard r["Status"] as? Int == 0 else {throw AppFailure("Clash DNS 返回错误状态")}
        return (r["Answer"] as? [[String:Any]] ?? []).filter { ($0["type"] as? Int)==1 }.compactMap { $0["data"] as? String }
    }
    public func reload(_ base:[String:Any], requireTun:Bool=true) throws {
        let before=try configs()
        let tun=before["tun"] as? [String:Any] ?? [:]
        if requireTun && tun["enable"] as? Bool != true { throw AppFailure("TUN 未开启；应用不会代为切换 TUN") }
        var payload=base
        // GET /configs contains parsed/defaulted TUN values. Pass it verbatim to avoid ReCreateTun.
        // Also preserve the user's live basic settings, including mode and ports.
        for (k,v) in before { payload[k]=v }
        let selectors=(try? request("/proxies")["proxies"] as? [String:[String:Any]]) ?? [:]
        guard JSONSerialization.isValidJSONObject(payload) else {throw AppFailure("配置包含不支持的值类型")}
        let payloadText=String(data:try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys,.withoutEscapingSlashes]),encoding:.utf8)!
        try request("/configs?force=false",method:"PUT",body:["payload":payloadText])
        let after=try configs()
        guard NSDictionary(dictionary:tun).isEqual(to:after["tun"] as? [String:Any] ?? [:]) else { throw AppFailure("热加载后 TUN 参数不一致，已停止进一步操作") }
        // Restore selector choices only where the selected member is still present after a subscription update.
        let newSelectors=(try? request("/proxies")["proxies"] as? [String:[String:Any]]) ?? [:]
        for (name,old) in selectors where old["type"] as? String == "Selector" {
            if let choice=old["now"] as? String, let now=newSelectors[name], (now["all"] as? [String] ?? []).contains(choice), now["now"] as? String != choice,
               let escaped=name.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed.subtracting(CharacterSet(charactersIn:"/"))) {
                try request("/proxies/"+escaped,method:"PUT",body:["name":choice])
            }
        }
        // Dedicated cache API, never toggle TUN. Do not flush the fake-IP pool: existing connections may still use it.
        _ = try? request("/cache/dns/flush",method:"POST")
    }
}
