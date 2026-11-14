import Foundation
import EasyClashCore
func netBirdTests() throws {
    let online = #"{"daemonStatus":"Connected","netbirdIp":"100.64.0.7/16","management":{"url":"https://vpn.example"}}"#
    var calls: [[String]] = []
    try NetBirdConnection.connect(managementURL:"https://vpn.example") { args, _ in calls.append(args); return (0,online) }
    expectEqual(calls, [["status", "--json"]])
    calls = []
    try NetBirdConnection.connect(managementURL:"https://vpn.example") { args, _ in
        calls.append(args)
        if calls.count == 1 { return (0, #"{"daemonStatus":"NeedsLogin"}"#) }
        return (0, args.first == "up" ? "" : online)
    }
    expectEqual(calls, [["status","--json"],["up","--management-url","https://vpn.example"],["status","--json"]])
    expectThrows(try NetBirdConnection.connect(managementURL:"https://other.example") { _,_ in (0, online) })
    expectThrows(try NetBirdConnection.connect(managementURL:"") { _,_ in (1, "error") })
    expectThrows(try NetBirdConnection.validateManagementURL("https://user:password@vpn.example"))
    var grace=NetBirdProbeGrace()
    expectTrue(grace.retain(fingerprint:"plan",installed:"plan",markerPresent:true,now:10))
    expectTrue(grace.retain(fingerprint:"plan",installed:"plan",markerPresent:true,now:39))
    expectFalse(grace.retain(fingerprint:"plan",installed:"plan",markerPresent:true,now:40))
    grace.reset()
    expectTrue(grace.retain(fingerprint:"plan",installed:"plan",markerPresent:true,now:42))
    expectFalse(grace.retain(fingerprint:"new-interface",installed:"plan",markerPresent:true,now:43))
    expectFalse(grace.retain(fingerprint:"plan",installed:"plan",markerPresent:false,now:44))
    expectFalse(grace.retain(fingerprint:"plan",installed:"other-plan",markerPresent:true,now:45))
    let event=["message":"No routing peer available","timestamp":"2026-11-13T09:25:15.350392Z","metadata":"private-value"]
    let time=ISO8601DateFormatter().date(from:"2026-11-13T09:26:16Z")!
    expectEqual(NetBirdPlan.recentPeerLoss(["events":[event]],now:time),"约1分钟前有资源无可用路由节点")
    expectNil(NetBirdPlan.recentPeerLoss(["events":[event]],now:time.addingTimeInterval(900)))
    expectNil(NetBirdPlan.recentPeerLoss(["events":[event]],now:time.addingTimeInterval(-120)))
    let listing="""
      - ID: one
        Domains: code.corp.example
        Status: Selected
      - ID: two
        Domains: private.corp.example
        Status: Not Selected
      - ID: three
        Domains: wrong.corp.example
        Status: Selected
    """
    let scopes=["code.corp.example","private.corp.example","wrong.corp.example","unassigned.corp.example","corp.example.attacker.test"].enumerated().map {i,n in "resolver #\(i+1)\n domain : \(n)\n nameserver[0] : \(i==2 ? "192.0.2.1":"100.64.0.53")\n port : 53\n"}.joined()
    let assignments=NetBirdPlan.assigned(listing), matched=NetBirdPlan.scoped(scopes,selected:assignments,domains:["corp.example"],ownsDNS:{$0=="100.64.0.53"})
    expectEqual(matched,["code.corp.example":"100.64.0.53"])
    let plan=NetBirdPlan(device:"utun71",localIP:"100.64.0.5",servers:matched)
    let baseline:[String:Any]=["dns":["enable":true,"nameserver-policy":["public.corp.example":"https://public.example/dns-query"]],"rules":["DOMAIN,public.corp.example,Proxy","MATCH,DIRECT"]]
    let overlay=try plan.overlay(baseline,marker:"session.invalid")
    let policies=(overlay["dns"] as? [String:Any])?["nameserver-policy"] as? [String:Any]
    expectEqual(policies?["code.corp.example"] as? [String],["tcp://100.64.0.53:53#utun71"])
    expectEqual(policies?["public.corp.example"] as? String,"https://public.example/dns-query")
    expectNil(policies?["+.corp.example"])
    expectEqual(overlay["rules"] as? [String],["DOMAIN,session.invalid,REJECT","DOMAIN,code.corp.example,"+Configuration.vpnProxy,"DOMAIN,public.corp.example,Proxy","MATCH,DIRECT"])
    let renamed = NetBirdPlan(device: "utun82", localIP: "100.64.0.9", servers: matched)
    let fresh = try renamed.overlay(baseline, marker:"session.invalid")
    let proxy = (fresh["proxies"] as? [[String:Any]])?.last
    expectEqual(proxy?["interface-name"] as? String, "utun82")
    let latestPolicy = (fresh["dns"] as? [String:Any])?["nameserver-policy"] as? [String:Any]
    expectEqual(latestPolicy?["code.corp.example"] as? [String], ["tcp://100.64.0.53:53#utun82"])
    let shared = NetBirdPlan.scoped("resolver #1\n domain : corp.example\n nameserver[0] : 100.64.0.53\n",
                                    selected:["corp.example","*.corp.example"], domains:["corp.example"], ownsDNS:{ _ in true })
    expectEqual(shared.count, 2)
    let wildcard = NetBirdPlan(device: "utun20", localIP:"100.64.0.5", servers:["*.corp.example":"100.64.0.53"])
    expectEqual(wildcard.resolver(for:"portal.corp.example"), "100.64.0.53")
    expectNil(wildcard.resolver(for:"corp.example"))
    expectNil(wildcard.resolver(for:"deep.nested.corp.example"))
    var settings = Settings()
    settings.vpnBackend = .netBird
    settings.domains = ["corp.example"]
    expectNoThrow(try settings.validated())
    let legacy = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    expectEqual(legacy.vpnBackend, .easyConnect)
}
