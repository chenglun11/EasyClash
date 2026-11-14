import Foundation
import Darwin

// A deliberately small projection of controller data. Never retain raw metadata, URLs,
// process paths, subscription/node configuration, headers or credentials.
public enum ObservationText {
    public static func host(_ text:String) -> String {
        let value=text.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
        guard value.count<=253, value.range(of:"^[a-z0-9_.-]+$",options:.regularExpression) != nil else {return ""}
        return value
    }
    public static func ip(_ value:String) -> String {
        var v4=in_addr(),v6=in6_addr()
        return inet_pton(AF_INET,value,&v4)==1 || inet_pton(AF_INET6,value,&v6)==1 ? value : ""
    }
    public static func company(_ host:String,domains:[String]) -> Bool {
        !host.isEmpty && domains.contains {host==$0.lowercased() || host.hasSuffix("."+$0.lowercased())}
    }
    public static func token(_ value:String) -> String {
        String(value.prefix(100)).filter {$0.isLetter || $0.isNumber || " ._()-".contains($0)}
    }
    public static func server(_ value:String) -> String {
        // Show only literal IP upstreams and their interface; redact DoH paths/query/auth.
        let parts=value.split(separator:"#",maxSplits:1).map(String.init)
        guard let address=parts.first,!address.isEmpty else {return "[未设置上游]"}
        let bare=ip(address)
        if !bare.isEmpty {return bare}
        guard let url=URLComponents(string:address.contains("://") ? address : "udp://"+address),
              url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,
              url.path.isEmpty,let host=url.host,!ip(host).isEmpty,
              ["tcp","udp","tls"].contains(url.scheme ?? "") else {return "[其他上游已隐藏]"}
        let suffix=parts.count==2 && parts[1].range(of:"^(utun|en|lo)[0-9]+$",options:.regularExpression) != nil ? "#"+parts[1] : ""
        return (url.scheme ?? "udp")+"://"+host+(url.port.map {":"+String($0)} ?? "")+suffix
    }
}
public enum TrafficPath:String,CaseIterable {
    case vpnBound="协同出口", vpnRoute="DIRECT · VPN 路由", direct="DIRECT", proxy="其他出口", unknown="待确认"
}
public struct TrafficRecord:Identifiable {
    public var id:String
    public var host:String
    public var destination:String
    public var process:String
    public var rule:String
    public var path:TrafficPath
    public var evidence:String
    public var company:Bool
    public var upload:Int64
    public var download:Int64
    public var seen:Date
    public var present=true
    public init?(raw:[String:Any],domains:[String],vpnInterface:String?,routeInterface:String?,vpnBindingVerified:Bool=false,now:Date=Date()) {
        guard let id=raw["id"] as? String,!id.isEmpty,id.count<100,let m=raw["metadata"] as? [String:Any] else {return nil}
        self.id=id;host=ObservationText.host(m["host"] as? String ?? "")
        destination=ObservationText.ip(m["destinationIP"] as? String ?? "")
        process=ObservationText.token((m["process"] as? String ?? "").components(separatedBy:"/").last ?? "")
        let type=raw["rule"] as? String ?? ""
        let allowed=["Domain","DomainSuffix","DomainKeyword","IPCIDR","IPCIDR6","GeoIP","RuleSet","Match","AND","OR","ProcessName","ProcessPath"]
        rule=allowed.contains(type) ? type : "其他规则"
        let payload=ObservationText.host(raw["rulePayload"] as? String ?? "")
        if ObservationText.company(payload,domains:domains) {rule += " · "+payload}
        let chains=raw["chains"] as? [String] ?? []
        company=ObservationText.company(host,domains:domains)
        if chains.first==Configuration.vpnProxy && vpnBindingVerified {
            path = .vpnBound;company=true
            evidence="Clash 连接记录命中 EasyClash VPN DIRECT，当前覆盖标记有效；API 未提供这条连接的实际绑定接口，不能认定旧连接已随 VPN 重连迁移，也不证明 HTTPS 成功。"
        } else if chains.first==Configuration.vpnProxy {
            path = .unknown;company=true;evidence="记录中有 VPN 出口名称，但本应用当前绑定未验证；不能仅凭名称确认公司网络。"
        } else if chains.first=="DIRECT" {
            if let routeInterface,let vpnInterface,routeInterface==vpnInterface,!destination.hasPrefix("198.18."),!destination.hasPrefix("198.19.") {
                path = .vpnRoute;company=true;evidence="Clash 记录 DIRECT；当前目标路由匹配 "+vpnInterface+"（路由快照，非抓包）。"
            } else {
                path = .direct;evidence=routeInterface.map {"Clash 记录 DIRECT；当前系统路由 "+$0+"，未确认进入公司 VPN。"} ?? "Clash 记录 DIRECT；目标路由未确认，不能认定为公司网络。"
            }
        } else if chains.isEmpty {path = .unknown;evidence="控制 API 未返回出口链。"}
        else {path = .proxy;evidence="Clash 记录代理或自定义出口；不根据目标系统路由推断其实际走向。"}
        upload=max(0,(raw["upload"] as? NSNumber)?.int64Value ?? 0)
        download=max(0,(raw["download"] as? NSNumber)?.int64Value ?? 0);seen=now
    }
}
public struct TrafficHistory {
    public private(set) var records:[TrafficRecord]=[]
    public let limit:Int
    public init(limit:Int=500) {self.limit=max(1,limit)}
    public mutating func update(_ sample:[TrafficRecord]) {
        let ids=Set(sample.map(\.id));var retained=records.filter {!ids.contains($0.id)}
        for i in retained.indices {retained[i].present=false}
        var unique:[TrafficRecord]=[];var seen=Set<String>()
        for row in sample where seen.insert(row.id).inserted {unique.append(row)}
        records=Array((unique+retained).sorted {$0.seen>$1.seen}.prefix(limit))
    }
    public mutating func clear() {records=[]}
    public var redactedReport:String {
        (["EasyClash 连接采样摘要（域名、IP、进程、规则内容和连接 ID 均已隐藏）"]+records.enumerated().map {i,r in
            "连接 \(i+1) | \(r.company ? "公司相关":"其他") | \(r.path.rawValue) | ↑\(r.upload) B ↓\(r.download) B | \(r.present ? "上次采样存在":"已不在采样中")"
        }).joined(separator:"\n")
    }
}
public struct ConfigLine:Identifiable {
    public let id=UUID()
    public var field:String
    public var value:String
    public init(_ field:String,_ value:String) {self.field=field;self.value=value}

