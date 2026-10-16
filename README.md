# 桂林理工大学南宁分校校园网自动登录服务安装脚本

</div>

> 在OpenWRT上部署，然后忘掉校园网要登录这件事~

**当前版本**: v1.4.0 (2026-10-16)

**特别鸣谢[xhzLK123](https://github.com/xhzLK123)提供的登录方法**

> **本仓库 fork 自 [VoidInTheShell/glut_network-autologin](https://github.com/VoidInTheShell/glut_network-autologin)**
> （原版 v1.3.2）。上游的代码与设计归原作者所有；本仓库仅在其基础上做问题修复，
> 并已同步更新本文档中的一键安装命令，使其指向本仓库的修复版。
> 如需同步上游更新：`git fetch upstream && git merge upstream/main`

---

## ⚠️ 本目录是修复版（务必先读）

本目录在原版 v1.3.2 基础上修复了「**实际在线却被判离线**」等 8 类问题（含认证报文 MAC 取真实网卡、行尾符规范化）。
**直接 `sh install.sh` 即可安装**，行为已在本校网关（10.10.11.11，ePortal/DrCOM）上实测验证，
并通过 A/B 对照实验确认（旧版 300 秒内 50 次状态检测全部失败、从未进入 ONLINE；新版首次检测即判定在线并稳定保持）。

### 快速安装

```sh
sh install.sh
```

安装过程是交互式的，只有 4 处必须填：

| 提示 | 填什么 |
|---|---|
| `是否继续安装? (y/n):` | `y` |
| `是否使用此接口? (Y/n):` | 自动检测到的 WAN 接口正确就回车（本项目实测为 `eth2`） |
| `请输入登录账号:` | 你的账号 |
| `请输入登录密码:` | 你的密码（不回显，正常现象） |
| `请选择策略 (1/2) [默认: 1]:` | 运营商：`1`=联通 `2`=移动 |

其余全部回车用默认值即可。

### 修复了什么

| # | 问题 | 修复 |
|---|---|---|
| 1 | **`/drcom/chkstatus` 状态接口已废弃** —— TCP 连上后不发响应头，挂起直到超时，导致状态检测恒为"不确定" | 弃用该接口，改用 **HTTPS 探测 + 公网 DNS 直连查询** 作为在线判据 |
| 2 | **`/eportal/portal/login` 不能当判据** —— 已在线时反而返回 `result:0`（服务器拒绝重复认证） | 不再用它判在线 |
| 3 | **`do_login` 成功判定错误** —— 只认 `success`，而本网关成功时返回 `"result":1` 与「Portal协议认证成功！」，导致每次成功都被记成失败 | 判定放宽为 `"result":1` / `认证成功` / `success` |
| 4 | **`ONLINE_VERIFY_STRATEGY` 是死配置** —— 安装时选的"仅DNS / DNS+HTTP"从未被 `login.sh` 引用，恢复判据被硬编码 | 新增 `check_online_criteria()`，让该开关真正生效 |
| 5 | **恢复阶段被单个判据卡死** —— 判据恒为"不确定"时永远回不到 ONLINE | 恢复判据容忍"不确定"，并按策略分派 |
| 6 | **空转刷屏** —— 离线时每 2 秒打印一次，日志迅速膨胀 | 检测间隔 2 秒 → 10 秒 |
| 7 | **认证报文里的 MAC 是写死的** —— 原脚本硬编码 `wlan_user_mac=000000000000`（被改成了某台 PC 的 MAC），报文里的 MAC 与实际网卡不符 | 新增 `get_wan_mac_hex()`，从 WAN 网卡动态读取真实 MAC；取不到合法值时放弃本次认证并记 ERROR |
| 8 | **行尾符是 CRLF** —— 在 `core.autocrlf=true` 的机器上签出后 `sh install.sh` 报 `: not found` / `set: illegal option -` | 加入 `.gitattributes`（`* text=auto eol=lf`），保证任何平台签出都是 LF |

### 关于 MAC 动态化（第 7 项）

改前的报文里 MAC 是硬编码的（`E0D55EFE63F1`，即某台 PC 的网卡 MAC），与路由器 WAN 口真实 MAC 不符。
现在 `do_login` 会调用 `get_wan_mac_hex()` 动态取值：

```
eth2 的 MAC 7c:d3:0a:15:01:c7  ->  报文里发送 7cd30a1501c7
```

实现上有两个 BusyBox 坑（已在本项目实际踩到并绕过，改动者请勿"优化"回去）：

1. **`case` 的方括号表达式在 BusyBox ash 下不生效** —— `[0-9a-f][0-9a-f]...` 这种 12 段方括号**恒不匹配**。
   正确做法：先用 `case "$v" in ????????????)` 查长度，再用 `grep -Eqi '^[0-9a-f]{12}$'` 查字符。
2. **BusyBox 的 `tr` 对字符范围处理有偏差** —— `tr -d '0-9a-f'` 会把 `c`、`d`、`a` 一并删掉，无法用于反向过滤非法字符。

另外注意：脚本原有的 `get_wan_mac()` 返回的是**带横线**的形式（`7c-d3-0a-15-01-c7`），
**不能直接塞进 URL**（那是非法 MAC 格式），必须先 `tr -d ':-'` 去掉分隔符。

> 实测结论：本校园网的认证服务器**并不校验 `wlan_user_mac`** ——
> 用真实 MAC、别的 MAC、空值、随机伪造值，回包都是 `result:1 认证成功`。
> 因此这项改动属于"让参数如实反映本机网卡"，不改变认证结果、无风险，
> 但能避免在启用 MAC 绑定的校园网里出问题。

### 若你的网络环境不同

修复项 1、2 源于「**HTTP 明文出站被本机透明代理 `ua3f` 吞掉 + 门户只放行 login 接口**」这一环境特征，判据选用：

- **主判据**：`wget --spider https://www.baidu.com/`（TLS 不受 UA 改写影响）
- **备判据**：`nslookup www.baidu.com 223.5.5.5` 是否返回真实应答（明确指定公网 DNS，避开本地 dnsmasq 缓存）

如果你的环境里 HTTPS 也受限，请把 `check_real_http()` 换成你环境里**唯一可靠**的探测方式。
判据函数位于 `install.sh` 中 `generate_login_script()` 的 heredoc 内，搜索 `check_real_http` 即可找到。

### 修改 install.sh 时的注意事项

`login.sh` 并不是独立存在的文件 —— 它由 `install.sh` 里的 **5 段 heredoc 拼接生成**。
所以**只改路由器上的 `/usr/local/autologin/login.sh` 是没有意义的**，下次重装就会被覆盖；
所有修复必须回填进 `install.sh` 的 heredoc 里（搜索 `generate_login_script()` 即可定位）。

改动后至少要做一次语法检查：

```sh
sh -n install.sh          # install.sh 自身
```

若想确认"生成出来的 login.sh 符合预期"，可以在 `install.sh` 中临时搜索 `check_real_http`
逐项核对，或另建一个只读的还原脚本比对。本目录不再附带校验工具，保持精简。

### 已知的架构局限（上游设计，未改动）

- `handle_online_state` 在 ONLINE 状态下**只做 ICMP ping**，不校验认证状态。本校园网的 ICMP 在登出后仍然通畅，
  因此**认证掉线到被发现之间存在延迟**（最坏约 `2 × DNS_CHECK_INTERVAL` 秒后进入 SUSPECT，再由并行检测确认）。
  这是判据能力的上限，不是 bug。
- `AUTH_HTTP_CHECK_INTERVAL` 已废弃但仍保留在配置文件里，仅作兼容。

## 功能特性

- ✅ 交互式配置（账号、密码、检测频率、日志选项）
- ✅ 四状态机检测在线情况，远程+本地FB多机制防止误判 **[v1.2.0b]**
- ✅ 离线认证保护机制（最大尝试次数+冷却期）**[v1.3.2]**
- ✅ 完整BusyBox兼容性（wget短选项、read/echo命令）**[v1.3.2]**
- ✅ 灵活的日志管理（文件日志、syslog、禁用）
- ✅ 更低的日志占用：运行1天只产生100kB左右实时日志（占用内存）和0.1KB左右运行日志（占用闪存）
- ✅ 智能双层日志系统（实时+持久化故障日志）**[v1.2.0b]**
- ✅ 完整运行统计和故障追踪（离线次数、恢复时间、DNS失败统计）**[v1.2.0b]**
- ✅ 结构化日志分级（INFO/CHECK/OFFLINE/AUTH/ONLINE/ERROR/WARN/STAT）**[v1.2.0b]**
- ✅ 自动告警机制（离线频率、认证失败）**[v1.2.0b]**
- ✅ 日志大小限制和智能轮转（自动过滤心跳日志）
- ✅ 自动配置为 OpenWrt 系统服务
- ✅ 支持开机自启动
- ✅ 网络断线自动重连
- ✅ 自动检测 OpenWrt 系统环境
- ✅ 自动安装缺失的依赖包（wget、curl）
- ✅ 自动获取 WAN 口本地 DHCP IP（无需手动指定接口）

## 快速开始

### 首次安装：直接执行以下命令安装

> 以下命令指向**本仓库（修复版）**。如果你又 fork 了自己的副本，
> 请把 URL 中的 `a16546311` 换成你的 GitHub 用户名。
```
sh -c "$(curl -fsSLk https://gh-proxy.org/raw.githubusercontent.com/a16546311/glut_network-autologin/refs/heads/main/install.sh)"
```

### 升级脚本
首先卸载旧版本
```
curl -fsSL https://gh-proxy.org/raw.githubusercontent.com/a16546311/glut_network-autologin/refs/heads/main/uninstall.sh -o uninstall.sh && sh uninstall.sh
```
然后安装新版本
```
sh -c "$(curl -fsSLk https://gh-proxy.org/raw.githubusercontent.com/a16546311/glut_network-autologin/refs/heads/main/install.sh)"
```
### 命令无法执行时，使用下面的方法安装
### 1. 上传脚本到 OpenWrt

将 `install.sh` 上传到你的 OpenWrt 路由器：

```sh
# 方法1: 使用 SCP
scp install.sh root@[你的路由器IP]]:/tmp/

# 方法2: 在路由器上使用 wget下载
# 首先ssh登录到路由器
cd /tmp
wget https://gh-proxy.org/raw.githubusercontent.com/a16546311/glut_network-autologin/refs/heads/main/install.sh
```

### 2. 运行安装脚本

```sh
# SSH 登录到路由器
ssh root@[你的路由器IP]

# 添加执行权限
chmod +x /tmp/install.sh

# 运行安装程序
sh /tmp/install.sh
```

### 3. 按照提示配置

安装程序会引导你完成以下配置：

#### 3.1 WAN 接口配置
- 脚本会自动检测 WAN 接口（如 eth1、wan 等）
- 如果检测正确，直接按回车确认
- 如果需要手动指定，输入正确的接口名称

#### 3.2 登录凭证
- 输入登录账号
- 输入登录密码（输入时不显示）

#### 3.3 运营商选择
- 1 = 联通
- 2 = 移动

#### 3.4 检测策略配置

系统使用双层检测策略：
- **主检测**: 公网DNS Ping (快速响应，不受认证服务器限制)
- **辅助检测**: 本地认证服务器HTTP状态 (fallback验证)

注意: 认证服务器有防护机制，高频HTTP请求会被强制登出

**在线状态检测频率**:
- 公网DNS检测频率 (默认: 10秒)
- 本地HTTP检测频率 (默认: 60秒，最小60秒以避免被登出)

**离线状态重连配置**:
- 离线重连等待时间 (默认: 3秒)

**离线认证保护配置** **[v1.3.2]**:
- 离线时最大认证尝试次数 (默认: 20次)
- 达到最大尝试次数后冷却时间 (默认: 300秒)
- 说明: 防止离线时无限制发送认证请求，避免给服务器造成过大压力
- 冷却期间暂停认证，结束后重置计数器继续尝试

**DNS离线判定策略**:
1. 任何1个DNS失败就离线 (最敏感，快速反应，可能误判)
2. 至少2个DNS失败才离线 (推荐，平衡误判和延迟)
3. 所有DNS都失败才离线 (最保守，可能延迟发现断线)

**在线判定策略**:
1. 仅依赖DNS检测 (达到DNS阈值即判定在线)
2. DNS + HTTP双重验证 (至少1个DNS可达 + 本地HTTP在线，推荐)

**公网DNS服务器配置**:
- 默认: 119.29.29.29 223.5.5.5 1.1.1.1
- 用于辅助验证网络连通性（负载均衡轮询）

#### 3.5 日志配置 **[v1.2.0b ]**
选择日志输出方式：

**选项 1: 智能双层日志系统**（推荐）
系统采用双层日志架构，兼顾实时分析和故障追踪：

- **实时日志**: `/tmp/autologin/autologin.log` (内存中，快速写入)
  - 记录所有级别日志（INFO/CHECK/OFFLINE/AUTH/ONLINE/ERROR/WARN/STAT）
  - 切割阈值：2MB（默认）
  - 查看：`tail -f /tmp/autologin/autologin.log`

- **持久化故障日志**: `/usr/local/autologin/logs/persistent.log` (闪存中，永久保存)
  - 仅保留故障事件（OFFLINE/AUTH/ONLINE/ERROR/WARN）和状态摘要（STAT）
  - 实时日志切割时自动过滤心跳日志（INFO/CHECK），提取故障事件归档
  - 大小限制：10MB（默认）
  - 查看：`tail -f /usr/local/autologin/logs/persistent.log`

- **运行统计**: `/usr/local/autologin/runtime.state`
  - 总运行时长、历史离线次数、认证统计
  - DNS失败统计（按服务器分类）
  - 上次离线时间/原因、恢复耗时
  - 查看：`cat /usr/local/autologin/runtime.state`

配置参数：
- 持久化故障日志大小限制（默认：10 MB）
- 实时日志切割阈值（默认：2 MB）
- 状态摘要输出间隔（默认：3600秒 = 1小时）
- 离线次数告警阈值（默认：3次/小时）
- 连续认证失败告警阈值（默认：3次）

**选项 2: 输出到 syslog**
- 日志输出到系统日志（结构化格式）
- 实时查看：`logread -f | grep autologin`
- 历史日志：`logread | grep autologin`
- 按级别过滤：`logread | grep autologin | grep OFFLINE`

**选项 3: 不记录日志**
- 所有日志输出到 /dev/null
- 适合性能敏感场景

## 安装后管理

### 服务管理命令

```sh
# 启动服务
/etc/init.d/autologin start

# 停止服务
/etc/init.d/autologin stop

# 重启服务
/etc/init.d/autologin restart

# 查看状态
/etc/init.d/autologin status

# 启用开机自启动
/etc/init.d/autologin enable

# 禁用开机自启动
/etc/init.d/autologin disable
```

### 修改配置
**执行安装脚本会提示进行配置，无需手动配置**

编辑配置文件：

```sh
vi /etc/config/autologin
```

配置文件示例：

```sh
# WAN 接口名称
WAN_INTERFACE="eth1"

# 登录凭证
USER_ACCOUNT="your_username"
USER_PASSWORD="your_password"

# 运营商选择 (1=联通, 2=移动)
ISP_CHOICE="1"

# 认证服务器配置
AUTH_SERVER="10.10.11.11"
AUTH_PORT_801="801"
AUTH_PORT_80="80"

# 检测频率配置 (秒)
DNS_CHECK_INTERVAL="10"           # 公网DNS检测频率
AUTH_HTTP_CHECK_INTERVAL="60"     # 已废弃 (v1.3.1+，仅保留兼容)
RECONNECT_INTERVAL="3"            # 离线重连等待时间

# 离线状态检测配置 (v1.3.0+)
OFFLINE_AUTH_INTERVAL="2"         # 离线时登录请求间隔
OFFLINE_HTTP_CHECK_INTERVAL="2"   # 离线时状态查询间隔

# 离线认证保护配置 (v1.3.2+)
OFFLINE_AUTH_MAX_ATTEMPTS="20"    # 离线时最大认证次数
OFFLINE_COOLDOWN_SECONDS="300"    # 达到最大次数后冷却时间

# 检测策略配置
DNS_FAILURE_THRESHOLD="2"         # DNS离线判定阈值 (1/2/999)
ONLINE_VERIFY_STRATEGY="2"        # 在线判定策略 (1=仅DNS, 2=DNS+HTTP)

# 检测方法开关
ENABLE_AUTH_HTTP="Y"              # 启用本地认证服务器HTTP检测
ENABLE_PUBLIC_PING="Y"            # 启用公网DNS Ping检测

# 公网测试服务器配置
DNS_TEST_SERVERS="119.29.29.29 223.5.5.5 1.1.1.1"

# 日志配置
LOG_TYPE="1"                      # 1=文件, 2=syslog, 3=禁用

# 日志系统配置 (LOG_TYPE=1 文件模式专用)
REALTIME_LOG_FILE="/tmp/autologin/autologin.log"           # 实时日志
PERSISTENT_LOG_FILE="/usr/local/autologin/logs/persistent.log"  # 持久化日志
REALTIME_LOG_SIZE_MB="2"          # 实时日志切割阈值
LOG_SIZE_MB="10"                  # 持久化日志大小限制
STAT_INTERVAL="3600"              # 状态摘要间隔 (秒)
OFFLINE_ALERT_THRESHOLD="3"       # 离线次数告警阈值
AUTH_FAIL_THRESHOLD="3"           # 连续认证失败告警阈值
LOG_SUSPECT_STATE="N"             # 记录疑似离线日志 (v1.3.1+)

# 状态文件路径
STATE_FILE="/usr/local/autologin/runtime.state"
```

修改后重启服务使配置生效：

```sh
/etc/init.d/autologin restart
```

### 查看日志 **[v1.2.0b ]**

**智能双层日志系统**（LOG_TYPE=1）：

```sh
# 查看实时日志（所有级别）
tail -f /tmp/autologin/autologin.log

# 查看持久化故障日志（仅故障事件）
tail -f /usr/local/autologin/logs/persistent.log

# 按日志级别过滤
tail -f /tmp/autologin/autologin.log | grep "\[OFFLINE\]"  # 离线事件
tail -f /tmp/autologin/autologin.log | grep "\[AUTH\]"     # 认证请求
tail -f /tmp/autologin/autologin.log | grep "\[STAT\]"     # 状态摘要
tail -f /tmp/autologin/autologin.log | grep "\[ERROR\]"    # 错误日志
tail -f /tmp/autologin/autologin.log | grep "\[WARN\]"     # 告警日志

# 查看最近的故障事件
grep "\[OFFLINE\]" /usr/local/autologin/logs/persistent.log | tail -20

# 查看运行统计
cat /usr/local/autologin/runtime.state

# 查看状态摘要（每小时自动生成）
grep "\[STAT\]" /tmp/autologin/autologin.log | tail -1
```

**syslog 模式**（LOG_TYPE=2）：
```sh
# 实时查看
logread -f | grep autologin

# 查看历史
logread | grep autologin

# 按级别过滤
logread | grep autologin | grep "\[OFFLINE\]"
logread | grep autologin | grep "\[STAT\]"
```

## 工作原理

### 1. WAN 口 IP 自动获取

脚本使用多种方法自动获取 WAN 口的本地 DHCP IP：

1. 优先使用 `ip addr` 命令（现代系统）
2. 其次使用 `ifconfig` 命令（兼容旧系统）
3. 支持多种 IP 格式解析

### 2. 四状态自适应检测机制

在线监测采用状态机设计，根据网络状态自动调整检测策略：

#### 状态 1: ONLINE (在线状态)
- **检测方式**: 低频轮询检测
- **检测频率**: 每 `DNS_CHECK_INTERVAL` 秒检测1个DNS服务器
- **特点**:
  - 轮询所有DNS服务器，分散负载
  - 不主动请求认证服务器，避免被强制下线
  - 连续失败计数机制，防止误判

#### 状态 2: SUSPECT (疑似离线)
- **触发条件**: 在线状态单次检测失败
- **检测方式**: 并行快速验证
- **检测频率**: 立即并行检测所有DNS (1秒超时)
- **转移逻辑**:
  - 验证通过 → 回到ONLINE (误报)
  - 验证失败 → 进入OFFLINE (确认离线)

#### 状态 3: OFFLINE (离线状态)
- **触发条件**: 快速验证确认网络离线
- **处理动作**:
  1. 立即执行登录请求
  2. 进入快速恢复循环
- **检测频率**:
  - DNS检测: 每2秒并行检测所有DNS
  - 登录尝试: 每10秒一次
- **转移逻辑**: DNS + HTTP双重验证通过 → 进入RECOVERING

#### 状态 4: RECOVERING (恢复验证)
- **触发条件**: DNS + HTTP双重验证初步通过
- **检测方式**: 持续稳定性验证
- **验证要求**: 连续5次成功 (每2秒检测一次)
- **转移逻辑**:
  - 连续5次成功 → 回到ONLINE (确认稳定)
  - 任意一次失败 → 回到OFFLINE (网络不稳定)

### 3. 双层检测策略

#### 主检测: 公网DNS Ping
- **优势**: 快速响应，不受认证服务器限制
- **方式**: 轮询模式 (在线状态) / 并行模式 (离线状态)
- **防护**: 连续失败判定，避免单次抖动误判

#### 辅助检测: 联通认证服务器HTTP状态码验证
- **优势**: 通过认证成功标志确认是否登录上网
- **频率**: 低频检测 (最小60秒间隔)
- **注意**: 避免高频请求导致被强制登出

### 4. 性能指标

- **在线误判防护**: 轮询单点失败 → 并行快速验证
- **离线发现时间**: < 2秒 (并行检测)
- **恢复时间**: < 2秒 (快速检测 + 立即登录)
- **状态稳定性**: 连续5次验证防止频繁切换

### 5. 日志轮转

当日志文件超过设定大小时：
1. 将当前日志重命名为 `.old` 后缀
2. 创建新的日志文件
3. 防止日志文件无限增长

### 6. 服务守护

使用 OpenWrt 的 `procd` 进程管理器：
- 自动重启崩溃的进程
- 开机自动启动
- 优雅的服务管理

## 文件结构 **[v1.2.0b 更新]**

安装完成后的文件分布：

```
/etc/
├── config/
│   └── autologin              # 配置文件
└── init.d/
    └── autologin              # 服务启动脚本

/usr/local/autologin/
├── login.sh                   # 登录主脚本
├── runtime.state              # 运行统计（v1.2.0b+）
└── logs/                      # 持久化日志目录
    └── persistent.log         # 故障日志（v1.2.0b+）

/tmp/autologin/                # 实时日志目录（v1.2.0b+，内存中）
└── autologin.log              # 实时日志
```

## 常见问题

### Q1: 如何查看 WAN 接口名称？

```sh
# 方法1: 查看网络接口
ifconfig

# 方法2: 查看 UCI 配置
uci show network.wan

# 方法3: 查看路由表
ip route | grep default
```

### Q2: 服务无法启动？

检查以下几点：
1. 确认配置文件存在：`cat /etc/config/autologin`
2. 确认脚本有执行权限：`ls -l /usr/local/autologin/login.sh`
3. 查看系统日志：`logread | tail -20`
4. 手动运行测试：`/usr/local/autologin/login.sh`

### Q3: 如何确认服务在运行？

```sh
# 方法1: 查看服务状态
/etc/init.d/autologin status

# 方法2: 查看进程
ps | grep login.sh

# 方法3: 查看日志
tail /usr/local/autologin/logs/autologin.log
```

### Q4: 日志文件太大怎么办？

编辑配置文件减小日志限制：

```sh
vi /etc/config/autologin
# 修改 LOG_SIZE_MB 为更小的值，如 5

# 重启服务
/etc/init.d/autologin restart
```

或者切换到 syslog 模式：

```sh
vi /etc/config/autologin
# 修改：
LOG_TYPE="2"
LOG_FILE="logger -t autologin"

# 重启服务
/etc/init.d/autologin restart
```

### Q5: 如何卸载？

**推荐方式：使用卸载脚本**
```sh
#直接执行以下命令卸载
sh -c "$(curl -fsSLk https://gh-proxy.org/raw.githubusercontent.com/a16546311/glut_network-autologin/refs/heads/main/uninstall.sh)"

# 上述命令无法执行时手动下载并上传 uninstall.sh 到路由器
scp uninstall.sh root@192.168.1.1:/tmp/

# SSH 登录并运行
ssh root@192.168.1.1
chmod +x /tmp/uninstall.sh && /tmp/uninstall.sh
```

卸载脚本功能：
- ✅ 自动检测安装状态
- ✅ 可选配置备份
- ✅ 安全停止所有服务和进程
- ✅ 完整清理所有文件
- ✅ 验证卸载结果
- ✅ 支持部分安装的清理

**手动卸载方式**
```sh
# 停止并禁用服务
/etc/init.d/autologin stop
/etc/init.d/autologin disable

# 删除所有文件
rm /etc/init.d/autologin
rm /etc/config/autologin
rm -rf /usr/local/autologin

# 终止残留进程
pkill -9 -f autologin
```

### Q6: 如何修改检测策略？

**修改检测频率**:
```sh
vi /etc/config/autologin

# 修改以下参数 (单位: 秒)
DNS_CHECK_INTERVAL="10"              # 在线状态DNS检测间隔
OFFLINE_AUTH_INTERVAL="2"            # 离线时登录请求间隔 (v1.3.0+)
OFFLINE_HTTP_CHECK_INTERVAL="2"      # 离线时状态查询间隔 (v1.3.0+)
RECONNECT_INTERVAL="3"               # 离线状态重连间隔
# AUTH_HTTP_CHECK_INTERVAL="60"      # 已废弃 (v1.3.1+)

# 重启服务
/etc/init.d/autologin restart
```

**修改离线判定策略**:
```sh
vi /etc/config/autologin

# DNS离线判定阈值
DNS_FAILURE_THRESHOLD="1"   # 1=任意1个DNS失败即离线
DNS_FAILURE_THRESHOLD="2"   # 2=至少2个DNS失败才离线 (推荐)
DNS_FAILURE_THRESHOLD="999" # 999=所有DNS都失败才离线

# 在线判定策略
ONLINE_VERIFY_STRATEGY="1"  # 1=仅依赖DNS检测
ONLINE_VERIFY_STRATEGY="2"  # 2=DNS + HTTP双重验证 (推荐)

# 重启服务
/etc/init.d/autologin restart
```

**修改DNS服务器列表**:
```sh
vi /etc/config/autologin

# 添加或修改DNS服务器 (空格分隔)
DNS_TEST_SERVERS="119.29.29.29 223.5.5.5 1.1.1.1 114.114.114.114"

# 重启服务
/etc/init.d/autologin restart
```

### Q7: 如何调试网络检测问题？

**查看检测日志**:
```sh
# 文件日志模式
tail -f /tmp/autologin/autologin.log | grep "检测"

# syslog模式
logread -f | grep autologin | grep "检测"
```

**手动测试DNS连通性**:
```sh
# 测试DNS服务器
ping -c 1 -W 1 119.29.29.29
ping -c 1 -W 1 223.5.5.5
ping -c 1 -W 1 1.1.1.1

# 测试认证服务器
ping -c 1 -W 1 10.10.11.11
wget --timeout=2 --tries=1 -qO- http://10.10.11.11/
```

**查看当前状态**:
```sh
# 查看进程
ps | grep login.sh

# 查看最近日志
tail -n 50 /tmp/autologin/autologin.log

# 实时监控状态变化
tail -f /tmp/autologin/autologin.log | grep "状态变化"
```

### Q8: 如何查看运行统计和故障历史？ **[v1.2.0b]**

**查看完整运行统计**:
```sh
# 查看状态文件
cat /usr/local/autologin/runtime.state

# 主要统计指标：
# - FIRST_START_TIME: 首次启动时间
# - OFFLINE_COUNT: 历史离线次数
# - LAST_OFFLINE_TIME: 上次离线时间（时间戳）
# - LAST_RECOVERY_DURATION: 上次恢复耗时（秒）
# - AUTH_TOTAL_COUNT: 总认证次数
# - DNS_FAIL_119/223/8/1: 各DNS服务器失败统计
# - MAX_ONLINE_DURATION: 最长在线时长（秒）
```

**查看最新状态摘要**:
```sh
# 查看最后一次状态摘要（每小时生成）
grep "\[STAT\]" /tmp/autologin/autologin.log | tail -20

# 输出示例：
# [2025-12-04 10:00:00] [STAT] ========== 状态摘要 ==========
# [2025-12-04 10:00:00] [STAT] 总运行时长: 2天5小时30分钟
# [2025-12-04 10:00:00] [STAT] 本次在线时长: 3小时25分钟
# [2025-12-04 10:00:00] [STAT] 历史离线次数: 5次
# [2025-12-04 10:00:00] [STAT] 上次离线时间: 2025-12-04 06:35
```

**查看故障事件历史**:
```sh
# 查看持久化故障日志中的所有离线事件
grep "========== 故障事件" /usr/local/autologin/logs/persistent.log

# 查看最近5次离线事件的详细信息
grep -A 10 "========== 故障事件" /usr/local/autologin/logs/persistent.log | tail -55
```

### Q9: 如何过滤和分析日志？ **[v1.2.0b]**

**按日志级别过滤**:
```sh
# 仅查看离线事件
tail -f /tmp/autologin/autologin.log | grep "\[OFFLINE\]"

# 仅查看认证请求
tail -f /tmp/autologin/autologin.log | grep "\[AUTH\]"

# 仅查看错误和告警
tail -f /tmp/autologin/autologin.log | grep -E "\[ERROR\]|\[WARN\]"

# 查看状态摘要
tail -f /tmp/autologin/autologin.log | grep "\[STAT\]"
```

**分析故障原因**:
```sh
# 查看某次故障事件的完整信息
grep -A 20 "故障事件 #5" /usr/local/autologin/logs/persistent.log

# 统计DNS失败分布
grep "DNS失败统计" /tmp/autologin/autologin.log | tail -1

# 查看告警
grep "\[WARN\]" /tmp/autologin/autologin.log

# 示例输出：
# [WARN] ⚠️ 告警: 最近1小时离线次数(5)超过阈值(3)
# [WARN] ⚠️ 告警: 连续认证失败次数(4)超过阈值(3)
```

**导出故障报告**:
```sh
# 导出最近的所有故障事件
grep -E "\[OFFLINE\]|\[AUTH\]|\[ERROR\]|\[WARN\]|\[STAT\]" \
  /tmp/autologin/autologin.log > /tmp/fault_report.log

# 导出持久化故障日志
cp /usr/local/autologin/logs/persistent.log /tmp/persistent_backup.log
```

## 高级配置

### 自定义检测策略

**保守策略 (避免误判，适合网络稳定场景)**:
```sh
vi /etc/config/autologin

DNS_CHECK_INTERVAL="15"         # 降低检测频率
DNS_FAILURE_THRESHOLD="999"     # 所有DNS都失败才判定离线
ONLINE_VERIFY_STRATEGY="2"      # 启用双重验证
```

**激进策略 (快速响应，适合网络不稳定场景)**:
```sh
vi /etc/config/autologin

DNS_CHECK_INTERVAL="5"          # 提高检测频率
DNS_FAILURE_THRESHOLD="1"       # 任意1个DNS失败就判定离线
ONLINE_VERIFY_STRATEGY="1"      # 仅依赖DNS检测
```

**平衡策略 (推荐，默认配置)**:
```sh
vi /etc/config/autologin

DNS_CHECK_INTERVAL="10"
DNS_FAILURE_THRESHOLD="2"
ONLINE_VERIFY_STRATEGY="2"
```

### 自定义DNS服务器列表

根据地理位置选择最快的DNS服务器:

```sh
vi /etc/config/autologin

# 国内DNS服务器 (推荐)
DNS_TEST_SERVERS="119.29.29.29 223.5.5.5 202.38.64.1 1.1.1.1"

# 国内 + 国际DNS服务器
DNS_TEST_SERVERS="119.29.29.29 223.5.5.5 1.1.1.1 8.8.8.8"

# 仅使用单个DNS (不推荐，无冗余)
DNS_TEST_SERVERS="119.29.29.29"
```

### 性能优化建议

**降低系统负载**:
```sh
# 1. 禁用文件日志，使用syslog
LOG_TYPE="2"

# 2. 降低检测频率
DNS_CHECK_INTERVAL="15"

# 3. 使用较少的DNS服务器
DNS_TEST_SERVERS="119.29.29.29 223.5.5.5"
```

**最快响应速度**:
```sh
# 1. 提高检测频率
DNS_CHECK_INTERVAL="5"

# 2. 使用激进判定策略
DNS_FAILURE_THRESHOLD="1"

# 3. 使用多个DNS服务器并行检测
DNS_TEST_SERVERS="119.29.29.29 223.5.5.5 1.1.1.1"
```
