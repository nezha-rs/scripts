# Nezha Rust 一键安装脚本

这是 `nezha-rs/nezha-rs` Rust 重构版的 Debian 一键安装脚本仓库。脚本会从 GitHub Release 下载已经编译好的二进制文件，不需要在服务器上安装 Rust 或从源码构建。

Release 来源：

- Dashboard / Agent 二进制：https://github.com/nezha-rs/nezha-rs/releases
- 安装脚本：https://github.com/nezha-rs/scripts/blob/main/install.sh

## 支持环境

- Debian 12 或更新版本
- systemd
- root 用户，或已安装 `sudo` 的普通用户
- 支持的 Dashboard 架构：`amd64`、`arm64`、`s390x`
- 支持的 Agent 架构：`386`、`amd64`、`arm`、`arm64`、`loong64`、`riscv64`、`s390x`

## 一键安装命令

交互式菜单安装：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | sh
```

如果服务器无法直接访问 `raw.githubusercontent.com`，可以先下载再执行：

```bash
curl -fL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh -o nezha-rs.sh
chmod +x nezha-rs.sh
./nezha-rs.sh
```

## 安装 Dashboard

交互式安装：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | sh -s -- install
```

非交互式安装示例：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | \
  NZ_SITE_TITLE="Nezha" \
  NZ_HTTP_PORT="8008" \
  NZ_INSTALL_HOST="https://nezha.example.com" \
  NZ_AGENT_TLS="true" \
  NZ_AGENT_SECRET_KEY="replace-with-agent-secret" \
  NZ_ADMIN_USERNAME="admin" \
  NZ_ADMIN_PASSWORD="replace-with-admin-password" \
  sh -s -- install
```

安装完成后：

- 用户前台：`http://服务器IP:8008/`
- 管理后台：`http://服务器IP:8008/dashboard/`
- Agent gRPC 默认入口：`服务器IP:5555`

## 安装 Agent

在被监控机器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | \
  NZ_SERVER="nezha.example.com:5555" \
  NZ_CLIENT_SECRET="replace-with-agent-secret" \
  NZ_TLS="false" \
  sh -s -- install_agent
```

如果你的 Agent 通过 HTTPS/TLS 反代连接 Dashboard，把 `NZ_TLS` 改成 `true`：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | \
  NZ_SERVER="nezha.example.com:443" \
  NZ_CLIENT_SECRET="replace-with-agent-secret" \
  NZ_TLS="true" \
  sh -s -- install_agent
```

## 指定版本

默认安装 GitHub Release 的 `latest`。如需固定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | \
  NZ_VERSION="v0.1.0" \
  sh -s -- install
```

Agent 同理：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | \
  NZ_VERSION="v0.1.0" \
  NZ_SERVER="nezha.example.com:5555" \
  NZ_CLIENT_SECRET="replace-with-agent-secret" \
  sh -s -- install_agent
```

## 常用管理命令

先下载脚本：

```bash
curl -fL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh -o nezha-rs.sh
chmod +x nezha-rs.sh
```

Dashboard：

```bash
./nezha-rs.sh install              # 安装 Dashboard
./nezha-rs.sh modify_config       # 修改 Dashboard 配置
./nezha-rs.sh restart_and_update  # 下载最新 release 并重启 Dashboard
./nezha-rs.sh show_log            # 查看 Dashboard 日志
./nezha-rs.sh uninstall           # 卸载 Dashboard
```

Agent：

```bash
./nezha-rs.sh install_agent         # 安装 Agent
./nezha-rs.sh modify_agent_config   # 修改 Agent 配置
./nezha-rs.sh restart_agent_update  # 下载最新 release 并重启 Agent
./nezha-rs.sh restart_agent         # 重启 Agent
./nezha-rs.sh show_agent_log        # 查看 Agent 日志
./nezha-rs.sh uninstall_agent       # 卸载 Agent
```

## 配置文件位置

Dashboard：

- 程序：`/opt/nezha/dashboard/app`
- 配置：`/opt/nezha/dashboard/data/config.yaml`
- 环境变量：`/opt/nezha/dashboard/.env`
- 数据库：`/opt/nezha/dashboard/data/sqlite.db`
- systemd：`/etc/systemd/system/nezha-dashboard.service`

Agent：

- 程序：`/opt/nezha/agent/nezha-agent`
- 配置：`/opt/nezha/agent/config.yml`
- systemd：`/etc/systemd/system/nezha-agent.service`

## 环境变量

Dashboard 常用变量：

```bash
NZ_VERSION=latest
NZ_SITE_TITLE=Nezha
NZ_HTTP_PORT=8008
NZ_GRPC_BIND=0.0.0.0:5555
NZ_INSTALL_HOST=https://nezha.example.com
NZ_AGENT_TLS=false
NZ_AGENT_SECRET_KEY=replace-with-agent-secret
NZ_ADMIN_USERNAME=admin
NZ_ADMIN_PASSWORD=replace-with-admin-password
```

Agent 常用变量：

```bash
NZ_VERSION=latest
NZ_SERVER=nezha.example.com:5555
NZ_CLIENT_SECRET=replace-with-agent-secret
NZ_TLS=false
```

高级变量：

```bash
NZ_RELEASE_REPO=nezha-rs/nezha-rs
NZ_SKIP_DEBIAN_CHECK=1
```

## 如何推送到 GitHub

如果你在本地修改了这个脚本仓库，可以按下面流程推送：

```bash
git clone https://github.com/nezha-rs/scripts.git
cd scripts

# 修改 install.sh 或 README.md 后
git status
git add install.sh README.md .gitattributes
git commit -m "Update installer documentation"
git push origin main
```

如果这是一个新仓库，第一次推送可以这样做：

```bash
git init
git branch -M main
git remote add origin https://github.com/nezha-rs/scripts.git
git add install.sh README.md .gitattributes
git commit -m "Add installer script"
git push -u origin main
```

推送前建议检查脚本语法：

```bash
sh -n install.sh
```
