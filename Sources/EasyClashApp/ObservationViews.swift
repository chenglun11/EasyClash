import SwiftUI
import AppKit
import EasyClashCore

final class ObservationModel:ObservableObject {
    @Published var history=TrafficHistory()
    @Published var configuration=ConfigInspection()
    @Published var sampling=true
    @Published var loadingTraffic=false
    @Published var loadingConfig=false
    @Published var trafficError=""
    @Published var checked:Date?
    private let queue=DispatchQueue(label:"com.easyclash.observation",qos:.utility)
    private var generation=0
    private var identity=""
    private var configIdentity=""
    private var configGeneration=0
    @Published var configSource="尚未读取"
    private func settingsKey(_ settings:EasyClashCore.Settings) -> String {
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(settings)).map(Files.hash) ?? settings.client.rawValue+settings.clashDirectory
    }
    func refreshTraffic(settings:EasyClashCore.Settings) {
        guard sampling,!loadingTraffic else {return}
        let next=settingsKey(settings)
        if identity != next {clear();identity=next}
        loadingTraffic=true;let token=generation
        queue.async {
            let result=Result {try ObservationReader(settings:settings).traffic()}
            DispatchQueue.main.async {
                self.loadingTraffic=false
                guard token==self.generation,self.sampling else {return}
                switch result {
                case .success(let rows):self.history.update(rows);self.checked=Date();self.trafficError=""
                case .failure:self.trafficError="无法读取连接；保留上次采样，当前状态未知。请检查所选客户端的控制接口。"
                }
            }
        }
    }
    func clear() {generation+=1;history.clear();checked=nil;trafficError=""}
    func pause() {sampling.toggle();generation+=1}
    func refreshConfig(settings:EasyClashCore.Settings) {
        let next=settingsKey(settings)
        if loadingConfig && configIdentity==next {return}
        if configIdentity != next {configuration=ConfigInspection()}
        configIdentity=next;configGeneration+=1;let token=configGeneration
        configSource=settings.client.name;loadingConfig=true
        queue.async {
            var result:ConfigInspection
            do {result=try ObservationReader(settings:settings).configuration()}
            catch {
                result=ConfigInspection();result.status="控制 API 不可用；磁盘配置不代表运行时状态。"
                if let base=try? Files.yaml(settings.configURL) {result.disk=ConfigInspection.project(base,domains:settings.domains)}
                else {result.error="磁盘配置也不可读，请检查设置中的目录。"}
                result.events=ObservationReader.events(root:Files.state)
            }
            DispatchQueue.main.async {guard token==self.configGeneration else {return};self.configuration=result;self.loadingConfig=false}
        }
    }

}

