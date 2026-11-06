# SBX (Sing-box & Linux VPS 管理面板)

轻量、纯净的 Linux VPS 综合维护与 Sing-box 代理管理工具箱。无冗余依赖，双列终端排版，纯字符无 emoji。

## 一键安装与使用

### 推荐：一键安装快捷指令

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3922510-creator/sbx/main/install.sh)
```

安装完成后，在终端直接输入以下命令即可打开面板：

```bash
sbx
```

### 免安装单次运行

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/3922510-creator/sbx/main/sbx.sh)
```

---

## 功能特性

### 1. 系统维护
- **系统状态总览**：CPU 架构/主频/占用率、内存/Swap 使用率、磁盘挂载、系统负载、TCP/UDP 连接统计、公网 IPv4/IPv6 及归属地。
- **系统更新与必备依赖**：一键识别包管理器（apt/dnf/yum/apk）更新系统，自动补齐 curl、wget、git、jq、tar、socat、htop 等常用工具。
- **系统垃圾清理**：清理包管理器缓存、清理孤儿废弃依赖、截断轮转 journalctl 旧日志、清理 /tmp 临时过期缓存。
- **修改 Root 密码**：双重输入验证与安全更新。
- **主机名与时区设置**：修改 hostname 并自动同步 `/etc/hosts`；一键切换为 `Asia/Shanghai` 或自定义目标时区。

### 2. 网络优化与安全
- **Swap 虚拟内存管理**：查看 Swap 状态，一键分配 1G / 2G / 4G / 自定义大小并写入 `/etc/fstab` 保证开机自启；支持一键彻底停用与清除。
- **DNS 优化与修改**：预置国际公共 DNS（1.1.1.1 / 8.8.8.8）、国内主流 DNS（223.5.5.5 / 119.29.29.29）、自定义输入与一键还原原始备份。
- **TCP 调优与 BBR 加速**：一键开启原生 BBR + FQ 拥塞控制；一键应用网络高吞吐调优参数（独立 sysctl 配置文件），支持随时一键还原默认值。
- **回程线路测试**：测试国内三大运营商核心骨干网（电信 163/CN2、联通 169/9929、移动 CMI、教育网）的平均延迟与丢包率。
- **UFW 防火墙管理**：防火墙状态查看、开启/关闭、放行指定端口、删除规则；开启时自动识别当前 SSH 监听端口并放行，杜绝失联。

### 3. Sing-box 代理管理
- **VLESS-Reality 节点搭建**：自动安装最新官方核心，自动生成 Reality 密钥对、UUID、短 ID 与伪装域名，生成客户端分享链接与终端二维码。
- **TCP / UDP 端口转发**：基于 Sing-box direct 模式的轻量中转，支持自定义本机监听端口与目标地址。
- **WARP 出口分流**：生成 WireGuard 出口，支持将 OpenAI (ChatGPT) 或主流流媒体流量按需分流走 WARP。
- **核心与服务维护**：查看实时运行状态与日志，配置语法自动校验与历史备份一键回滚。

### 4. 彻底卸载与残留清理
- 面板菜单选 `15` 即可一键彻底卸载。
- 自动注销并删除 `sbx.service` 服务单元。
- 彻底删除 `/etc/sbx` 下全部配置、节点私钥、历史备份与日志。
- 自动清理快捷命令 `/usr/local/bin/sbx`、还原 sysctl 调优配置并清理临时文件。
- 绝不触碰系统中的其他服务或旧版脚本。

---

## 目录结构

- `sbx.sh`: 编译生成的单文件分发脚本
- `install.sh`: 一键安装器
- `src/`: 模块化源码（header, system, network, proxy_core, proxy_nodes, proxy_features, uninstall, menus）
- `tools/build.py`: 单文件构建工具
- `tests/`: 自动化测试用例
