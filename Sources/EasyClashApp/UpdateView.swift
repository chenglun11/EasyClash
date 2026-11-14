import SwiftUI
import AppKit
import EasyClashCore

struct UpdateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(UpdateProduct.allCases) { product in
                UpdateRow(product: product)
                if product == .easyClash { Divider() }
            }
        }.padding(24).frame(minWidth: 460, minHeight: 220)
    }
}

private struct UpdateRow: View {
    let product: UpdateProduct
    @State private var message = "正在检查…"
    @State private var busy = false
    @State private var available: ReleaseUpdate?
    @State private var installer: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(product.rawValue).font(.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("重新检查") { Task { await check() } }.disabled(busy)
            }
            Text(message).font(.callout).textSelection(.enabled)
            if let file = installer {
                if product == .netBird {
                    Text("安装可能短暂中断 VPN，请在方便时继续。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("在菜单中退出 EasyClash，再将镜像内的应用拖到原安装位置。").font(.caption).foregroundStyle(.secondary)
                }
                Button(product == .netBird ? "打开系统安装器…" : "打开安装镜像…") {
                    if !NSWorkspace.shared.open(file) { message = "系统未能打开文件，可在访达中查看。"; NSWorkspace.shared.activateFileViewerSelecting([file]) }
                }
            } else if let release = available {
                Button("下载更新包") { Task { await download(release) } }.disabled(busy)
            }
        }.task { await check() }
    }

    @MainActor private func check() async {
        guard !busy else { return }
        busy = true
        available = nil
        installer = nil
        message = "正在检查…"
        defer { busy = false }
        do {
            let selected = product
            let installed = try await Task.detached { try selected.installedVersion() }.value
            let release = try await ReleaseUpdate.latest(product)
            let newer = try installed.map { try release.isNewer(than: $0) } ?? true
            message = "\(installed.map { "已安装 " + $0 } ?? "未安装") · 最新稳定版 \(release.version)"
            if newer {
                if product == .netBird, let path = NetBirdConnection.installationPath,
                   path.contains("/Cellar/") {
                    message += "。此客户端由 Homebrew 管理，请用 brew upgrade netbird 更新。"
                } else { available = release }
            } else { message += installed == release.version ? " · 已是最新版" : " · 本机版本较新" }
        } catch { message = (error as? AppFailure)?.message ?? "无法完成版本检查，请检查网络后重试。" }
    }

    @MainActor private func download(_ release: ReleaseUpdate) async {
        guard !busy else { return }
        busy = true
        message = "正在下载并校验 \(release.version)…"
        defer { busy = false }
        do {
            installer = try await release.download()
            message = "\(release.name) 已通过校验。"
        } catch { message = (error as? AppFailure)?.message ?? "下载未完成，请重试。" }
    }
}