private func copyObservation(_ text:String) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}
struct TrafficView:View {
    @ObservedObject var model:Model
    @ObservedObject var observation:ObservationModel
    @State private var search=""
    @State private var showDetails = false
    @State private var companyOnly=true
    @State private var selected:String?
    private let ticker=Timer.publish(every:2,on:.main,in:.common).autoconnect()
    private var rows:[TrafficRecord] {
        observation.history.records.filter {row in
            (!companyOnly || row.company) && (search.isEmpty || [row.host,row.destination,row.process,row.path.rawValue].contains {$0.localizedCaseInsensitiveContains(search)})
        }
    }
    private var selection:TrafficRecord? {rows.first {$0.id==selected}}
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading,spacing:4) {Text("连接日志").font(.title2.bold());Text("查看公司域名、命中规则与出口证据").foregroundStyle(.secondary)}
                Spacer()
                if observation.loadingTraffic {ProgressView().controlSize(.small)}
                Button(observation.sampling ? "暂停":"继续",action:observation.pause)
                Button("清空",action:observation.clear)
            }
            HStack {
                if showDetails { TextField("搜索域名、IP、进程或出口", text:$search).textFieldStyle(.roundedBorder) }
                Spacer()
                Toggle("仅公司相关", isOn:$companyOnly)
                Toggle("显示本机明细", isOn:$showDetails)
            }.toggleStyle(.checkbox).onChange(of:showDetails) { visible in if !visible { search="" } }
            if !observation.trafficError.isEmpty {Label(observation.trafficError,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange)}
            Table(rows,selection:$selected) {
                TableColumn("目标") {r in VStack(alignment:.leading,spacing:3) {Text(showDetails ? (r.host.isEmpty ? "未提供域名":r.host) : (r.company ? "公司相关连接" : "其他连接")).lineLimit(1);if showDetails { Text(r.destination.isEmpty ? "IP 未提供":r.destination).font(.caption).foregroundStyle(.secondary) }}}.width(min:160,ideal:230)
                TableColumn("出口") {r in Text(r.path.rawValue).foregroundStyle(r.path == .vpnBound || r.path == .vpnRoute ? Color.green:Color.primary)}.width(min:120,ideal:150)
                TableColumn("命中规则") {r in Text(showDetails ? r.rule : (r.rule.components(separatedBy:" · ").first ?? "其他规则")).lineLimit(2)}.width(min:100,ideal:170)
                TableColumn("进程") {r in Text(showDetails && !r.process.isEmpty ? r.process : "—")}.width(min:60,ideal:90)
                TableColumn("采样") {r in VStack(alignment:.leading) {Text(r.seen,style:.time);Text(r.present ? "上次存在":"已不在采样中").font(.caption).foregroundStyle(.secondary)}}.width(min:90,ideal:110)
            }.overlay {
                if rows.isEmpty {VStack(spacing:8) {Image(systemName:"network").font(.largeTitle).foregroundStyle(.secondary);Text(observation.history.records.isEmpty ? "等待连接记录":"没有匹配的连接");Text("保持此页打开，再访问目标网站。短连接可能在两次采样之间结束。").font(.caption).foregroundStyle(.secondary)}.allowsHitTesting(false)}
            }
            GroupBox("路由证据") {
                VStack(alignment:.leading,spacing:6) {
                    Text(selection?.evidence ?? "选中一条连接查看依据。DIRECT 只表示直连，并不自动等于公司 VPN。").frame(maxWidth:.infinity,alignment:.leading)
                    if let row=selection {Text("↑ \(ByteCountFormatter.string(fromByteCount:row.upload,countStyle:.binary))  ↓ \(ByteCountFormatter.string(fromByteCount:row.download,countStyle:.binary))").font(.caption).foregroundStyle(.secondary)}
                }.textSelection(.enabled).padding(5)
            }
            HStack {Text("\(rows.count) 条 / 最多保留 500 条").font(.caption).foregroundStyle(.secondary);if let checked=observation.checked {Text(checked,style:.time).font(.caption).foregroundStyle(.secondary)};Spacer();Button("复制脱敏摘要") {copyObservation(observation.history.redactedReport)}}
            Text("此页可见时约每 2 秒采样；不抓包、不记录 URL 路径或凭据，仅保存在内存中。不是完整 DNS 查询日志；失败请求可能尚未进入连接列表。暂停或读取失败时，记录不代表实时状态。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)

        }.padding(22).frame(minWidth:800,minHeight:570)
        .onDisappear { showDetails = false; search = "" }
        .onAppear {observation.refreshTraffic(settings:model.settings)}
        .onChange(of:model.settings) {_ in observation.clear();observation.refreshTraffic(settings:model.settings)}
        .onReceive(ticker) {_ in if NSApp.windows.contains(where:{$0.title=="EasyClash · 连接日志" && $0.isVisible && !$0.isMiniaturized}) {observation.refreshTraffic(settings:model.settings)}}
    }
}
struct ConfigurationView:View {
    @ObservedObject var model:Model
    @ObservedObject var observation:ObservationModel
    @State private var section=0
    @State private var showDetails = false
    private var data:ConfigInspection {observation.configuration}
    private var lines:[ConfigLine] {switch section {case 0:return data.disk;case 1:return data.planned;case 2:return data.rules;default:return data.events}}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {VStack(alignment:.leading,spacing:4) {Text("Clash 配置").font(.title2.bold());Text(observation.configSource+" · 公司网络相关修改").foregroundStyle(.secondary)};Spacer();if observation.loadingConfig {ProgressView().controlSize(.small)};Button("刷新") {observation.refreshConfig(settings:model.settings)}.disabled(observation.loadingConfig)}
            HStack(alignment:.top) {Label(data.status,systemImage:"info.circle").font(.callout).fixedSize(horizontal:false,vertical:true);Spacer();if !observation.loadingConfig {Text(data.checked,style:.time).font(.caption).foregroundStyle(.secondary)}}
            Picker("配置来源",selection:$section) {Text("磁盘配置").tag(0);Text("协同计划").tag(1);Text("实际规则").tag(2);Text("修改记录").tag(3)}.pickerStyle(.segmented)
            Toggle("显示本机明细", isOn:$showDetails).toggleStyle(.checkbox)
            ScrollView {
                LazyVStack(alignment:.leading,spacing:0) {
                    ForEach(lines) {line in VStack(alignment:.leading,spacing:7) {Text(showDetails ? line.field : line.field.components(separatedBy:" · ").first ?? "配置项").font(.system(.callout,design:.monospaced)).foregroundStyle(.secondary);Text(showDetails || section == 3 ? line.value : line.publicValue).font(.body).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.padding(14);Divider()}
                    if lines.isEmpty {Text(section==3 ? "暂无修改记录":"此来源暂无公司相关条目").foregroundStyle(.secondary).padding(30).frame(maxWidth:.infinity)}
                }
            }.background(.quaternary.opacity(0.25)).cornerRadius(10)
            if !data.error.isEmpty {Text(data.error).font(.caption).foregroundStyle(.orange)}
            Text(section==0 ? "这是当前生成文件中的相关字段，不等同于内核完整 DNS 状态；订阅、节点和密钥均不展示。":section==1 ? "这里只预览开启协同时的计划。页面不会应用、热加载或回滚配置；修改域名和 DNS 请进入协同设置。":section==2 ? "规则通过控制 API 读取，编号反映全局顺序。运行时标记只能证明覆盖存在；本页未主动发送 DNS / HTTPS 探测。":"修改记录来自 EasyClash 的本机事件日志。请在实际规则中查看当前生效情况。").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {Button("编辑协同设置…") {model.show("设置")};Button("打开备份目录") {let url=Files.state.appendingPathComponent("backups");NSWorkspace.shared.open(FileManager.default.fileExists(atPath:url.path) ? url:Files.state)};Spacer();Button("复制脱敏摘要") {copyObservation(data.redactedReport)}}
        }.padding(22).frame(minWidth:740,minHeight:540).onDisappear { showDetails = false }.onAppear {observation.refreshConfig(settings:model.settings)}.onChange(of:model.settings) {_ in observation.refreshConfig(settings:model.settings)}
    }
}
