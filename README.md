# Nezha Rust 一键安装脚本

这是 `nezha-rs/nezha-rs` Rust 重构版的 Debian 一键安装脚本仓库。脚本会从 GitHub Release 下载已经编译好的二进制文件，不需要在服务器上安装 Rust 或从源码构建。

从这一版起，Dashboard 与 Agent 的安装脚本已拆分为两个独立脚本：

- `install-dashboard.sh` — Dashboard 安装 / 配置 / 卸载 / 升级
- `install-agent.sh` — Agent 安装 / 配置 / 重启 / 卸载 / 升级
- `lib/common.sh` — 两个脚本共用的工具库（自动通过同目录或 `NZ_SCRIPT_BASE_URL` 拉取）

`install.sh` 保留为**兼容入口**：它会把旧版的子命令（如 `install_agent`、`uninstall_dashboard`）转发到新脚本，老的一键命令依然可用。

Release 来源：

- Dashboard / Agent 二进制：https://github.com/nezha-rs/nezha-rs/releases
- 安装脚本：https://github.com/nezha-rs/scripts

## 支持环境

- Debian 12 或更新版本
- systemd
- root 用户，或已安装 `sudo` 的普通用户
- 支持的 Dashboard 架构：`amd64`、`arm64`、`s390x`
- 支持的 Agent 架构：`386`、`amd64`、`arm`、`arm64`、`loong64`、`riscv64`、`s390x`

## 安装 Dashboard

交互式菜单：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | sh
```

直接安装：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | sh -s -- install
```

非交互式安装示例：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | \
  NZ_SITE_TITLE="Nezha" \
  NZ_HTTP_PORT="8008" \
  NZ_GRPC_BIND="0.0.0.0:5555" \
  NZ_INSTALL_HOST="https://nezha.example.com" \
  NZ_AGENT_TLS="true" \
  NZ_AGENT_SECRET_KEY="replace-with-agent-secret" \
  NZ_ADMIN_USERNAME="admin" \
  NZ_ADMIN_PASSWORD="replace-with-admin-password" \
  sh -s -- install
```

安装完成后：

- Dashboard 用户前台：`http://服务器IP:8008/`
- Dashboard 管理后台：`http://服务器IP:8008/dashboard/`
- Agent gRPC 接入入口：`服务器IP:5555`

Dashboard 的 Web 端口和 Agent 的 gRPC 端口是分开的：

```bash
NZ_HTTP_PORT=8008          # Dashboard HTTP 面板端口
NZ_GRPC_BIND=0.0.0.0:5555  # Agent gRPC 接入端口
```

管理员密码不会回显到终端或 journal，安装结束后从 `.env` 读取：

```bash
sudo grep ^NZ_ADMIN_PASSWORD= /opt/nezha/dashboard/.env
```

## 安装 Agent

在被监控机器上执行。`NZ_SERVER` 填的是 Dashboard 的 Agent gRPC 接入地址，**不是** Dashboard 的 HTTP 面板地址。

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh | \
  NZ_SERVER="nezha.example.com:5555" \
  NZ_CLIENT_SECRET="replace-with-agent-secret" \
  NZ_TLS="false" \
  sh -s -- install
```

如果 Agent 通过 HTTPS/TLS 反代连接 Dashboard，把 `NZ_TLS` 改成 `true`：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh | \
  NZ_SERVER="nezha.example.com:443" \
  NZ_CLIENT_SECRET="replace-with-agent-secret" \
  NZ_TLS="true" \
  sh -s -- install
```

Dashboard 后台「Agent 一键安装命令」按钮生成的命令已直接指向 `install-agent.sh`，复制粘贴即可。

## 卸载

Dashboard：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | sh -s -- uninstall
```

Agent：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh | sh -s -- uninstall
```

跳过确认：

```bash
NZ_YES=1 ./nezha-dashboard.sh uninstall
NZ_YES=1 ./nezha-agent.sh uninstall
```

