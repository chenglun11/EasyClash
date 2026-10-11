import SwiftUI
import AppKit
import Network
import ServiceManagement
import EasyClashCore

final class Model: ObservableObject {
    @Published var state=Snapshot()
    @Published var busy=false
    @Published var checking=false
    @Published var error=""
    @Published var settings=EasyClashCore.Settings()
    @Published var login=false
    private let engine=Coordinator()
    private var pendingDiagnostics=false
    private var appLock:FileLock?
    private let queue=DispatchQueue(label:"com.easyclash.coordinator",qos:.utility)
    private var timer:Timer?
    private let monitor=NWPathMonitor()
    private var observers:[NSObjectProtocol]=[]
    private var windows:[String:NSWindow]=[:]
    init() {
        do {appLock=try FileLock(Files.state.appendingPathComponent("app.lock"))} catch {DispatchQueue.main.async {NSApp.terminate(nil)};return}
        settings=engine.settings;login=SMAppService.mainApp.status == .enabled
        queue.async { _ = try? Recovery.restore(root:Files.state,force:true) }
        timer=Timer.scheduledTimer(withTimeInterval:4,repeats:true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        monitor.pathUpdateHandler={ [weak self] _ in Task { @MainActor in self?.refresh() } };monitor.start(queue:queue)
        let nc=NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.refresh(diagnostics:true) } })
        observers.append(nc.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            // Stop the lease immediately on sleep; the next poll/wake re-evaluates the actual route.
            self?.queue.async { _ = try? Recovery.restore(root:Files.state,force:true) }
        })
        if CommandLine.arguments.contains("--enable-cooperation") {toggle()} else {refresh()}
    }
    func refresh(diagnostics:Bool=false) {
        guard !busy && !checking else {pendingDiagnostics = pendingDiagnostics || diagnostics;return};checking=true
        queue.async {let s=self.engine.inspect(diagnostics:diagnostics);DispatchQueue.main.async {self.state=s;self.checking=false;self.runPendingDiagnostics()}}
    }
    private func runPendingDiagnostics() {
        guard pendingDiagnostics && !busy && !checking else {return}
        pendingDiagnostics=false;refresh(diagnostics:true)
    }
    func operation(_ work:@escaping () throws -> Void, completion:(()->Void)?=nil) {
        guard !busy else {return};busy=true;error=""
        queue.async {
            var failure=""
            do {try work()} catch {failure=(error as? AppFailure)?.message ?? "操作未完成；请查看诊断和恢复说明"}
            let s=self.engine.inspect()
            DispatchQueue.main.async {self.error=failure;self.state=s;self.busy=false;if failure.isEmpty {completion?()};self.runPendingDiagnostics()}
        }
    }
    func toggle() {
        let off=state.enabled
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/EasyClashRecovery")
        let app=Bundle.main.bundleURL.path
        operation {if off {try self.engine.disable()} else {try self.engine.enable(helper:helper,appPath:app)}}
    }
    func save(_ s:EasyClashCore.Settings) {operation({try self.engine.save(s)},completion:{self.settings=s;self.windows["设置"]?.close()})}
    func setLogin(_ value:Bool) {
        do {if value {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()};login=SMAppService.mainApp.status == .enabled}
        catch {self.error="登录启动设置失败，请在系统设置 → 通用 → 登录项中检查"}
    }
    func openEasyConnect() {
        let url=URL(fileURLWithPath:"/Applications/EasyConnect.app")
        NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()) { _,error in if error != nil {Task { @MainActor in self.error="未找到 /Applications/EasyConnect.app" }} }
    }
    func show(_ name:String) {
        if let w=windows[name] {w.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return}
        let content:AnyView = name=="设置" ? AnyView(SettingsView(model:self)) : AnyView(DiagnosticsView(model:self))
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:name=="设置" ? 510:660,height:name=="设置" ? 660:540),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title="EasyClash · "+name;w.contentView=NSHostingView(rootView:content);w.isReleasedWhenClosed=false;w.center();windows[name]=w;w.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        if name=="诊断" {refresh(diagnostics:true)}
    }
    func quit() {operation({try self.engine.disable()},completion:{NSApp.terminate(nil)})}
}

