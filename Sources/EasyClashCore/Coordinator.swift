import Foundation

public struct Snapshot: Codable {
    public var client="Clash Verge Rev"
    public var mode="已关闭"
    public var clash="检测中"
    public var tun="检测中"
    public var netBird="未检测"
    public var easyConnect="检测中"
    public var vpn="检测中"
    public var dns="未测试"
    public var warning=""
    public var active=false
    public var enabled=false
    public var checked=Date()
    public var hosts:[HostDiagnostic]=[]
    public init() {}
    public var report:String {
        var rows=["EasyClash 脱敏诊断", "检测时间：\(ISO8601DateFormatter().string(from:checked))", "客户端：\(client)","协同模式：\(mode)","Clash：\(clash)","TUN：\(tun)","EasyConnect：\(easyConnect)","NetBird：\(netBird)","VPN 路由：\(vpn)","公司 DNS：\(dns)"]
        if !warning.isEmpty {rows.append("提示："+warning)}
        for (index,h) in hosts.enumerated() { rows.append("目标 \(index+1) | DNS \(h.dns) | 路由 \(h.route) | HTTPS \(h.https)") }
        rows.append("不包含域名、订阅、密钥、VPN 凭据、IP 地址或完整配置。")
        return rows.joined(separator:"\n")
    }
}
// All methods run on one serial queue. The UI never performs networking on the main thread.
public final class Coordinator {
    public let root:URL
    public var settings:Settings
    public private(set) var enabled=false
    private var lease:Lease?
    private var fingerprint=""
    private var lastProbe=Date.distantPast
    private var grace = NetBirdProbeGrace()
    private var pendingProbe = false
    private var lastDNS="未测试"
    private var lastHosts:[HostDiagnostic]=[]
    private let explicitSocket:String?
    public init(root:URL=Files.state,settings:Settings?=nil,explicitSocket:String?=nil) {
        self.root=root;self.settings=settings ?? (try? Files.read(Settings.self,root.appendingPathComponent("settings.json"))) ?? Settings();self.explicitSocket=explicitSocket
    }
    public func save(_ value:Settings) throws {
        guard !enabled else {throw AppFailure("请先关闭协同模式，再修改设置")}
        let valid=try value.validated();if valid.client == .flclash {try FlClashSetup.prepare(root:root)};try Files.json(valid,to:root.appendingPathComponent("settings.json"));settings=valid;Audit(root:root).event("settings_saved")
    }
    public func enable(helper:URL?,appPath:String?=nil) throws {
        settings=try settings.validated()
        if settings.client == .flclash && explicitSocket==nil {try FlClashSetup.prepare(root:root)}
        // Resolve any prior crashed session before acquiring a new lease.
        _ = try Recovery.restore(root:root,force:true,explicitSocket:explicitSocket)
        if let helper {try Recovery.installHelper(root:root,binary:helper)}
        else if explicitSocket==nil {throw AppFailure("缺少恢复程序，请从完整 .app 启动")}
        lease=Lease(settings:settings,appPath:appPath)
        grace.reset(); pendingProbe=false; lastProbe = .distantPast
        enabled=true;fingerprint="";Audit(root:root).event("mode_enabled")
    }
    public func disable() throws {
        enabled=false
        _ = try Recovery.restore(root:root,force:true,explicitSocket:explicitSocket)
        lease=nil;fingerprint="";Audit(root:root).event("mode_disabled")
    }
    public func inspect(diagnostics:Bool=false) -> Snapshot {
        var s=Snapshot();s.client=settings.client.name;s.enabled=enabled;s.hosts=lastHosts
        if enabled, let path=lease?.appPath, !FileManager.default.fileExists(atPath:path) {
            enabled=false;s.enabled=false;s.mode="应用已移除 · 协同已关闭"
            do {_ = try Recovery.restore(root:root,force:true,explicitSocket:explicitSocket);lease=nil;fingerprint=""}
            catch {s.warning="应用已移除，恢复守护将继续撤销覆盖"}
            return s
        }
        guard (try? settings.validated()) != nil else {
            s.mode="待配置";s.warning="请先在设置中选择 VPN 并填写公司网络信息。"
            s.clash="未检测";s.tun="未检测";s.easyConnect="未检测";s.vpn="未检测";s.hosts=[]
            return s
        }
        let dir=URL(fileURLWithPath:settings.clashDirectory)
        let process=NetworkProbe.easyConnectRunning();s.easyConnect=process ? "进程存在" : "未运行"
        if NetworkProbe.proxyConflict() {s.warning="系统代理或 PAC 仍开启，可能与 TUN 冲突；请在 Clash 中检查。"}
        do {
            let api=try ClashAPI(directory:dir,client:settings.client,explicitSocket:explicitSocket)
            let version=try api.request("/version")["version"] as? String ?? "未知版本"
            let general=try api.configs();s.clash="运行中 · "+version
            let tun=general["tun"] as? [String:Any] ?? [:]
            let on=tun["enable"] as? Bool == true, device=tun["device"] as? String ?? ""
            s.tun=on ? "已开启 · "+device : "未开启"
            if settings.vpnBackend == .netBird {
                let (status, plan) = NetBirdPlan.discover(domains: settings.domains)
                s.netBird = status
                s.vpn = plan.map { "NetBird · " + $0.device } ?? "隧道未就绪"
                guard let plan, !plan.servers.isEmpty, on, plan.device != device,
                      general["mode"] as? String == "rule" else {
                    if enabled {
                        try Recovery.restore(root: root, force: true, explicitSocket: explicitSocket)
                        fingerprint = ""
                        s.mode = "等待 NetBird 资源、TUN 或规则模式"
                    }
                    grace.reset()
                    pendingProbe = false
                    lastHosts = []
                    s.hosts = []
                    return s
                }
                guard enabled else { return s }
                return try inspectNetBird(plan, api: api, general: general, snapshot: s, diagnostics: diagnostics)
            }
            let route=try? NetworkProbe.route(settings.dns)
            let ready=route?.isVPN(dns:settings.dns,clashDevice:device,easyConnectRunning:process)==true
            s.vpn=ready ? "可用 · "+route!.interface : "不可用（进程存在不代表 VPN 已连接）"
            let source=settings.configURL
            let sourceBytes=try Data(contentsOf:source)

            if diagnostics || Date().timeIntervalSince(lastProbe)>20 {
                lastProbe=Date()
                if ready, let r=route {
                    do {
                        let name=settings.effectiveProbeHost
                        let answers=try NetworkProbe.query(name,server:settings.dns)
                        guard try NetworkProbe.route(settings.dns)==r else {throw AppFailure("路由已变化")}
                        for ip in answers {guard try NetworkProbe.route(ip).interface==r.interface else {throw AppFailure("公司目标路由未经过 VPN")}}
                        lastDNS=answers.isEmpty ? "已响应，探测域名无 A 记录" : "响应正常（仅公司上游）"
                    } catch {lastDNS="公司 DNS 或目标路由检查失败；未回退公共 DNS"}
                } else {lastDNS="VPN 未就绪，使用原有解析"}
            }
            if !ready {lastDNS="VPN 未就绪，使用原有解析"}
            s.dns=lastDNS
            if enabled {
                if !on || !ready || (general["mode"] as? String != "rule") {
                    _ = try Recovery.restore(root:root,force:true,explicitSocket:explicitSocket)
                    fingerprint="";s.mode = !on ? "等待 Clash TUN" : !ready ? "等待 VPN · 公司内网暂不可用" : "等待 Clash 规则模式"
                } else if let route, var session=lease {
                    let cidrs=try NetworkProbe.vpnCIDRs(interface:route.interface)
                    guard !cidrs.isEmpty else {throw AppFailure("VPN 没有可用的目标网段")}
                    let current=Files.hash(sourceBytes)+route.interface+cidrs.joined(separator:",")
                    let lock=try FileLock(root.appendingPathComponent("transaction.lock"));defer{withExtendedLifetime(lock){}}
                    let present=try Recovery.markerPresent(session.marker,api:api)
                    if fingerprint != current || !present {
                        // Probe before installing the policy; a failure while already active never falls back to public DNS.
                        let testName=settings.effectiveProbeHost
                        let upstream = try NetworkProbe.query(testName,server:settings.dns)
                        for ip in upstream {
                            guard try NetworkProbe.route(ip).interface == route.interface else {throw AppFailure("公司目标路由未经过 EasyConnect；未应用分流")}
                        }
                        guard try NetworkProbe.route(settings.dns)==route, try Data(contentsOf:source)==sourceBytes else {throw AppFailure("网络或配置正在变化，下一轮自动重试")}
                        let backup=root.appendingPathComponent("backups/first-runtime-\(settings.client.rawValue).yaml")
                        if !FileManager.default.fileExists(atPath:backup.path) {try Files.write(sourceBytes,to:backup)}
                        let leaseURL=root.appendingPathComponent("lease.json")
                        if !FileManager.default.fileExists(atPath:leaseURL.path) {session.updated=Date();try Files.json(session,to:leaseURL)}
                        lease=session
                        let document = try RuntimeSource(sourceBytes)
                        var overlay=try Configuration.overlay(document.config,settings:settings,interface:route.interface,vpnCIDRs:cidrs)
                        var rules=overlay["rules"] as? [String] ?? []
                        rules.insert("DOMAIN,\(session.marker),REJECT",at:settings.domains.count*2);overlay["rules"]=rules
                        try api.reload(overlay, sourceOrder: document.dnsPolicyOrder, overlayKeys: settings.domains.map { "+." + $0 })
                        guard try api.hasRules(settings.domains),try Recovery.markerPresent(session.marker,api:api) else {throw AppFailure("最终生效规则验证失败")}
                        let actual=try api.dns(testName)
                        guard !actual.isEmpty, Set(actual)==Set(upstream), !actual.contains(where:{$0.hasPrefix("198.18.") || $0.hasPrefix("198.19.")}) else {throw AppFailure("生效 DNS 未匹配公司上游结果")}
                        fingerprint=current;Audit(root:root).event("runtime_overlay_verified")
                        let hosts=[settings.effectiveProbeHost]
                        lastHosts=hosts.map {NetworkProbe.diagnostic(host:$0,settings:settings,vpn:route,proxyPort:general["mixed-port"] as? Int)}
                        s.hosts=lastHosts
                    }
                    session.updated=Date();try Files.json(session,to:root.appendingPathComponent("lease.json"));lease=session
                    s.active = !lastDNS.contains("失败") && !lastHosts.contains(where:{!$0.reachable})
                    s.mode=lastDNS.contains("失败") ? "协同中 · DNS / 路由异常" : s.active ? "协同中 · 检查通过" : "协同中 · HTTPS 待检查"
                }
            }
            if diagnostics {
                let hosts=[settings.effectiveProbeHost]
                lastHosts=hosts.prefix(4).map { NetworkProbe.diagnostic(host:$0,settings:settings,vpn:ready ? route : nil,proxyPort:enabled ? general["mixed-port"] as? Int : nil) };s.hosts=lastHosts
                if enabled && !fingerprint.isEmpty {s.active = !lastDNS.contains("失败") && !lastHosts.contains(where:{!$0.reachable});s.mode=s.active ? "协同中 · 检查通过" : "协同中 · 诊断异常"}
            }
        } catch {
            s.mode=enabled ? "等待恢复 / 重试" : "已关闭（检测异常）"
            let message=(error as? AppFailure)?.message ?? "检测失败；未输出配置或系统原始错误"
            s.warning += (s.warning.isEmpty ? "" : "\n")+message
            if s.clash=="检测中" {s.clash="控制 API 不可用"}
            if s.tun=="检测中" {s.tun="未知"}
            if s.vpn=="检测中" {s.vpn="未知"}
            // Do not refresh a lease after a failed transaction. Guardian retries restoration independently.
        }
        return s
    }

