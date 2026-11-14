import Foundation
import EasyClashCore

func observationTests() throws {
    let domains=["corp.example"]
    func raw(_ host:String="build.corp.example",chain:[String]=["DIRECT"],ip:String="192.0.2.80",id:String="test") -> [String:Any] {
        ["id":id,"metadata":["host":host,"destinationIP":ip,"process":"/private/user/Browser","processPath":"/secret/credentials","sniffHost":"https://hidden.example/?token=private"],"rule":"DomainSuffix","rulePayload":"corp.example","chains":chain,"upload":40,"download":80]
    }
    let now=Date()
    let direct=try unwrap(TrafficRecord(raw:raw(),domains:domains,vpnInterface:"utun4",routeInterface:"en0",now:now))
    expectEqual(direct.path,.direct);expectTrue(direct.company);expectEqual(direct.process,"Browser")
    let routed=try unwrap(TrafficRecord(raw:raw(),domains:domains,vpnInterface:"utun10",routeInterface:"utun10"))
    expectEqual(routed.path,.vpnRoute);expectTrue(routed.evidence.contains("路由快照"))
    let changed=try unwrap(TrafficRecord(raw:raw(),domains:domains,vpnInterface:"utun10",routeInterface:"utun4"))
    expectEqual(changed.path,.direct)
    let fake=try unwrap(TrafficRecord(raw:raw(ip:"198.18.0.20"),domains:domains,vpnInterface:"utun4",routeInterface:"utun4"))
    expectEqual(fake.path,.direct)
    let proxy=try unwrap(TrafficRecord(raw:raw(chain:["Proxy Secret","DIRECT"]),domains:domains,vpnInterface:"utun4",routeInterface:"utun4"))
    expectEqual(proxy.path,.proxy)
    let ambiguous=try unwrap(TrafficRecord(raw:raw(chain:[Configuration.vpnProxy]),domains:domains,vpnInterface:"utun4",routeInterface:nil))
    expectEqual(ambiguous.path,.unknown)
    let bound=try unwrap(TrafficRecord(raw:raw(chain:[Configuration.vpnProxy]),domains:domains,vpnInterface:"utun4",routeInterface:nil,vpnBindingVerified:true))
    expectEqual(bound.path,.vpnBound);expectFalse(bound.evidence.contains("utun4"));expectTrue(bound.evidence.contains("实际绑定接口"))
    expectFalse(ObservationText.company("evilcorp.example",domains:domains));expectFalse(ObservationText.company("corp.example.attacker.test",domains:domains))
    expectTrue(ObservationText.company("corp.example",domains:domains))
    expectNil(TrafficRecord(raw:[:],domains:domains,vpnInterface:nil,routeInterface:nil))
    let missing=try unwrap(TrafficRecord(raw:raw("",chain:[],ip:"bad-ip"),domains:domains,vpnInterface:nil,routeInterface:nil))
    expectEqual(missing.path,.unknown);expectEqual(missing.destination,"")
    let injected=try unwrap(TrafficRecord(raw:raw("https://name:pass@corp.example/?token=SECRET"),domains:domains,vpnInterface:nil,routeInterface:nil))
    expectEqual(injected.host,"")
    var history=TrafficHistory(limit:2);history.update([direct,direct]);expectEqual(history.records.count,1)
    history.update([]);expectFalse(history.records[0].present)
    let second=try unwrap(TrafficRecord(raw:raw(id:"second"),domains:domains,vpnInterface:nil,routeInterface:nil,now:now.addingTimeInterval(1)))
    let third=try unwrap(TrafficRecord(raw:raw(id:"third"),domains:domains,vpnInterface:nil,routeInterface:nil,now:now.addingTimeInterval(2)))
    history.update([second,third]);expectEqual(history.records.count,2);expectEqual(history.records.first?.id,"third")
    for secret in ["corp.example","192.0.2.80","Browser","second","third","SECRET"] {expectFalse(history.redactedReport.contains(secret))}
    history.clear();expectTrue(history.records.isEmpty)
    expectEqual(ObservationText.server(""),"[未设置上游]")
    expectEqual(ObservationText.server("tcp://192.0.2.53:53#utun4"),"tcp://192.0.2.53:53#utun4")
    for v in ["https://dns.example/dns-query?token=SECRET","tcp://user:SECRET@192.0.2.53","udp://192.0.2.53/path","https://dns.example/SECRET"] {expectFalse(ObservationText.server(v).contains("SECRET"))}
    let base:[String:Any]=["secret":"SECRET","proxies":[["server":"secret.example","password":"SECRET"]],"dns":["enable":true,"enhanced-mode":"fake-ip","nameserver-policy":["+.corp.example":["tcp://192.0.2.53:53#en0"],"build.corp.example":["https://dns.example/?token=SECRET"],"other.example":["PRIVATE"]],"fake-ip-filter":["+.corp.example","secret.example"]]]
    let before=try JSONSerialization.data(withJSONObject:base,options:.sortedKeys)
    let projection=ConfigInspection.project(base,domains:domains)
    let text=projection.map {$0.field+" "+$0.value}.joined(separator:"\n")
    expectTrue(text.contains("192.0.2.53"));expectFalse(text.contains("SECRET"));expectFalse(text.contains("PRIVATE"));expectFalse(text.contains("secret.example"))
    expectEqual(before,try JSONSerialization.data(withJSONObject:base,options:.sortedKeys))
    let rules=ConfigInspection.ruleLines([["type":"Match","payload":"","proxy":"SECRET"],["type":"DomainSuffix","payload":"corp.example","proxy":"DIRECT"]],domains:domains)
    expectEqual(rules.count,1);expectTrue(rules[0].field.contains("#2"))
    let ambiguousRules=ConfigInspection.ruleLines([["type":"Match","payload":"","proxy":Configuration.vpnProxy]],domains:domains)
    expectTrue(ambiguousRules[0].value.contains("条件未验证"));expectFalse(ambiguousRules[0].value.contains("VPN 网段"))
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("ec-observation-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:dir)}
    try Files.write(Data("{\"event\":\"mode_enabled\",\"time\":\"2026-10-13T00:00:00Z\"}\n{\"event\":\"SECRET\",\"time\":\"bad\"}\n".utf8),to:dir.appendingPathComponent("events.jsonl"))
    let events=ObservationReader.events(root:dir);expectEqual(events.count,1);expectFalse(events[0].value.contains("SECRET"))
    var inspection = ConfigInspection()
    inspection.disk = projection
    inspection.rules = rules
    let hidden = projection.map(\.publicValue).joined() + inspection.redactedReport
    for detail in ["corp.example", "192.0.2.53", "SECRET", "utun4"] { expectFalse(hidden.contains(detail)) }
    print("PASS observation: routing evidence, reconnect/fake-IP ambiguity, bounded history, redaction, config projection")
}
