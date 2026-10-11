import Foundation

public struct FlClashSetupRecord:Codable {
    public let previous:String?
    public let owned:String
}
public enum FlClashSetup {
    public static let suite="com.follow.clash"
    public static let endpoint="127.0.0.1:9090"
    private static func running() throws -> Bool {
        let r=try Command.run("/bin/ps",["-axo","comm="],timeout:3)
        guard r.code==0 else {throw AppFailure("无法确认 FlClash 运行状态")}
        return r.out.split(separator:"\n").contains {$0.hasSuffix("/FlClash.app/Contents/MacOS/FlClash") || $0.hasSuffix("/FlClash.app/Contents/MacOS/FlClashCore")}
    }
    // One-time local controller preference, independent of any company DNS policy.
    // The caller explicitly selects FlClash or invokes prepare-flclash.
    public static func prepare(root:URL,suiteName:String=suite) throws {
        let lock=try FileLock(root.appendingPathComponent("flclash-setup.lock"));defer{withExtendedLifetime(lock){}}
        guard let defaults=UserDefaults(suiteName:suiteName),let text=defaults.string(forKey:"flutter.config"),var config=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],var patch=config["patchClashConfig"] as? [String:Any] else {throw AppFailure("未找到 FlClash 设置，请先安装并完成首次配置")}
        let previous=patch["external-controller"] as? String
        if let previous,!previous.isEmpty {_ = try ClientIdentity.loopbackPort(previous);return}
        if suiteName==suite,try running() {throw AppFailure("FlClash 正在运行，请在其基本配置中打开外部控制；无需重启或切换 TUN")}
        let recordURL=root.appendingPathComponent("flclash-controller.json")
        if !FileManager.default.fileExists(atPath:recordURL.path) {
            try Files.write(Data(text.utf8),to:root.appendingPathComponent("backups/flclash-pre-controller.json"))
            try Files.json(FlClashSetupRecord(previous:previous,owned:endpoint),to:recordURL)
        }
        if suiteName==suite,try running() {throw AppFailure("FlClash 刚刚启动，已停止离线设置写入；请在客户端内操作控制开关")}
        defaults.synchronize()
        guard defaults.string(forKey:"flutter.config")==text else {throw AppFailure("FlClash 设置已变化，请重试")}
        patch["external-controller"]=endpoint;config["patchClashConfig"]=patch
        let encoded=String(data:try JSONSerialization.data(withJSONObject:config),encoding:.utf8)!
        defaults.set(encoded,forKey:"flutter.config")
        guard defaults.synchronize() else {throw AppFailure("FlClash 设置未能保存")}
        Audit(root:root).event("flclash_controller_prepared")
    }
    public static func undo(root:URL,suiteName:String=suite) throws {
        let lock=try FileLock(root.appendingPathComponent("flclash-setup.lock"));defer{withExtendedLifetime(lock){}}
        let recordURL=root.appendingPathComponent("flclash-controller.json")
        guard FileManager.default.fileExists(atPath:recordURL.path) else {return}
        if suiteName==suite,try running() {throw AppFailure("先退出 FlClash 后再撤销控制接口设置，以免与客户端保存设置冲突")}
        let record=try Files.read(FlClashSetupRecord.self,recordURL)
        guard let defaults=UserDefaults(suiteName:suiteName),let text=defaults.string(forKey:"flutter.config"),var config=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],var patch=config["patchClashConfig"] as? [String:Any] else {throw AppFailure("无法读取 FlClash 设置")}
        if patch["external-controller"] as? String == record.owned {
            patch["external-controller"]=record.previous;config["patchClashConfig"]=patch
            if suiteName==suite,try running() {throw AppFailure("FlClash 刚刚启动，已停止离线设置写入；请在客户端内操作控制开关")}
        defaults.synchronize()
        guard defaults.string(forKey:"flutter.config")==text else {throw AppFailure("FlClash 设置已变化，请重试")}
            defaults.set(String(data:try JSONSerialization.data(withJSONObject:config),encoding:.utf8),forKey:"flutter.config")
            guard defaults.synchronize() else {throw AppFailure("FlClash 设置未能保存")}
        }
        try FileManager.default.removeItem(at:recordURL)
        Audit(root:root).event("flclash_controller_preparation_undone")
    }
}
