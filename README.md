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

| 名称 | 说明 |
| --- | --- |
| `TSCODE_ARTIFACT_PAT` | 用于跨仓库读取 Actions artifact 的 PAT，需对 `AI-Testing-Workbench/test-workbench-vscode` 拥有 **Actions: Read** 权限（public 仓库拉取 artifact 同样需要鉴权） |

**② 上游仓库（test-workbench-vscode）`Settings -> Secrets and variables -> Actions`：**

| 名称 | 说明 |
| --- | --- |
| `DOCKER_REPO_PAT` | 用于调度本流水线的 PAT，需对 `AI-Testing-Workbench/tscode-server-docker` 拥有 **Workflow** 写入权限。未配置时上游不会调度本仓库（release 流水线不受影响，仅跳过调度步骤） |

### 联动调度

`test-workbench-vscode/.github/workflows/release.yml` 在 `build-linux` 成功后新增了 `trigger-docker-build` job，会通过 `workflow_dispatch`（携带 `server_run_id`）自动触发本仓库流水线，确保镜像与服务端构建一一对应，无需手动等待。

### 插件（vsix）打包

将需要打包的插件放入本仓库 `vsix/` 目录并提交（该目录已被 `.gitignore` 排除全局 `*.vsix` 规则之外），流水线会自动复制进构建上下文。若不需要打包插件，可以忽略此目录。

## 方式二：本地手动构建

1. 在根目录下放置名为 `vscode-server-linux-x64.tar.gz` 的 TSCode 服务端压缩包
2. (可选) 在根目录下直接放置额外需要打包的 `vsix` 插件
3. 运行如下命令进行构建

```shell
docker build -t testagent/tscode-server:latest .
```

4. 运行如下命令导出镜像

```shell
docker save -o tscode-server.tar testagent/tscode-server:latest
$in="tscode-server.tar"; $out="$in.gz"; $src=[IO.File]::OpenRead($in); $dst=[IO.File]::Create($out); $gz=[IO.Compression.GZipStream]::new($dst,[IO.Compression.CompressionMode]::Compress); $src.CopyTo($gz); $gz.Dispose(); $dst.Dispose(); $src.Dispose()
```
