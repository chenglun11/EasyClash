import Foundation
import EasyClashCore

func clientTests() throws {
    let old=Data("{\"domains\":[\"example.com\"],\"dns\":\"10.0.0.53\",\"clashDirectory\":\"/tmp/old\"}".utf8)
    let settings=try JSONDecoder().decode(Settings.self,from:old)
    expectEqual(settings.client,.verge);expectEqual(settings.domains,["example.com"])
    var fl=settings;fl.client = .flclash
    expectEqual(fl.configURL.lastPathComponent,"config.yaml")
    expectEqual(settings.configURL.lastPathComponent,"clash-verge.yaml")
    expectEqual(try ClientIdentity.loopbackPort("127.0.0.1:9090").1,9090)
    for bad in ["0.0.0.0:9090","10.0.0.1:9090","evil.example:9090","127.0.0.1:9090/path","user@localhost:9090"] {expectThrows(try ClientIdentity.loopbackPort(bad))}
    expectEqual(ClientIdentity.listeningPIDs("tcp4 0 0 127.0.0.1.9090 *.* LISTEN 0 0 131072 131072 FlClashCore:123 0",port:9090),[123])
    expectTrue(ClientIdentity.listeningPIDs("tcp4 0 0 127.0.0.1.9091 *.* LISTEN 0 0 FlClashCore:123",port:9090).isEmpty)
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),suite="com.easyclash.test."+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer {defaults.removePersistentDomain(forName:suite);try? FileManager.default.removeItem(at:root)}
    let config:[String:Any]=["patchClashConfig":["external-controller":"","mixed-port":7890],"profiles":["keep-user-data"]]
    defaults.set(String(data:try JSONSerialization.data(withJSONObject:config),encoding:.utf8),forKey:"flutter.config");defaults.synchronize()
    try FlClashSetup.prepare(root:root,suiteName:suite)
    var result=try JSONSerialization.jsonObject(with:Data(defaults.string(forKey:"flutter.config")!.utf8)) as! [String:Any]
    expectEqual((result["patchClashConfig"] as! [String:Any])["external-controller"] as? String,FlClashSetup.endpoint)
    result["new-user-setting"]="preserved"
    defaults.set(String(data:try JSONSerialization.data(withJSONObject:result),encoding:.utf8),forKey:"flutter.config");defaults.synchronize()
    try FlClashSetup.prepare(root:root,suiteName:suite)
    try FlClashSetup.undo(root:root,suiteName:suite)
    result=try JSONSerialization.jsonObject(with:Data(defaults.string(forKey:"flutter.config")!.utf8)) as! [String:Any]
    expectEqual((result["patchClashConfig"] as! [String:Any])["external-controller"] as? String,"")
    expectEqual(result["new-user-setting"] as? String,"preserved")
    expectEqual(result["profiles"] as? [String],["keep-user-data"])
}

func flClashIntegrationTests() throws {
    guard FileManager.default.fileExists(atPath:"/Applications/FlClash.app/Contents/MacOS/FlClashCore") else {print("SKIP FlClash core integration: not installed");return}
    let dir=URL(fileURLWithPath:"/tmp/fltest-"+String(UUID().uuidString.prefix(8)))
    let fixture=Process();fixture.executableURL=URL(fileURLWithPath:"/usr/bin/python3");fixture.arguments=["scripts/flclash-fixture.py",dir.path];fixture.standardOutput=FileHandle.nullDevice;fixture.standardError=FileHandle.nullDevice;try fixture.run()
    defer {if fixture.isRunning {fixture.terminate()};fixture.waitUntilExit();try? FileManager.default.removeItem(at:dir)}
    let ready=dir.appendingPathComponent("ready")
    for _ in 0..<120 {if FileManager.default.fileExists(atPath:ready.path) || !fixture.isRunning {break};Thread.sleep(forTimeInterval:0.1)}
    expectTrue(FileManager.default.fileExists(atPath:ready.path))
    var s=fixtureSettings();s.client = .flclash;s.clashDirectory=dir.path
    let api=try ClashAPI(directory:dir,client:s.client)
    let version=try api.request("/version")["version"] as? String ?? "unknown"
    let original=try Data(contentsOf:s.configURL)
    let base=try Files.yaml(s.configURL)
    let overlay=try Configuration.overlay(base,settings:s,interface:"utun42",vpnCIDRs:["10.0.0.0/8"])
    var owned=overlay;var lease=Lease(settings:s);lease.owner=999999
    var rules=owned["rules"] as! [String];rules.append("DOMAIN,\(lease.marker),REJECT");owned["rules"]=rules
    let root=dir.appendingPathComponent("state")
    try Files.json(lease,to:root.appendingPathComponent("lease.json"))
    try api.reload(owned,requireTun:false)
    expectTrue(try api.hasRules(s.domains));expectTrue(try Recovery.markerPresent(lease.marker,api:api))
    expectEqual(try Data(contentsOf:s.configURL),original)
    expectFalse((try api.configs()["tun"] as? [String:Any])?["enable"] as? Bool ?? true)
    var latest=base;latest["rules"]=["DOMAIN,new-subscription.example,DIRECT","MATCH,DIRECT"]
    try Files.write(Data(try Files.yamlText(latest).utf8),to:s.configURL)
    let helper=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("EasyClashRecovery")
    let guardProcess=Process();guardProcess.executableURL=helper;guardProcess.arguments=["watch","--state",root.path];guardProcess.standardOutput=FileHandle.nullDevice;guardProcess.standardError=FileHandle.nullDevice;try guardProcess.run()
    defer {if guardProcess.isRunning {guardProcess.terminate()};guardProcess.waitUntilExit()}
    for _ in 0..<80 {if !FileManager.default.fileExists(atPath:root.appendingPathComponent("lease.json").path) {break};Thread.sleep(forTimeInterval:0.1)}
    expectFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("lease.json").path))
    expectFalse(try Recovery.markerPresent(lease.marker,api:api))
    expectEqual((try api.request("/rules")["rules"] as? [[String:Any]])?.first?["payload"] as? String,"new-subscription.example")
    // A wrong secret must fail and must never appear in process arguments.
    var wrong=latest;wrong["secret"]="incorrect";try Files.write(Data(try Files.yamlText(wrong).utf8),to:s.configURL)
    let invalid=try ClashAPI(directory:dir,client:.flclash)
    expectThrows(try invalid.configs())
    let foreignPort=try String(contentsOf:dir.appendingPathComponent("unowned-port"))
    wrong["external-controller"]="127.0.0.1:"+foreignPort
    try Files.write(Data(try Files.yamlText(wrong).utf8),to:s.configURL)
    expectThrows(try ClashAPI(directory:dir,client:.flclash))
    print("PASS actual isolated FlClash \(version): authenticated HTTP, owner verification, overlay, latest-source recovery; TUN off")
}
