import Foundation

public enum Configuration {
    public static let vpnProxy="EasyClash VPN DIRECT"
    public static func overlay(_ base:[String:Any], settings:Settings, interface:String, vpnCIDRs:[String]=[]) throws -> [String:Any] {
        let settings=try settings.validated()
        guard interface.range(of:"^utun[0-9]+$",options:.regularExpression) != nil else { throw AppFailure("VPN 接口无效") }
        var b=base, dns=b["dns"] as? [String:Any] ?? [:]
        guard dns["enable"] as? Bool == true else { throw AppFailure("Clash DNS 未开启") }
        guard (dns["fake-ip-filter-mode"] as? String ?? "blacklist")=="blacklist" else { throw AppFailure("当前 fake-IP 使用非 blacklist 模式，需先在 Clash 中调整") }
        var p=dns["nameserver-policy"] as? [String:Any] ?? [:]
        var filter=dns["fake-ip-filter"] as? [String] ?? []
        var rules=b["rules"] as? [String] ?? []
        // Remove more-specific existing policies under managed suffixes to prevent public-DNS races.
        for key in p.keys {
            let plain=key.hasPrefix("+.") || key.hasPrefix("*.") ? String(key.dropFirst(2)) : key
            if settings.domains.contains(where: { plain == $0 || plain.hasSuffix("."+$0) }) { p.removeValue(forKey:key) }
        }
        let owned=settings.domains.map { "DOMAIN-SUFFIX,\($0),DIRECT" }
        var bound:[String]=[]
        if !vpnCIDRs.isEmpty {
            var proxies=b["proxies"] as? [[String:Any]] ?? []
            guard !proxies.contains(where:{$0["name"] as? String == vpnProxy}), !(b["proxy-groups"] as? [[String:Any]] ?? []).contains(where:{$0["name"] as? String == vpnProxy}) else {throw AppFailure("用户配置已有 EasyClash 保留出口名，未覆盖")}
            proxies.append(["name":vpnProxy,"type":"direct","interface-name":interface,"ip-version":"ipv4"]);b["proxies"]=proxies
            let ipRules=vpnCIDRs.map {"(IP-CIDR,"+$0+")"}.joined(separator:",")
            bound=settings.domains.map {"AND,((DOMAIN-SUFFIX,"+$0+"),(OR,("+ipRules+"))),"+vpnProxy}
        }
        rules=bound + owned + rules.filter { !owned.contains($0) }
        for d in settings.domains {
            p["+."+d]=["tcp://\(settings.dns):53#\(interface)"]
            for item in [d,"+."+d] where !filter.contains(item) { filter.append(item) }
        }
        dns["nameserver-policy"]=p; dns["fake-ip-filter"]=filter
        dns["direct-nameserver-follow-policy"]=true
        b["dns"]=dns; b["rules"]=rules
        return b
    }
}