    var safeScalar: Bool {
        ["dns.enable", "dns.enhanced-mode", "direct-nameserver-follow-policy"].contains(field) &&
            ["true", "false / 未设置", "fake-ip", "redir-host", "未设置 / 其他"].contains(value)
    }

    public var publicValue: String {
        if safeScalar { return value }
        if field.hasPrefix("规则 #") {
            let target = value.components(separatedBy:" → ").last ?? ""
            return ["DIRECT", "REJECT", Configuration.vpnProxy].contains(target) ? target : "其他出口"
        }
        if field == "公司 fake-IP 排除" && value == "未发现" { return value }
        return "明细已隐藏"
    }
}
public struct ConfigInspection {
    public var disk:[ConfigLine]=[]
    public var planned:[ConfigLine]=[]
    public var rules:[ConfigLine]=[]
    public var events:[ConfigLine]=[]
    public var status="尚未读取"
    public var error=""
    public var checked=Date()
    public init() {}
    public static func project(_ base:[String:Any],domains:[String]) -> [ConfigLine] {
        let dns=base["dns"] as? [String:Any] ?? [:]
        var result=[ConfigLine("dns.enable",dns["enable"] as? Bool == true ? "true":"false / 未设置"),ConfigLine("dns.enhanced-mode",["fake-ip","redir-host"].contains(dns["enhanced-mode"] as? String ?? "") ? dns["enhanced-mode"] as! String:"未设置 / 其他")]
        let policies=dns["nameserver-policy"] as? [String:Any] ?? [:]
        for k in policies.keys.sorted() {
            let plain=k.hasPrefix("+.") || k.hasPrefix("*.") ? String(k.dropFirst(2)) : k
            guard ObservationText.company(ObservationText.host(plain),domains:domains) else {continue}
            let values=(policies[k] as? [String]) ?? (policies[k] as? String).map {[$0]} ?? []
            result.append(ConfigLine("nameserver-policy · "+k,values.map(ObservationText.server).joined(separator:"\n")))
        }
        let filters=(dns["fake-ip-filter"] as? [String] ?? []).filter {value in
            let plain=value.hasPrefix("+.") || value.hasPrefix("*.") ? String(value.dropFirst(2)):value
            return ObservationText.company(ObservationText.host(plain),domains:domains)
        }
        result.append(ConfigLine("公司 fake-IP 排除",filters.isEmpty ? "未发现":filters.joined(separator:"\n")))
        result.append(ConfigLine("direct-nameserver-follow-policy",dns["direct-nameserver-follow-policy"] as? Bool == true ? "true":"false / 未设置"))
        return result
    }
    public static func ruleLines(_ raw:[[String:Any]],domains:[String]) -> [ConfigLine] {
        raw.enumerated().compactMap {i,r in
            let payload=r["payload"] as? String ?? "",type=r["type"] as? String ?? ""
            let domain=ObservationText.host(payload)
            let bound=r["proxy"] as? String == Configuration.vpnProxy
            guard ObservationText.company(domain,domains:domains) || bound else {return nil}
            let target=r["proxy"] as? String ?? ""
            let safeTarget=["DIRECT","REJECT",Configuration.vpnProxy].contains(target) ? target:"其他出口（名称隐藏）"
            return ConfigLine("规则 #\(i+1) · "+ObservationText.token(type),(bound ? "指向协同出口；匹配条件未验证":domain)+" → "+safeTarget)
        }
    }
    public var redactedReport:String {
        "EasyClash 配置摘要\n磁盘公司配置条目：\(disk.count)\n计划条目：\(planned.count)\n实际公司规则：\(rules.count)\n修改记录：\(events.count)\n"+status+"\n域名、DNS、路径、完整配置和规则内容均已隐藏。"
    }
}
// No calls to Coordinator.inspect/reload/Recovery.restore: both pages are strictly read-only.
public final class ObservationReader {
    private let settings:Settings
    private let root:URL
    private let api:ClashAPI
    public init(settings:Settings,root:URL=Files.state,explicitSocket:String?=nil) throws {
        self.settings=settings;self.root=root
        api=try ClashAPI(directory:URL(fileURLWithPath:settings.clashDirectory),client:settings.client,explicitSocket:explicitSocket)
    }
    private func netBird() -> NetBirdPlan? {
        guard settings.vpnBackend == .netBird, !settings.domains.isEmpty else { return nil }
        let plan=NetBirdPlan.discover(domains:settings.domains).1
        return plan?.servers.isEmpty==false ? plan : nil
    }
    private func vpn(_ general:[String:Any],netBird:NetBirdPlan?) -> String? {
        guard (try? settings.validated()) != nil else { return nil }
        let tun=(general["tun"] as? [String:Any])?["device"] as? String ?? ""
        if let n=netBird,n.device != tun {return n.device}
        guard settings.vpnBackend == .easyConnect else { return nil }
        guard let r=try? NetworkProbe.route(settings.dns),r.isVPN(dns:settings.dns,clashDevice:tun,easyConnectRunning:NetworkProbe.easyConnectRunning()) else {return nil}
        guard r.interface != NetBirdPlan.activeDevice() else {return nil}
        return r.interface
    }
    public func traffic() throws -> [TrafficRecord] {
        let general=try api.configs(),interface=vpn(general,netBird:netBird())
        let response=try api.request("/connections")
        let connections:[[String:Any]]
        if response["connections"] is NSNull {connections=[]}
        else if let rows=response["connections"] as? [[String:Any]] {connections=rows}
        else {throw AppFailure("连接 API 格式不兼容，保留上次记录")}
        var bindingVerified=false
        if connections.contains(where:{($0["chains"] as? [String])?.first==Configuration.vpnProxy}),
           let lease=try? Files.read(Lease.self,root.appendingPathComponent("lease.json")),
           lease.settings==settings,!lease.expired(ownerAlive:kill(lease.owner,0)==0),interface != nil {
            bindingVerified=(try? Recovery.markerPresent(lease.marker,api:api))==true
        }
        var routes:[String:String]=[:],budget=6
        return connections.prefix(1000).compactMap {raw in
            let metadata=raw["metadata"] as? [String:Any] ?? [:]
            let host=ObservationText.host(metadata["host"] as? String ?? "")
            let ip=ObservationText.ip(metadata["destinationIP"] as? String ?? "")
            let direct=(raw["chains"] as? [String])?.first=="DIRECT"
            if direct,!ip.isEmpty,routes[ip]==nil,budget>0,(interface != nil || ObservationText.company(host,domains:settings.domains)) {
                budget-=1;routes[ip]=(try? NetworkProbe.route(ip).interface) ?? ""
            }
            let route=routes[ip].flatMap {$0.isEmpty ? nil:$0}
            return TrafficRecord(raw:raw,domains:settings.domains,vpnInterface:interface,routeInterface:route,vpnBindingVerified:bindingVerified)
        }
    }
    public func configuration() -> ConfigInspection {
        var result=ConfigInspection()
        do {result.disk=ConfigInspection.project(try Files.yaml(settings.configURL),domains:settings.domains)}
        catch {result.error="磁盘配置不可读；未显示原始错误或配置正文。"}
        let nb=netBird()
        var interface:String?
        do {
            interface=vpn(try api.configs(),netBird:nb)
            guard let raw=try api.request("/rules")["rules"] as? [[String:Any]] else {throw AppFailure("规则 API 格式不兼容")}
            result.rules=ConfigInspection.ruleLines(raw,domains:settings.domains)
            let lease=try? Files.read(Lease.self,root.appendingPathComponent("lease.json"))
            let owned=lease.map {l in l.settings==settings && !l.expired(ownerAlive:kill(l.owner,0)==0) && raw.contains {$0["payload"] as? String==l.marker && $0["proxy"] as? String=="REJECT"}} ?? false
            result.status=owned ? "检测到本应用运行时标记；规则已从 API 读取。":"未检测到本应用运行时标记；下方计划尚不能视为已应用。"
        } catch {result.status="控制 API 不可用，无法确认实际生效规则。"}
        let target="tcp://"+ObservationText.ip(settings.dns)+":53#"+(interface ?? "<VPN 就绪后的接口>")
        if let nb {
            result.planned.append(ConfigLine("NetBird · 已分配资源","仅 "+String(nb.servers.count)+" 项使用隧道 DNS 和 "+nb.device+"；其他域名保留原规则"))
        } else if settings.vpnBackend == .netBird {
            result.planned.append(ConfigLine("NetBird", "等待已分配的资源和专用 DNS"))
        } else {for d in settings.domains {
            result.planned.append(ConfigLine("nameserver-policy · +."+d,target))
            result.planned.append(ConfigLine("fake-IP / 分流 · "+d,"排除 fake-IP；公司网段优先绑定 VPN；其他地址 DIRECT"))
        }
        }
        result.planned.append(ConfigLine("生命周期","VPN 就绪后应用；关闭或断线撤销运行时覆盖，读取最新磁盘配置。"))
        result.events=Self.events(root:root)
        return result
    }
    public static func events(root:URL) -> [ConfigLine] {
        let labels = [
            "settings_saved": "已保存协同设置", "mode_enabled": "开启协同模式", "mode_disabled": "关闭协同模式",
            "netbird_overlay_verified": "NetBird 资源规则和 DNS 通过检查",
            "runtime_overlay_verified": "运行时覆盖通过检查", "runtime_restored": "撤销运行时覆盖",
            "flclash_controller_prepared": "准备 FlClash 控制接口", "flclash_controller_preparation_undone": "撤销控制接口准备",
            "recovery_retry": "恢复守护正在重试", "helper_uninstalled": "移除恢复守护"
        ]
        var rows:[ConfigLine]=[]
        if let data=try? Data(contentsOf:root.appendingPathComponent("events.jsonl")),data.count<512_000,let text=String(data:data,encoding:.utf8) {
            for line in text.split(separator:"\n").suffix(40).reversed() {
                guard let raw=try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any],let label=labels[raw["event"] as? String ?? ""] else {continue}
                let time=raw["time"] as? String ?? ""
                rows.append(ConfigLine(ISO8601DateFormatter().date(from:time).map {ISO8601DateFormatter().string(from:$0)} ?? "时间未知",label))
            }
        }
        return rows
    }
}
