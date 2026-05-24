# 哪吒监控（Rust 版）一键安装教程

这是 [`nezha-rs/nezha-rs`](https://github.com/nezha-rs/nezha-rs) Rust 重构版的 Debian 一键安装脚本。

脚本会从 GitHub Release 下载已经编译好的二进制文件，**不需要在服务器上装 Rust，也不需要从源码编译**。整个安装流程跟着提示按回车就能跑完。

> 如果你是第一次用，建议从头读到 "第三步" 就够了，后面是查阅用的。

---

## 0. 你需要准备什么

- 一台跑 **Dashboard 面板** 的服务器：用来收数据、提供网页后台。
  - 系统：Debian 12 或更新版本
  - 架构：`amd64` / `arm64` / `s390x`
  - 一个对外的端口（默认 HTTP `8008`，Agent 接入 `5555`）
- 一台或多台**被监控的服务器**（叫做 Agent）：跑你的业务的机器。
  - 系统：Debian 12 或更新版本
  - 架构：`386` / `amd64` / `arm` / `arm64` / `loong64` / `riscv64` / `s390x`
- 两台服务器都需要：`systemd`、`root` 用户（或装了 `sudo` 的普通用户）。

> Dashboard 和 Agent 可以装在同一台机器上，仅做单机测试时这样最快。

---

## 第一步：装 Dashboard（面板服务器）

登录**面板服务器**，运行：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | sh -s -- install
```

跑起来后，脚本会问你几个问题：

| 提示 | 含义 | 没主意就填 |
| --- | --- | --- |
| Site title | 面板标题，显示在浏览器标签栏 | `Nezha` |
| Dashboard HTTP port | 面板网页端口 | `8008` |
| Public install host | 你打算让 Agent 接进来的地址，比如 `nezha.example.com:5555` 或 `https://nezha.example.com` | 你的域名或公网 IP |
| Should agents connect with TLS | Agent 是否通过 HTTPS/TLS 反代连进来 | 没套反代填 `n`，套了 Cloudflare/Nginx 反代填 `y` |
| Backend language | 后台语言 | `zh_CN` |

装完会看到这样的提示：

```
Dashboard HTTP:  http://SERVER_IP:8008/
Dashboard Admin: http://SERVER_IP:8008/dashboard/
Agent gRPC:      0.0.0.0:5555
Admin username:  admin
Admin password:  stored in /opt/nezha/dashboard/.env (NZ_ADMIN_PASSWORD)
```

**为了安全，管理员密码不会打印在屏幕上**。第一次登录前，在面板服务器上读一下：

```bash
sudo grep ^NZ_ADMIN_PASSWORD= /opt/nezha/dashboard/.env
```

然后浏览器打开 `http://你的服务器IP:8008/dashboard/`，用 `admin` + 上面查到的密码登录。

---

## 第二步：在面板里拿到 Agent 一键安装命令

登录后台后：

1. 进入 **服务器管理** 页面。
2. 点 **「Agent 一键安装命令」** 按钮，会弹出一段 `curl ... | sh` 命令。
3. 复制这段命令。

这段命令里已经带好了：
- 你 Dashboard 的 gRPC 地址（默认 `5555`）
- Agent 的密钥（`NZ_CLIENT_SECRET`）
- TLS 开关（`NZ_TLS`）

不用你手动填。

---

## 第三步：在被监控机器上跑 Agent 命令

登录**任何一台你想监控的机器**，把上一步复制的命令粘贴运行。例如：

```bash
curl -L https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh -o /tmp/nezha-agent.sh && \
  env NZ_SERVER='nezha.example.com:5555' \
      NZ_TLS=false \
      NZ_CLIENT_SECRET='面板生成的密钥' \
      sh /tmp/nezha-agent.sh install
```

跑完没报错的话，回到面板的服务器列表，几秒钟内就会出现这台机器的实时数据。

> ⚠️ `NZ_SERVER` 填的是 Dashboard 的 **gRPC 接入地址**（默认 `:5555`），**不是**你访问网页用的 `:8008`。如果 Agent 通过 HTTPS 反代连进来，写成 `nezha.example.com:443` 并且 `NZ_TLS=true`。

要监控更多机器？在每台上重复这一步就行，密钥是同一个。

---

## 常见操作

下面这些命令在对应的机器上跑。`install.sh` 老的一键命令也仍然能用（会自动转给新脚本），但**新部署建议直接用 `install-dashboard.sh` / `install-agent.sh`**。

### 看日志

面板服务器：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | sh -s -- show_log
```

Agent 机器：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh | sh -s -- show_log
```

按 `Ctrl+C` 退出。

### 升级到最新版

升级会从 GitHub Release 拉最新二进制，然后重启服务。配置和数据库不动。

```bash
# Dashboard
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | sh -s -- restart_and_update

# Agent
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh | sh -s -- restart_and_update
```

如果想固定一个版本而不是 `latest`：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | \
  NZ_VERSION="v0.1.0" sh -s -- restart_and_update
```

### 改配置（端口、域名、密码……）

```bash
# Dashboard
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | sh -s -- modify_config

# Agent
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh | sh -s -- modify_config
```

会重新问一遍参数，回车保持原值，输入新值覆盖。改完会自动重启服务。

### 卸载

```bash
# Dashboard（会删 /opt/nezha/dashboard，数据库一并删除！）
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | sh -s -- uninstall

# Agent
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh | sh -s -- uninstall
```

需要免确认（比如写脚本里自动执行）加 `NZ_YES=1`：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | NZ_YES=1 sh -s -- uninstall
```

---

## 进阶：非交互式安装

适合 Ansible / cloud-init / Dockerfile 这种场景，所有参数从环境变量传入，不会弹任何提示。

Dashboard：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh | \
  NZ_SITE_TITLE="Nezha" \
  NZ_HTTP_PORT="8008" \
  NZ_GRPC_BIND="0.0.0.0:5555" \
  NZ_INSTALL_HOST="https://nezha.example.com" \
  NZ_AGENT_TLS="true" \
  NZ_AGENT_SECRET_KEY="自己生成一段随机字符串" \
  NZ_ADMIN_USERNAME="admin" \
  NZ_ADMIN_PASSWORD="自己定一个强密码" \
  sh -s -- install
```

Agent：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh | \
  NZ_SERVER="nezha.example.com:5555" \
  NZ_CLIENT_SECRET="跟 Dashboard 的 NZ_AGENT_SECRET_KEY 保持一致" \
  NZ_TLS="false" \
  sh -s -- install
```

---

## 进阶：把脚本下载到本地管理

每次都 `curl ... | sh` 也行，但如果你想用菜单交互方式管理，把脚本下到本地更方便：

```bash
curl -fL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-dashboard.sh -o nezha-dashboard.sh
curl -fL https://raw.githubusercontent.com/nezha-rs/scripts/main/install-agent.sh -o nezha-agent.sh
chmod +x nezha-dashboard.sh nezha-agent.sh
```

之后直接跑（不带参数会进菜单）：

```bash
./nezha-dashboard.sh          # 面板菜单
./nezha-agent.sh              # Agent 菜单
```

子命令一览：

```bash
./nezha-dashboard.sh install              # 安装
./nezha-dashboard.sh modify_config        # 改配置
./nezha-dashboard.sh restart_and_update   # 升级 + 重启
./nezha-dashboard.sh show_log             # 看日志
./nezha-dashboard.sh uninstall            # 卸载
./nezha-dashboard.sh update_script        # 更新脚本本身

./nezha-agent.sh install
./nezha-agent.sh modify_config
./nezha-agent.sh restart_and_update
./nezha-agent.sh restart                  # 只重启，不升级
./nezha-agent.sh show_log
./nezha-agent.sh uninstall
./nezha-agent.sh update_script
```

两个脚本都会自动在同目录下找 `lib/common.sh`；找不到就从 GitHub 拉。完全离线部署的话，把这个文件一起下下来：

```bash
mkdir -p lib
curl -fL https://raw.githubusercontent.com/nezha-rs/scripts/main/lib/common.sh -o lib/common.sh
```

或者用 `NZ_COMMON_LIB=/绝对/路径/common.sh` 显式指定。

---

## 出问题怎么排查

**1. Agent 在面板里一直离线**

- 检查 Agent 机器到 Dashboard 的 gRPC 端口是否通：
  ```bash
  # 在 Agent 机器上
  nc -vz 你的Dashboard地址 5555
  ```
  不通就是防火墙 / 安全组没放行 `5555`。
- 检查 Agent 日志（在 Agent 机器上）：
  ```bash
  sudo journalctl -xf -u nezha-agent.service
  ```
- 走了 HTTPS 反代但 `NZ_TLS` 还是 `false` → 改成 `true` 再重装/改配置。
- 密钥不一致：面板上 `NZ_AGENT_SECRET_KEY` 和 Agent 上 `NZ_CLIENT_SECRET` 必须是同一个字符串。

**2. 浏览器打不开 Dashboard**

- 在面板服务器上：
  ```bash
  sudo systemctl status nezha-dashboard.service
  sudo journalctl -xf -u nezha-dashboard.service
  ```
- 检查防火墙 / 云服务商安全组有没有放行 `8008`（或你改过的端口）。

**3. 忘了管理员密码**

```bash
sudo grep ^NZ_ADMIN_PASSWORD= /opt/nezha/dashboard/.env
```

如果想改密码：跑一遍 `modify_config`，在 `NZ_ADMIN_PASSWORD` 那一项输入新密码，脚本会同步进数据库。

---

## 文件都装在哪儿

Dashboard：

| 用途 | 路径 |
| --- | --- |
| 程序 | `/opt/nezha/dashboard/app` |
| 配置 | `/opt/nezha/dashboard/data/config.yaml` |
| 环境变量（含 admin 密码）| `/opt/nezha/dashboard/.env` |
| 数据库 | `/opt/nezha/dashboard/data/sqlite.db` |
| systemd 单元 | `/etc/systemd/system/nezha-dashboard.service` |

Agent：

| 用途 | 路径 |
| --- | --- |
| 程序 | `/opt/nezha/agent/nezha-agent` |
| 配置 | `/opt/nezha/agent/config.yml` |
| systemd 单元 | 由 `nezha-agent service install` 注册 |

---

## 环境变量速查

Dashboard：

```bash
NZ_VERSION=latest               # 或 v0.1.0
NZ_SITE_TITLE=Nezha
NZ_HTTP_PORT=8008               # Dashboard HTTP 面板端口
NZ_GRPC_BIND=0.0.0.0:5555       # Agent gRPC 接入端口
NZ_INSTALL_HOST=https://nezha.example.com
NZ_AGENT_TLS=false              # Agent 是否走 TLS 连进来
NZ_AGENT_SECRET_KEY=...         # 不填会随机生成
NZ_ADMIN_USERNAME=admin
NZ_ADMIN_PASSWORD=...           # 不填会随机生成
```

Agent：

```bash
NZ_VERSION=latest
NZ_SERVER=nezha.example.com:5555
NZ_CLIENT_SECRET=...            # 必须和 Dashboard 的 NZ_AGENT_SECRET_KEY 一致
NZ_TLS=false
```

通用：

```bash
NZ_RELEASE_REPO=nezha-rs/nezha-rs                                # 改 release 来源
NZ_SCRIPT_BASE_URL=https://raw.githubusercontent.com/nezha-rs/scripts/main
NZ_COMMON_LIB=/path/to/common.sh                                 # 离线/私有部署
NZ_SKIP_DEBIAN_CHECK=1                                           # 在非 Debian 上强行装
NZ_YES=1                                                         # 跳过卸载/危险确认
```

---

## 兼容入口 `install.sh`

老的一键命令仍然有效，`install.sh` 已经变成一个调度层，会自动转给新脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | sh -s -- install            # → install-dashboard.sh install
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | sh -s -- install_agent      # → install-agent.sh install
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | sh -s -- uninstall_dashboard
curl -fsSL https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh | sh -s -- uninstall_agent
```

新部署没必要走 `install.sh`，直接用 `install-dashboard.sh` / `install-agent.sh` 就好。

---

## Release 来源

- 程序二进制：https://github.com/nezha-rs/nezha-rs/releases
- 安装脚本：https://github.com/nezha-rs/scripts
