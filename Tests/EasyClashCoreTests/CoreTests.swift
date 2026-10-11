import Foundation
import EasyClashCore

func fixtureSettings() -> Settings {
    var s=Settings();s.domains=["corp.example.com"];s.dns="192.0.2.53";return s
}
final class CoreTests {
    func testUnconfiguredLaunchAndRedactedReport() throws {
        let empty=Settings();expectTrue(empty.domains.isEmpty);expectEqual(empty.dns,"");expectThrows(try empty.validated())
        let decoded=try JSONDecoder().decode(Settings.self,from:Data("{}".utf8))
        expectEqual(decoded.domains,[]);expectEqual(decoded.dns,"")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let coordinator=Coordinator(root:root,settings:empty)
        expectEqual(coordinator.inspect().mode,"待配置")
        expectThrows(try coordinator.enable(helper:nil))
        expectFalse(FileManager.default.fileExists(atPath:root.path))
        var s=fixtureSettings();s.probeHost="portal.corp.example.com";expectNoThrow(try s.validated())
        s.probeHost="outside.example.com";expectThrows(try s.validated())
        s.probeHost="https://corp.example.com";expectThrows(try s.validated())
        var report=Snapshot();report.hosts=[try JSONDecoder().decode(HostDiagnostic.self,from:Data(#"{"host":"portal.corp.example.com","dns":"成功","route":"VPN","https":"404","reachable":true}"#.utf8))]
        expectFalse(report.report.contains("corp.example.com"));expectTrue(report.report.contains("目标 1"))
        let api=try ClashAPI(directory:root,explicitSocket:root.appendingPathComponent("absent.sock").path)
        do {_ = try api.request("/proxies/private-node.example");expectTrue(false)}
        catch {expectFalse(error.localizedDescription.contains("private-node.example"))}

    }

    func testVPNRouteRejectsClashDefaultAndProcessOnly() {
        let good=RouteInfo.parse("destination: 192.0.2.53\ngateway: 192.0.2.1\ninterface: utun4\n")
        expectTrue(good.isVPN(dns:"192.0.2.53",clashDevice:"utun1024",easyConnectRunning:true))
        expectFalse(good.isVPN(dns:"192.0.2.53",clashDevice:"utun4",easyConnectRunning:true))
        expectFalse(good.isVPN(dns:"192.0.2.53",clashDevice:"utun1024",easyConnectRunning:false))
        for text in ["destination: default\ngateway: 192.0.2.1\ninterface: utun4", "destination: 192.0.2.53\ngateway: 198.18.0.1\ninterface: utun10", "destination: 192.0.2.53\ngateway: 192.168.1.1\ninterface: en0"] {
            expectFalse(RouteInfo.parse(text).isVPN(dns:"192.0.2.53",clashDevice:"utun1024",easyConnectRunning:true))
        }
        expectTrue(RouteInfo.parse("destination: 192.0.2.53\ngateway: 192.0.2.1\ninterface: utun10").isVPN(dns:"192.0.2.53",clashDevice:"utun1024",easyConnectRunning:true))
    }
    func testOverlayRemovesPublicRaceAndPreservesOtherUserSettings() throws {
        let b:[String:Any] = ["dns":["enable":true,"nameserver":["1.1.1.1"],"nameserver-policy":["+.google.com":["tls://8.8.8.8"],"portal.corp.example.com":["8.8.8.8"],"+.corp.example.com":["192.0.2.53","1.1.1.1"]],"fake-ip-filter":["+.lan"]],"rules":["MATCH,Proxy"],"tun":["enable":true,"device":"utun1024"],"custom":"keep"]
        let result=try Configuration.overlay(b,settings:fixtureSettings(),interface:"utun10")
        let dns=try unwrap(result["dns"] as? [String:Any]),p=try unwrap(dns["nameserver-policy"] as? [String:Any])
        expectEqual(p["+.corp.example.com"] as? [String],["tcp://192.0.2.53:53#utun10"])
        expectNil(p["portal.corp.example.com"])
        expectEqual(p["+.google.com"] as? [String],["tls://8.8.8.8"])
        expectEqual(result["rules"] as? [String],["DOMAIN-SUFFIX,corp.example.com,DIRECT","MATCH,Proxy"])
        expectEqual(result["custom"] as? String,"keep")
        expectTrue((dns["fake-ip-filter"] as? [String] ?? []).contains("+.lan"))
        expectEqual(NSDictionary(dictionary:b["tun"] as! [String:Any]),NSDictionary(dictionary:result["tun"] as! [String:Any]))
        expectEqual((b["rules"] as? [String]),["MATCH,Proxy"])
    }
    func testWhitelistFailsWithoutMutation() {
        expectThrows(try Configuration.overlay(["dns":["enable":true,"fake-ip-filter-mode":"whitelist"]],settings:fixtureSettings(),interface:"utun4"))
    }
    func testSettingsRejectInjectionAndSupportMultipleDomains() throws {
        for domain in ["*.corp.example.com","https://corp.example.com","foo..com","foo.com;rm","foo.com\n","-foo.com"] {
            var s=fixtureSettings();s.domains=[domain]
            if domain.hasSuffix("\n") {expectNoThrow(try s.validated())} else {expectThrows(try s.validated())}
        }
        var s=fixtureSettings();s.domains=[" CORP.EXAMPLE.COM ","internal.example.com","corp.example.com"]
        expectEqual(try s.validated().domains,["corp.example.com","internal.example.com"])
        s.dns="1.2.3.4#en0";expectThrows(try s.validated())
    }
    func testLeaseExpiresAfterCrashHangClockRollbackAndDeletion() {
        var l=Lease(settings:fixtureSettings())
        expectFalse(l.expired(ownerAlive:true))
        expectTrue(l.expired(ownerAlive:false))
        expectTrue(l.expired(now:l.updated.addingTimeInterval(46),ownerAlive:true))
        expectTrue(l.expired(now:l.updated.addingTimeInterval(-10),ownerAlive:true))
        l.appPath="/nonexistent-easyclash-app";expectTrue(l.expired(ownerAlive:true))
    }

    func testRouteTableScopeAndInterfaceChanges() {
        let table="""
        Destination Gateway Flags Netif Expire
        default 192.0.2.1 UGScg utun4
        10/20 192.0.2.1 UGSc utun4
        192.0.2.80 192.0.2.1 UGHS utun4
        8/5 198.18.0.1 UGSc utun1024
        192.0.2.53 192.0.2.1 UGHS utun10
        """
        expectEqual(NetworkProbe.parseCIDRs(table,interface:"utun4"),["10.0.0.0/20","192.0.2.80/32"])
        expectEqual(NetworkProbe.parseCIDRs(table,interface:"utun10"),["192.0.2.53/32"])
    }
    func testLogContainsOnlyEventCode() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        Audit(root:root).event("runtime_restored")
        let line=try String(contentsOf:root.appendingPathComponent("events.jsonl"))
        expectTrue(line.contains("runtime_restored"));expectFalse(line.contains("secret"))
        let attrs=try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("events.jsonl").path)
        expectEqual(attrs[.posixPermissions] as? Int,0o600)
    }

    func testBackgroundCommandsExitAndTimeout() throws {
        let done=DispatchSemaphore(value:0)
        let queue=DispatchQueue(label:"test.command.worker")
        queue.async {
            do {
                for _ in 0..<100 {
                    let result=try Command.run("/usr/bin/true",[],timeout:1)
                    expectEqual(result.code,0)
                }
                let start=Date()
                let result=try Command.run("/bin/sleep",["10"],timeout:0.1)
                expectTrue(result.code != 0)
                expectTrue(Date().timeIntervalSince(start)<4)
            } catch {failure("background command failed",file:#filePath,line:#line)}
            done.signal()
        }
        let completion=done.wait(timeout:.now()+15)
        expectTrue(completion == .success)
    }

}
