# 安装、卸载与恢复

## 安装与使用

执行 `./scripts/build-app.sh`，把 `dist/EasyClash.app` 放到固定目录。构建仅 ad-hoc 签名，未公证，macOS 可能要求在系统设置中确认打开。

首次填写域名、DNS、探测主机和客户端。不要直接照抄 README 的保留示例地址。保持所选代理客户端 TUN 开启，手动连接 EasyConnect 后启用协同。无需管理员权限；EasyConnect 或代理客户端本身申请的系统权限由各客户端负责。

登录自启仅启动菜单栏应用，协同模式每次默认关闭。关闭协同模式不会断开 EasyConnect，也不影响客户端独立运行或订阅更新。

## 恢复

通常关闭协同模式或退出即可。异常退出后，恢复守护会在发现进程退出或心跳过期时清理；API 不可达时重试。

手动恢复（路径按实际安装位置调整）：

```sh
"/Applications/EasyClash.app/Contents/Helpers/EasyClashRecovery" recover
```

应用已被删除时，可使用留存的独立程序：

```sh
"$HOME/Library/Application Support/EasyClash/EasyClashRecovery" recover
```

不要通过反复开关 TUN 清理缓存，不要把旧备份整份覆盖回客户端。恢复失败时先检查客户端 API、文件访问权限和脱敏诊断；保留状态目录供本地恢复使用。

## 卸载

1. 关闭协同模式，在设置中关闭登录启动，然后退出应用。
2. 若希望撤销本应用准备的 FlClash 控制接口，在 FlClash 已正常退出时运行下面的可选命令。它仅撤销仍等于本应用写入值的字段，保留其他修改。
3. 执行 `uninstall`。成功后再删除 app；此命令不会删除备份或用户设置。

```sh
"/Applications/EasyClash.app/Contents/Helpers/EasyClashRecovery" undo-flclash-setup
"/Applications/EasyClash.app/Contents/Helpers/EasyClashRecovery" uninstall
```

如果已删除 app，改用状态目录内的恢复程序。确认恢复和卸载成功之后，可在 Finder 删除 `~/Library/Application Support/EasyClash` 中不再需要的本地数据。不要先删除状态目录，否则会丢失恢复所需的所有权记录。

## 发布前

源码发布清单不包含 `.build`、`dist`、Git 历史、用户状态、运行日志、图片或截图。仅发布生成并复核过的源码包；不要上传整个开发工作目录。打包脚本不代表内容已自动脱敏，新增测试和文档必须使用虚构示例。