卸载会停止并禁用对应 service，删除：

- Dashboard：`/opt/nezha/dashboard`、`/etc/systemd/system/nezha-dashboard.service`
- Agent：`/opt/nezha/agent`、`/etc/systemd/system/nezha-agent.service`（通过 `nezha-agent service uninstall` 注销）

## 指定版本

默认安装 GitHub Release 的 `latest`。如需固定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | \
  NZ_VERSION="v0.1.0" sh -s -- install
```

Agent 同理：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh | \
  NZ_VERSION="v0.1.0" \
  NZ_SERVER="nezha.example.com:5555" \
  NZ_CLIENT_SECRET="replace-with-agent-secret" \
  sh -s -- install
```

## 本地下载后管理

```bash
curl -fL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh -o nezha-dashboard.sh
curl -fL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh -o nezha-agent.sh
chmod +x nezha-dashboard.sh nezha-agent.sh
```

两份脚本会自动在同目录（或 `NZ_SCRIPT_BASE_URL`）寻找 / 拉取 `lib/common.sh`，无需手动下载。如果离线部署，可以同时下载：

```bash
mkdir -p lib
curl -fL https://raw.githubusercontent.com/nezha-rs/scripts/main/lib/common.sh -o lib/common.sh
```

Dashboard 子命令：

```bash
./nezha-dashboard.sh                    # 菜单
./nezha-dashboard.sh install            # 安装
./nezha-dashboard.sh modify_config      # 修改配置
./nezha-dashboard.sh restart_and_update # 下载最新 release 并重启
./nezha-dashboard.sh show_log           # 查看日志
./nezha-dashboard.sh uninstall          # 卸载
./nezha-dashboard.sh update_script      # 更新脚本本身
```

Agent 子命令：

```bash
./nezha-agent.sh                        # 菜单
./nezha-agent.sh install                # 安装
./nezha-agent.sh modify_config          # 修改配置
./nezha-agent.sh restart_and_update     # 下载最新 release 并重启
./nezha-agent.sh restart                # 重启
./nezha-agent.sh show_log               # 查看日志
./nezha-agent.sh uninstall              # 卸载
./nezha-agent.sh update_script          # 更新脚本本身
```

## 兼容入口 `install.sh`

旧的一键命令仍然可用，会自动转发到新脚本：

```bash
# 等同于 install-dashboard.sh install
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | sh -s -- install

# 等同于 install-agent.sh install
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | sh -s -- install_agent

# 等同于 install-dashboard.sh uninstall
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | sh -s -- uninstall_dashboard
```

`install.sh` 已不再包含具体逻辑，只是一个调度层。新部署建议直接使用 `install-dashboard.sh` / `install-agent.sh`。

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
- systemd：通过 `nezha-agent service install` 注册

## 环境变量

Dashboard 常用变量：

```bash
NZ_VERSION=latest
NZ_SITE_TITLE=Nezha
NZ_HTTP_PORT=8008          # Dashboard HTTP 面板端口
NZ_GRPC_BIND=0.0.0.0:5555  # Agent gRPC 接入端口
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
NZ_SCRIPT_BASE_URL=https://raw.githubusercontent.com/nezha-rs/scripts/main
NZ_COMMON_LIB=/path/to/common.sh   # 离线/私有部署时显式指定共用库
NZ_SKIP_DEBIAN_CHECK=1
NZ_YES=1                            # 跳过卸载确认
```

## 如何推送到 GitHub

如果你在本地修改了这个脚本仓库，可以按下面流程推送：

```bash
git clone https://github.com/nezha-rs/scripts.git
cd scripts

git status
git add install.sh install-dashboard.sh install-agent.sh lib/common.sh README.md .gitattributes
git commit -m "Split installer into dashboard and agent scripts"
git push origin main
```

推送前检查脚本语法：

```bash
sh -n install.sh
sh -n install-dashboard.sh
sh -n install-agent.sh
sh -n lib/common.sh
```