    private func inspectNetBird(_ plan: NetBirdPlan, api: ClashAPI, general: [String: Any],
                                snapshot: Snapshot, diagnostics: Bool) throws -> Snapshot {
        guard var session = lease else { throw AppFailure("协同会话未就绪") }
        var result = snapshot
        let bytes = try Data(contentsOf: settings.configURL)
        let resources = plan.servers.keys.sorted()
        let identity = [Files.hash(bytes), plan.device, plan.localIP] + resources.map { $0 + ":" + plan.servers[$0]! }
        let signature = identity.joined(separator: ",")
        let present = try Recovery.markerPresent(session.marker, api: api)
        let needsApply = fingerprint != signature || !present
        let hosts = settings.probeHost.isEmpty ? Array(resources.filter { !$0.hasPrefix("*.") }.prefix(3)) : [settings.probeHost]
        do {
            if needsApply || diagnostics || Date().timeIntervalSince(lastProbe) > (pendingProbe ? 5 : 25) {
                let sample = hosts.lazy.compactMap { host -> (String, String, [String])? in
                    guard let server = plan.resolver(for: host),
                          (try? NetworkProbe.route(server).interface) == plan.device,
                          let ips = try? NetworkProbe.query(host, server: server, source: plan.localIP),
                          !ips.isEmpty, ips.allSatisfy({ (try? NetworkProbe.route($0).interface) == plan.device })
                    else { return nil }
                    return (host, server, ips)
                }.first
                if let (host, server, upstream) = sample {
                    grace.reset()
                    pendingProbe = false
                    if needsApply {
                        let lock = try FileLock(root.appendingPathComponent("transaction.lock"))
                        defer { withExtendedLifetime(lock) {} }
                        let document = try RuntimeSource(bytes)
                        let overlay = try plan.overlay(document.config, marker: session.marker)
                        guard try Data(contentsOf: settings.configURL) == bytes,
                              try NetworkProbe.route(server).interface == plan.device else {
                            throw AppFailure("资源或配置正在变化，稍后重试")
                        }
                        let backup = root.appendingPathComponent("backups/first-netbird-runtime.yaml")
                        if !FileManager.default.fileExists(atPath: backup.path) { try Files.write(bytes, to: backup) }
                        session.updated = Date()
                        try Files.json(session, to: root.appendingPathComponent("lease.json"))
                        try api.reload(overlay, sourceOrder: document.dnsPolicyOrder, overlayKeys: resources)
                        let rules = try api.request("/rules")["rules"] as? [[String: Any]] ?? []
                        let assigned = rules.dropFirst().prefix(resources.count)
                        guard rules.first?["payload"] as? String == session.marker,
                              assigned.allSatisfy({ $0["proxy"] as? String == Configuration.vpnProxy }),
                              Set(assigned.compactMap { $0["payload"] as? String }) == Set(resources)
                        else { throw AppFailure("NetBird 分流规则验证失败") }
                    }
                    guard Set(try api.dns(host)) == Set(upstream) else { throw AppFailure("Clash DNS 与 VPN DNS 不一致") }
                    fingerprint = signature
                    let (code, ok) = (try? NetworkProbe.proxyHTTPS(host: host, port: general["mixed-port"] as? Int ?? 0)) ?? (0, false)
                    lastHosts = [HostDiagnostic(host: host, dns: "专用 DNS 已验证", route: "NetBird · " + plan.device,
                                                https: ok ? "HTTP " + String(code) : "HTTPS 连接失败", reachable: ok)]
                } else if Set(plan.servers.values).allSatisfy({ (try? NetworkProbe.route($0).interface) == plan.device }),
                          grace.retain(fingerprint: signature, installed: fingerprint, markerPresent: present,
                                       now: ProcessInfo.processInfo.systemUptime) {
                    pendingProbe = true
                    lastHosts = []
                } else {
                    throw AppFailure(hosts.isEmpty ? "请为通配符资源填写具体探测主机" : "NetBird 资源的 DNS 或路由尚未通过验证")
                }
                lastProbe = Date()
            }
            session.updated = Date()
            try Files.json(session, to: root.appendingPathComponent("lease.json"))
            lease = session
            result.hosts = lastHosts
            result.active = lastHosts.first?.reachable == true
            result.dns = pendingProbe ? "专用 DNS 或路由待复查" : "资源 DNS 抽检通过"
            result.mode = pendingProbe ? "保留已验证规则，正在复查" : (result.active ? "NetBird 协同中" : "NetBird 协同中 · HTTPS 待检查")
            return result
        } catch {
            try Recovery.restore(root: root, force: true, explicitSocket: explicitSocket)
            fingerprint = ""
            lastHosts = []
            grace.reset()
            pendingProbe = false
            throw error
        }
    }
}
