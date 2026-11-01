# SCWebManager

生存战争（Survivalcraft）服务器一站式管理面板，由 **JIILNetTechStudio** 开发与维护。

> **本仓库仅用于对外发布**：提供安装脚本、版本清单与安装包下载。
> 产品源码不公开，仓库中不包含任何源代码。
> 版权所有 © JIILNetTechStudio，未经书面许可，禁止复制、转载、二次分发、反编译或用于任何商业用途。

---

## 功能概览

- **实例管理**：启动 / 停止 / 重启、内存看护与自动重启、配置在线编辑
- **玩家管理**：在线与离线列表、属性编辑、背包可视化与编辑、聊天与进出记录
- **地图**：世界渲染查看、玩家标记、行走轨迹与时间追溯
- **文件与模组**：在线文件管理、模组上传与版本管理、一键更新
- **控制台**：实时日志流、命令执行、命令记录
- **定时任务**：cron 表达式，命令 / 脚本任务与执行审计
- **AI 助手**：多模型接入、工具调用与分级审批、对话级回滚
- **安全**：登录保护、权限分组（RBAC）、操作审计、网络环境自检

## 支持平台

| 平台 | 版本要求 | 架构 |
| --- | --- | --- |
| Windows | Windows 10 / Windows Server 2016 及以上 | x64、ARM64 |
| Linux | x86_64 / aarch64，主流发行版（Ubuntu、Debian、CentOS、RHEL、Fedora、openSUSE、Alpine 等） | amd64、arm64 |

组件与端口：面板 `18233`、守护进程 `18234`、游戏内插件 `18244`（随实例自动安装）。

## 一键安装

Windows（PowerShell）：

```powershell
irm https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/install.ps1 | iex
```

Linux：

```bash
curl -fsSL https://gitee.com/JIILStudio/jiilsc-web-manger/raw/master/install.sh | bash
```

安装脚本会自动识别本机 CPU 架构并选择对应安装包，安装过程中可选择目录（默认 / 手动输入 / 文件管理器选择），完成后自动启动守护进程与面板，并输出访问地址与初始管理员账号。

安装参数（可选）：

| 参数 | 说明 |
| --- | --- |
| `-1 <目录>` | 指定安装目录 |
| `-2 <版本>` | 指定版本（`latest` 或具体版本号） |
| `-f` | 静默安装，使用默认值 |
| `-json` | 仅输出一行 JSON 结果 |

## 手动安装

1. 打开 [发行版](https://gitee.com/JIILStudio/jiilsc-web-manger/releases) 页面，按你的平台与架构下载对应安装包；
2. 解压到任意目录（重复安装时保留已有 `data` 目录即可保留配置与数据）；
3. 先运行 `scweb-daemon`（Windows 为 `scweb-daemon.exe -dir <目录>`），再运行 `scweb-panel`；
4. 浏览器访问 `http://127.0.0.1:18233`，使用启动日志中给出的初始账号登录。

## 文件校验

发行版附带的 `SHA256SUMS` 是各安装包的 SHA-256 校验值，**不是程序，下载后无需运行**。校验方法：

```powershell
# Windows
Get-FileHash .\scweb-1.5.8-windows-amd64.zip -Algorithm SHA256
```

```bash
# Linux / macOS
sha256sum -c SHA256SUMS
```

输出与清单一致即可；不一致说明下载不完整或被篡改，请重新下载。安装脚本会自动校验，手动安装时建议核对一次。

## 仓库文件说明

| 文件 | 用途 |
| --- | --- |
| `install.ps1` | Windows 安装脚本 |
| `install.sh` | Linux 安装脚本 |
| `versions.json` | 版本清单（安装脚本按架构选择安装包） |
| `version.json` | 面板自动更新清单 |
| `true-list.json` | 各发行版最低系统版本要求 |

## 自动更新

面板内置更新检查：在「设置 → 更新」中可以查看新版本并执行更新。更新包会按当前平台与架构自动选择，下载校验完成后由守护进程在服务器实例全部停止时替换程序并重启面板。

## 反馈

使用问题、安装问题或功能建议请提交 Issue，并附上基本信息：操作系统版本、CPU 架构、安装方式，以及 `data/startup-error.log`、`panel.err.log`（如有）。

---

**版权声明**：本产品及其全部内容（含安装包、界面、文档）版权归 JIILNetTechStudio 所有。本仓库仅作发布用途，不授予任何源码权利。禁止以任何形式二次分发（包括但不限于转载到其他平台、打包进其他产品）或反编译、修改后发布。
