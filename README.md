# 如何构建 TSCode 镜像

## 方式一：GitHub Actions 流水线（推荐）

以下任一方式触发 `.github/workflows/build-docker-image.yml`：

- **自动**：`AI-Testing-Workbench/test-workbench-vscode` 的 `release.yml` 在 `main` 分支（或 `v*` tag）构建成功后，会自动调度本流水线，并传入对应的服务端构建 run id（详见下方“联动调度”）
- **手动**：推送 `main` 分支，或在 Actions 页面手动触发（可选填 `server_run_id` 指定服务端构建）

流水线执行：

1. 从 [`AI-Testing-Workbench/test-workbench-vscode`](https://github.com/AI-Testing-Workbench/test-workbench-vscode) 定位服务端构建（默认取 `release.yml` 在 `main` 分支最近一次成功构建，被调度时使用上游传入的 run id）
2. 下载其 `vscode-server-linux-x64` artifact
3. 下载本仓库 `vsix/` 目录下（可选）提交的插件，随镜像一并打包
4. 构建 `testagent/tscode-server:latest` 镜像
5. 通过 `docker save | gzip` 导出为 `tscode-server.tar.gz`，并上传到本次运行（`tscode-server-image` artifact，保留 7 天）供直接下载

### 首次使用需要配置

在两个仓库分别配置密钥：

**① 本仓库（tscode-server-docker）`Settings -> Secrets and variables -> Actions`：**

| 名称                    | 说明                                                                                                                                                                  |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TSCODE_ARTIFACT_PAT` | 用于跨仓库读取 Actions artifact 的 PAT，需对`AI-Testing-Workbench/test-workbench-vscode` 拥有 **Actions: Read** 权限（public 仓库拉取 artifact 同样需要鉴权） |

**② 上游仓库（test-workbench-vscode）`Settings -> Secrets and variables -> Actions`：**

| 名称                | 说明                                                                                                                                                                             |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DOCKER_REPO_PAT` | 用于调度本流水线的 PAT，需对`AI-Testing-Workbench/tscode-server-docker` 拥有 **Workflow** 写入权限。未配置时上游不会调度本仓库（release 流水线不受影响，仅跳过调度步骤） |

### 联动调度

`test-workbench-vscode/.github/workflows/release.yml` 在 `build-linux` 成功后新增了 `trigger-docker-build` job，会通过 `workflow_dispatch`（携带 `server_run_id`）自动触发本仓库流水线，确保镜像与服务端构建一一对应，无需手动等待。

### 插件（vsix）打包

将需要打包的插件放入本仓库 `vsix/` 目录并提交（该目录已被 `.gitignore` 排除全局 `*.vsix` 规则之外），流水线会自动复制进构建上下文。若不需要打包插件，可以忽略此目录。

## 方式二：本地手动构建

1. 在根目录下放置名为 `vscode-server-linux-x64.tar.gz` 的 TSCode 服务端压缩包
2. (可选) 在根目录下直接放置额外需要打包的 `vsix` 插件
3. (可选) 如需离线内置 ripgrep，确保 `builtin/ripgrep-15.1.0-x86_64-unknown-linux-musl.tar.gz` 存在（Dockerfile 会将其解包安装，避免容器运行期联网下载）
4. 运行如下命令进行构建

```shell
docker build -t testagent/tscode-server:latest .
```

4. 运行如下命令导出镜像

```shell
docker save -o tscode-server.tar testagent/tscode-server:latest
$in="tscode-server.tar"; $out="$in.gz"; $src=[IO.File]::OpenRead($in); $dst=[IO.File]::Create($out); $gz=[IO.Compression.GZipStream]::new($dst,[IO.Compression.CompressionMode]::Compress); $src.CopyTo($gz); $gz.Dispose(); $dst.Dispose(); $src.Dispose()
```


## OpenSandbox Chrome 沙盒模式

镜像内置 Google Chrome 与 TigerVNC，供 OpenSandbox 提供带浏览器的沙盒（基座仍为 Ubuntu 24.04，未回退 Debian）。

- **Chrome**：官方 deb 安装的真 Chrome（Ubuntu apt 无 chromium 二进制包，仅有指向 snap 的过渡包）。Chrome ≥130 已停用 `--remote-debugging-address`，DevTools 固定只监听 `127.0.0.1:9222`；启动时用 `socat TCP-LISTEN:9922 TCP:127.0.0.1:9222` 暴露为 `0.0.0.0:9922`，容器外按 IP 访问。注意 Chrome 只接受 Host 为 IP 或 localhost，用域名访问会返回 `HTTP 500 Host header is specified and is not an IP address or localhost`
- **VNC**：`Xtigervnc :1`，无密码，端口 `5901`
- **noVNC**：`websockify --web=/usr/share/novnc 6080 localhost:5901`，端口 `6080`，供宿主机浏览器实时查看容器内 Chrome
- 启动脚本：`/chrome.sh`（对应仓库根目录 `chrome.sh`）

默认**不启动** Chrome。需要浏览器时，在创建容器/Sandbox 时注入环境变量 `TESTAGENT_ENABLE_CHROME=1`（`true`/`yes`/`on` 亦可），`/root/.start.sh` 检测到后会在后台拉起 VNC 与 Chrome，sshd 照常作为主进程运行；启动日志见容器内 `/tmp/vnc.log`、`/tmp/chrome.log`、`/tmp/socat.log`、`/tmp/novnc.log`。

接入 OpenSandbox 时参照 `examples/chrome`、`examples/desktop`，通过 execd 端点访问：

```text
SSH:      <endpoint>/proxy/22
VNC:      <endpoint>/proxy/5901
DevTools: <endpoint>/proxy/9922/json
noVNC:    <endpoint>/proxy/6080/vnc.html?host=<execd_host>&port=<execd_port>&path=proxy/6080
```

例如 execd 端点为 `127.0.0.1:50365`，宿主机浏览器打开：
`http://127.0.0.1:50365/proxy/6080/vnc.html?host=127.0.0.1&port=50365&path=proxy/6080`
即可实时看到容器内 Chrome 的自动化执行画面。

注意：`dl.google.com` 需可访问（GitHub Actions 正常，国内手动构建若超时可自备 Google Chrome deb 镜像）。

## 注意事项
在docker作为容器引擎（行外全流程测试），需要在通过sandbox创建好容器后，需要在宿主机执行下 connect-fix.sh 脚本。k8s作为背后引擎（生产环境）则不需要

## 旧式 TLS 重新协商（unsafe legacy renegotiation）

部分代理或旧服务端在 TLS 握手中不发送 RFC 5746 扩展，OpenSSL 3 默认拒绝此类连接。表现为在 TSCode 里下载插件、或扩展发起 HTTPS 请求时报：

```text
write EPROTO ... SSL routines:final_renegotiate:unsafe legacy renegotiation disabled
```

镜像分两条路径启用 `UnsafeLegacyRenegotiation`（即 `SSL_OP_LEGACY_SERVER_CONNECT`）作为兜底：

- **系统 OpenSSL 工具（curl/git/openssl）**：内置 `/etc/ssl/tscode-openssl.cnf`，通过 sshd `SetEnv` 注入 `OPENSSL_CONF`。
- **Node（tscode-server、扩展宿主）**：Node 不会把 OpenSSL 的 `[system_default]` 应用到自身的 `SSL_CTX`，因此改用 `tscode-tls-legacy-renegotiation.cjs` 预加载补丁，经 `NODE_OPTIONS=--require` 注入，直接在 `tls.connect`/`tls.createSecureContext` 的 `secureOptions` 上补该 SSL_OP 位。

两条路径都由 `start.sh` 通过 sshd `SetEnv` 下发，仅影响 SSH 会话派生的进程。注意：这会略微降低 TLS 安全性（允许不安全的旧式重新协商），仅用于兼容无法升级的旧服务端/代理；若网络环境已不再需要，删除 Dockerfile 中的 `tscode-openssl.cnf` 生成与补丁 COPY，以及 `start.sh` 里的 `OPENSSL_CONF`/`NODE_OPTIONS` 注入即可。