struct StateRow:View {
    let title:String;let value:String
    var body:some View {HStack(alignment:.top) {Text(title).foregroundStyle(.secondary).frame(width:82,alignment:.leading);Text(value).frame(maxWidth:.infinity,alignment:.leading)}.font(.system(size:12))}
}
struct MenuView:View {
    @ObservedObject var model:Model
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {Image(systemName:model.state.active ? "network.badge.shield.half.filled":"network").font(.title2).foregroundStyle(model.state.active ? .green:.secondary);VStack(alignment:.leading,spacing:3) {Text("EasyClash").font(.headline);Text(model.state.mode).font(.caption).foregroundStyle(.secondary)};Spacer();if model.busy || model.checking {ProgressView().controlSize(.small)}}
            Divider()
            VStack(spacing:8) {StateRow(title:model.state.client=="FlClash" ? "FlClash":"Clash",value:model.state.clash);StateRow(title:"TUN",value:model.state.tun);StateRow(title:"EasyConnect",value:model.state.easyConnect);StateRow(title:"VPN 路由",value:model.state.vpn);StateRow(title:"公司 DNS",value:model.state.dns)}
            if !model.state.warning.isEmpty {Label(model.state.warning,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)}
            if !model.error.isEmpty {Text(model.error).font(.caption).foregroundStyle(.red)}
            Button(action:model.toggle) {Text(model.state.enabled ? "关闭协同模式":"开启协同模式").frame(maxWidth:.infinity)}.buttonStyle(.borderedProminent).disabled(model.busy)
            HStack {Button("打开 EasyConnect",action:model.openEasyConnect);Spacer();Button("重新检测") {model.refresh(diagnostics:true)}.disabled(model.busy)}
            Divider()
            HStack {Button("设置…") {model.show("设置")};Button("诊断…") {model.show("诊断")};Spacer();Button("退出",action:model.quit).disabled(model.busy)}.buttonStyle(.plain)
        }.padding(18).frame(width:370)

    }
}
struct SettingsView:View {
    @ObservedObject var model:Model
    @State private var domains=""
    @State private var dns=""
    @State private var probeHost=""
    @State private var directory=""
    @State private var client:ProxyClient = .verge
    var body:some View {
        Form {
            Section("公司网络") {
                Text("公司域名（每行一个，包含全部子域名）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text:$domains).font(.system(.body,design:.monospaced)).frame(height:95).border(.quaternary)
                TextField("公司 DNS（IPv4）",text:$dns)
                TextField("探测主机（可选，必须能经 VPN 访问）",text:$probeHost)
                Text("留空则检查首个公司域名；探测主机必须属于上面的域名范围。").font(.caption).foregroundStyle(.secondary)
                Text("仅在 VPN 路由就绪时生效；VPN 断开后恢复 Clash 原有解析。内网 DNS 查询失败不会转发到公共 DNS。").font(.caption).foregroundStyle(.secondary)
            }
            Section("代理客户端") {
                Picker("客户端",selection:$client) {ForEach(ProxyClient.allCases) {c in Text(c.name).tag(c)}}
                    .onChange(of:client) {value in directory=value == model.settings.client ? model.settings.clashDirectory : value.directory.path}
                Text("一次只协调所选客户端；不会自动启动、关闭或切换另一客户端。首次选择 FlClash 会准备其回环控制接口。").font(.caption).foregroundStyle(.secondary)
            }
            Section("应用") {
                Toggle("登录时启动 EasyClash",isOn:Binding(get:{model.login},set:{model.setLogin($0)}))
                Text("协同模式每次启动默认关闭。恢复守护仅负责清理遗留运行时配置。").font(.caption).foregroundStyle(.secondary)
                TextField("Clash 配置目录",text:$directory)
            }
            if model.state.enabled {Text("修改设置前，请先关闭协同模式。").foregroundStyle(.orange)}
            if !model.error.isEmpty {Text(model.error).foregroundStyle(.red)}
            HStack {Spacer();Button("保存") {var s=EasyClashCore.Settings();s.domains=domains.components(separatedBy:.newlines);s.dns=dns.trimmingCharacters(in:.whitespaces);s.clashDirectory=directory;s.client=client;s.probeHost=probeHost;model.save(s)}.buttonStyle(.borderedProminent).disabled(model.busy || model.state.enabled)}
        }.formStyle(.grouped).padding().onAppear {client=model.settings.client;domains=model.settings.domains.joined(separator:"\n");dns=model.settings.dns;probeHost=model.settings.probeHost;directory=model.settings.clashDirectory}
    }
}
struct DiagnosticsView:View {
    @ObservedObject var model:Model
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {VStack(alignment:.leading) {Text("网络诊断").font(.title2.bold());Text("分别检查 DNS、系统路由与 HTTPS；404 和登录跳转代表连接可达。").font(.caption).foregroundStyle(.secondary)};Spacer();if model.busy || model.checking {ProgressView().controlSize(.small)}}
            ScrollView {Text(model.state.report).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(12).background(.quaternary.opacity(0.35)).cornerRadius(8)}
            if !model.error.isEmpty {Text(model.error).foregroundStyle(.red)}
            HStack {Button("重新诊断") {model.refresh(diagnostics:true)}.disabled(model.busy);Button("复制脱敏诊断") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(model.state.report,forType:.string)};Spacer();Button("打开日志目录") {NSWorkspace.shared.open(Files.state)}}
        }.padding(22).frame(minWidth:580,minHeight:440)
    }
}
final class AppDelegate:NSObject,NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
@main struct EasyClashApp:App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model=Model()
    var body:some Scene {
        MenuBarExtra {MenuView(model:model)} label: {Image(systemName:model.state.active ? "checkmark.shield.fill" : model.state.enabled ? "exclamationmark.shield":"shield.lefthalf.filled").accessibilityLabel("EasyClash · "+model.state.mode)}.menuBarExtraStyle(.window)
    }
}
