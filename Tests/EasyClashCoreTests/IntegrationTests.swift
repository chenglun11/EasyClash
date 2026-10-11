import Foundation
import Darwin
import EasyClashCore

func integrationTests() throws {
    guard let binary=ProcessInfo.processInfo.environment["MIHOMO_BINARY"] else {print("SKIP isolated core integration: set MIHOMO_BINARY");return}
    let dir=URL(fileURLWithPath:"/tmp").appendingPathComponent("easyclash-tests-"+String(UUID().uuidString.prefix(8)))
    try Files.prepare(dir)
    let socket=dir.appendingPathComponent("api.sock").path
    let source=dir.appendingPathComponent("clash-verge.yaml"),root=dir.appendingPathComponent("state")
    var base:[String:Any]=["mode":"rule","mixed-port":0,"allow-lan":false,"tun":["enable":false],"dns":["enable":false],"proxies":[],"proxy-groups":[],"rules":["DOMAIN,existing.example,DIRECT","MATCH,DIRECT"],"external-controller-unix":socket]
    try Files.write(Data(try Files.yamlText(base).utf8),to:source)
    let p=Process();p.executableURL=URL(fileURLWithPath:binary);p.arguments=["-d",dir.path,"-f",source.path,"-ext-ctl-unix",socket]
    p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run()
    defer {p.terminate();p.waitUntilExit();try? FileManager.default.removeItem(at:dir)}
    for _ in 0..<50 {if FileManager.default.fileExists(atPath:socket){break};Thread.sleep(forTimeInterval:0.1)}
    let api=try ClashAPI(directory:dir,explicitSocket:socket)
    expectNotNil(try api.request("/version")["version"])
    var settings=fixtureSettings();settings.clashDirectory=dir.path
    var lease=Lease(settings:settings);lease.owner=999999
    base["rules"]=["DOMAIN,\(lease.marker),REJECT","MATCH,DIRECT"]
    try Files.json(lease,to:root.appendingPathComponent("lease.json"))
    print("fixture: apply overlay")
    try api.reload(base,requireTun:false)
    expectTrue(try Recovery.markerPresent(lease.marker,api:api))
    // User changes mode through the controller and edits their source during the session.
    try api.request("/configs",method:"PATCH",body:["mode":"direct"])
    var latest=try Files.yaml(source);latest["rules"]=["DOMAIN,user-added.example,REJECT","MATCH,DIRECT"]
    try Files.write(Data(try Files.yamlText(latest).utf8),to:source)
    print("fixture: restore")
    expectTrue(try Recovery.restore(root:root,explicitSocket:socket))
    expectFalse(try Recovery.markerPresent(lease.marker,api:api))
    expectEqual(try api.configs()["mode"] as? String,"direct")
    let restored=try api.request("/rules")["rules"] as! [[String:Any]]
    expectEqual(restored.first?["payload"] as? String,"user-added.example")
    expectFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("lease.json").path))
    // A subscription update has already removed our marker: recovery must leave that runtime alone.
    try Files.json(lease,to:root.appendingPathComponent("lease.json"))
    latest["rules"]=["DOMAIN,subscription.example,REJECT","MATCH,DIRECT"]
    try api.reload(latest,requireTun:false)
    print("fixture: restore")
    expectTrue(try Recovery.restore(root:root,explicitSocket:socket))
    let after=try api.request("/rules")["rules"] as! [[String:Any]]
    expectEqual(after.first?["payload"] as? String,"subscription.example")
    // Compile nested route-aware DIRECT rules in a real isolated core (no real VPN traffic).
    var routeFixture=latest
    routeFixture["dns"]=["enable":true,"nameserver":["127.0.0.1:53535"],"enhanced-mode":"fake-ip"]
    let routed=try Configuration.overlay(routeFixture,settings:settings,interface:"utun42",vpnCIDRs:["10.0.0.0/8","192.0.2.80/32"])
    try api.reload(routed,requireTun:false)
    expectTrue(try api.hasRules(settings.domains))
    let proxies=try api.request("/proxies")["proxies"] as? [String:Any] ?? [:]
    expectNotNil(proxies[Configuration.vpnProxy])
    // Run the actual standalone guardian against ONLY the isolated socket.
    let helper=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("EasyClashRecovery")
    let owner=Process();owner.executableURL=URL(fileURLWithPath:"/bin/sleep");owner.arguments=["60"];try owner.run()
    defer {if owner.isRunning {owner.terminate()};owner.waitUntilExit()}
    lease.owner=owner.processIdentifier;lease.updated=Date()
    var owned=latest;owned["rules"]=["DOMAIN,\(lease.marker),REJECT","MATCH,DIRECT"]
    try api.reload(owned,requireTun:false);try Files.json(lease,to:root.appendingPathComponent("lease.json"))
    let guardian=Process();guardian.executableURL=helper;guardian.arguments=["watch","--state",root.path,"--socket",socket];guardian.standardOutput=FileHandle.nullDevice;guardian.standardError=FileHandle.nullDevice;try guardian.run()
    defer {if guardian.isRunning {guardian.terminate()};guardian.waitUntilExit()}
    kill(owner.processIdentifier,SIGKILL);owner.waitUntilExit()
    for _ in 0..<70 {if !FileManager.default.fileExists(atPath:root.appendingPathComponent("lease.json").path) {break};Thread.sleep(forTimeInterval:0.1)}
    expectFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("lease.json").path))
    expectFalse(try Recovery.markerPresent(lease.marker,api:api))
    // Removing only the app bundle also expires a live owner's lease.
    let fakeApp=dir.appendingPathComponent("Fake.app");try Files.prepare(fakeApp)
    lease.owner=getpid();lease.updated=Date();lease.appPath=fakeApp.path
    try api.reload(owned,requireTun:false);try Files.json(lease,to:root.appendingPathComponent("lease.json"));try FileManager.default.removeItem(at:fakeApp)
    for _ in 0..<70 {if !FileManager.default.fileExists(atPath:root.appendingPathComponent("lease.json").path) {break};Thread.sleep(forTimeInterval:0.1)}
    expectFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("lease.json").path))
    expectFalse(try Recovery.markerPresent(lease.marker,api:api))
    print("PASS standalone guardian: actual SIGKILL owner and deleted app bundle recovered")
    let deleted=Coordinator(root:dir.appendingPathComponent("deleted-state"),settings:settings,explicitSocket:socket)
    try deleted.enable(helper:nil,appPath:dir.appendingPathComponent("absent.app").path)
    expectFalse(deleted.inspect().enabled)
    expectFalse(deleted.enabled)
    // The lock prevents watchdog/app concurrent mutations.
    let lock=try FileLock(root.appendingPathComponent("transaction.lock"))
    try Files.json(lease,to:root.appendingPathComponent("lease.json"))
    expectThrows(try Recovery.restore(root:root,force:true,explicitSocket:socket))
    withExtendedLifetime(lock){}
    print("PASS isolated Mihomo: crash recovery, latest source, user live mode, subscription supersession, lock exclusion")
}
