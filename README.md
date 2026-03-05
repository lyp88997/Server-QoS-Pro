# ⚡ Server-QoS-Pro (v3.0)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash Shell](https://img.shields.io/badge/Language-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)](https://www.kernel.org/)

**Server-QoS-Pro** 是一款专为 Linux 服务器设计的智能端口流量控制工具。它基于系统的 `TC (Traffic Control)` 和 `iptables` 内核架构，能够根据实时流量自动触发限速规则，并在设定的冷却时间后自动恢复，实现全自动的带宽管理与网络优化。

---

## ✨ 核心特性

* **🔍 智能双向监控**：实时监控指定端口的流量情况（支持 TCP/UDP/BOTH 协议）。
* **⚖️ 动态触发机制**：支持“带宽阈值 × 持续时间”组合规则。只有当流量持续超标时才触发限制，精准识别异常占用。
* **🔄 自动循环复原**：限速时长到期后，系统自动撤销限制并重新进入监控，无需人工手动干预。
* **🛠️ 交互式管理菜单**：全中文交互式 CLI 界面，支持规则增删改查、网卡切换、采样频率调节。
* **📦 生产级稳定性**：
    * **环境自适应**：首次运行自动检测并补齐 `tc`, `iptables`, `bc` 等核心依赖。
    * **系统服务化**：支持一键安装为 `systemd` 系统服务，确保服务器重启后自动运行。
    * **全协议兼容**：采用 `fwmark` 标记技术，完美兼容 IPv4/IPv6 以及 NAT 复杂环境。

---

## 🚀 快速开始

### 1. 一键安装与配置
在你的 Linux 服务器上执行以下命令（支持 Debian/Ubuntu/CentOS/Alpine）：

```wget -O qos.sh https://raw.githubusercontent.com/lyp88997/Server-QoS-Pro/refs/heads/main/qos.sh && bash qos.sh setup```

2. 快捷指令
安装完成后，你可以在任何位置直接输入以下快捷命令：

• qos - 进入交互式管理主菜单

• qos start - 启动后台监控进程

• qos stop - 停止后台监控进程

• qos status - 查看当前所有端口的实时监控与限速状态

• qos clear - 一键强制清除所有流量控制规则
