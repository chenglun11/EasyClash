import Foundation
import EasyClashCore

let args=Array(CommandLine.arguments.dropFirst())
let verb=args.first ?? "inspect"
let root:URL = {if let i=args.firstIndex(of:"--state"),args.count>i+1 {return URL(fileURLWithPath:args[i+1])};return Files.state}()
let testSocket:String? = {if root != Files.state,let i=args.firstIndex(of:"--socket"),args.count>i+1 {return args[i+1]};return nil}()
let coordinator=Coordinator(root:root)
do {
    switch verb {
    case "watch":
        while true {do {_ = try Recovery.restore(root:root,explicitSocket:testSocket)} catch {Audit(root:root).event("recovery_retry")};Thread.sleep(forTimeInterval:3)}
    case "recover": _ = try Recovery.restore(root:root,force:true);print("运行时恢复完成")
    case "uninstall":try Recovery.uninstall(root:root);print("恢复守护已卸载；备份保留")
    case "inspect":print(coordinator.inspect(diagnostics:args.contains("--diagnostics")).report)
    case "prepare-flclash":try FlClashSetup.prepare(root:root);print("FlClash 回环控制接口已准备；未启动客户端或修改 TUN")
    case "undo-flclash-setup":try FlClashSetup.undo(root:root);print("已按字段撤销 FlClash 控制接口准备，保留其他设置")
    default:throw AppFailure("用法：EasyClashRecovery inspect [--diagnostics] | recover | uninstall | prepare-flclash | undo-flclash-setup")
    }
} catch {print((error as? AppFailure)?.message ?? "操作失败；请检查路径、权限和恢复记录");exit(1)}
