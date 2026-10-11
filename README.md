# EasyClash

让 macOS 上的 Clash TUN 与 EasyConnect 协同工作的菜单栏工具。支持选择 Clash Verge Rev 或 FlClash，使用 Swift + SwiftUI 实现。

**当前为预发布版本。** VPN 的路由方式、客户端版本和 DNS 配置会影响兼容性，目前不承诺支持所有企业 VPN 环境。应用不是上述客户端的官方组件，不包含 VPN、代理内核或订阅。

## 做什么

- 保持 Clash TUN 开启，区分 EasyConnect 进程存在与 VPN 路由就绪。
- 为指定域名生成独占公司 DNS 策略、fake-IP 排除和 DIRECT 规则；对 VPN 网段绑定检测到的接口。
- VPN 未就绪时恢复原有解析；启用期间公司 DNS 查询不与公共 DNS 竞速。
- 检查 DNS、路由与 HTTPS；HTTP 404、登录重定向均可代表连接已建立。
- 通过运行时覆盖、标记与恢复守护处理断线、配置更新和异常退出。
- 默认无 Dock 图标，手动启动；登录启动可选。

不会自动处理 VPN 凭据、断开 VPN、开关 TUN 或重启代理客户端。协同配置不写入订阅、Merge 或扩展脚本。

## 快速开始

1. macOS 13 或更新版本，安装 Xcode Command Line Tools 和支持 Swift 5.10 的工具链。
2. 在源码目录执行 `./scripts/build-app.sh`，生成 `dist/EasyClash.app`。构建产物仅临时签名（ad-hoc），没有 Developer ID 签名或公证。
3. 把应用放到固定位置，例如 `/Applications`，首次启动进入“设置”。
4. 填写自己的公司域名、公司 DNS IPv4、可经 VPN 访问的 HTTPS 探测主机。所有网络字段默认为空，没有预置公司信息。
5. 选择客户端，保持该客户端 TUN 开启、规则模式，建议系统代理/PAC 关闭。在 EasyConnect 内自行完成登录，然后开启协同模式。

示例仅用于说明：域名 `corp.example.com`、DNS `192.0.2.53`、探测主机 `portal.corp.example.com`。这些是保留示例地址，不能用于实际连接。探测主机须属于配置的域名范围，解析出的 IPv4 地址须经 VPN 路由；留空时使用排序后的首个公司域名。

FlClash 使用回环控制 API。若 FlClash 未运行且接口为空，首次保存设置会备份并仅设置其外部控制字段为 `127.0.0.1:9090`；如果已运行，请在 FlClash 内打开外部控制。应用不会为了此设置重启 FlClash，端口冲突时会拒绝操作。

## 限制与验证

- 当前针对 IPv4、TCP DNS 和带独立 DNS 主机路由的 EasyConnect 环境；VPN DNS 必须支持 TCP/53。
- 需要 Clash DNS 开启、fake-IP filter 的 blacklist 模式和可用控制 API。
- 一次只协调一个客户端，不自动处理同时开启两个代理 TUN 的情况。
- 不迁移其他工具创建的 DNS 转发器或扩展脚本。已有定制规则应由其所有者清理；关闭协同后会回到这些原有配置。
- 恢复基于客户端最新生成的配置文件，保留可读取的通用运行参数和节点选择；仅在控制 API 中临时改动、未写入配置源的任意规则或 DNS 策略，无法保证保留。
- “检查通过”仅表示配置的探测主机通过检查，不代表所有公司服务都已验证。

见 [架构与恢复](docs/ARCHITECTURE.md)、[安装、卸载和恢复](docs/OPERATIONS.md)、[测试](docs/TESTING.md)。测试命令：`./scripts/test.sh`。集成测试只运行隔离的内核实例，TUN 关闭，不使用真实订阅或公司网络。

## 隐私与反馈

请使用应用的“复制脱敏诊断”提交问题。不要上传完整配置、订阅、状态目录、备份、真实域名、DNS 地址、账号或截图中的公司信息。没有遥测或自动上传功能；配置的探测主机会收到 DNS/HTTPS 检查流量。

发布源码请运行 `python3 scripts/package-source.py`，按固定清单生成源码包，排除构建目录、状态数据和 Git 历史。发布前仍需人工审核内容，清单不能自动识别后来新增的敏感字符串。

## 许可证

MIT，见 [LICENSE](LICENSE)。Yams 依赖及其 MIT 许可见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Clash Verge Rev、FlClash 和 EasyConnect 的名称归各自所有者；本项目不重新分发它们。
