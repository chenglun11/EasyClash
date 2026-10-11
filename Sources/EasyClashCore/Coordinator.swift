import Foundation

public struct Snapshot: Codable {
    public var client="Clash Verge Rev"
    public var mode="已关闭"
    public var clash="检测中"
    public var tun="检测中"
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
        var rows=["EasyClash 脱敏诊断", "检测时间：\(ISO8601DateFormatter().string(from:checked))", "客户端：\(client)","协同模式：\(mode)","Clash：\(clash)","TUN：\(tun)","EasyConnect：\(easyConnect)","VPN 路由：\(vpn)","公司 DNS：\(dns)"]
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
            s.mode="待配置";s.warning="请先在设置中填写公司域名、DNS 和探测主机。"
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
            let route=try? NetworkProbe.route(settings.dns)
            let ready=route?.isVPN(dns:settings.dns,clashDevice:device,easyConnectRunning:process)==true
            s.vpn=ready ? "可用 · "+route!.interface : "不可用（进程存在不代表 VPN 已连接）"
            let source=settings.configURL
            let sourceBytes=try Data(contentsOf:source)
            let base=try Files.yaml(source)
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
                    let attrs=try FileManager.default.attributesOfItem(atPath:source.path)
                    let cidrs=try NetworkProbe.vpnCIDRs(interface:route.interface)
                    guard !cidrs.isEmpty else {throw AppFailure("VPN 没有可用的目标网段")}
                    let current=Files.hash(sourceBytes)+route.interface+cidrs.joined(separator:",")+String(describing:attrs[.modificationDate])
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
                        var overlay=try Configuration.overlay(base,settings:settings,interface:route.interface,vpnCIDRs:cidrs)
                        var rules=overlay["rules"] as? [String] ?? []
                        rules.insert("DOMAIN,\(session.marker),REJECT",at:settings.domains.count*2);overlay["rules"]=rules
                        try api.reload(overlay)
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
}
