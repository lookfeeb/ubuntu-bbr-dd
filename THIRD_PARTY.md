# 上游来源与许可

公开仓库不改变上游版权和许可。分发组合脚本、补丁或编译内核时，须遵守对应组件的条款；不能把整个内核当作本项目原创。

| 组件 | 来源及许可 |
| --- | --- |
| Linux 7.3.5 | kernel.org 官方源码；以源码中的 `COPYING`、`LICENSES/` 和各文件 SPDX 为准，内核整体 GPL-2.0-only |
| Google BBRv3 完整补丁 | `tools/google-bbr3.patch` 保留全部作者、提交信息及 SPDX；新增 BBRv3 文件为 GPL-2.0 OR BSD-3-Clause，其他 TCP 修改遵从被修改文件许可 |
| Guard 派生模块 | 从固定 Google 文件生成，保留原文件许可和作者信息；额外策略头声明 GPL-2.0-only OR BSD-2-Clause |
| bin456789/reinstall | 固定提交 `8ac9db68f9bca0b26c4143b2f3e206f2aa342d6b`，上游 LICENSE 为 GPL-3.0；运行时下载校验后应用本项目补丁，资源包保留 LICENSE |
| Ubuntu cloud image 公钥 | Ubuntu `ubuntu-keyring` 中 UEC Image Automatic Signing Key 的公开部分，不包含私钥 |
| 3X-UI | [MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui)，GPL-3.0（以所安装版本 LICENSE 为准）；首次安装查询官方最新稳定 Release，冻结并校验对应架构包的官方 SHA-256，不在本仓库打包二进制 |
| OpenList | [OpenListTeam/OpenList](https://github.com/OpenListTeam/OpenList)，AGPL-3.0（以所安装版本 LICENSE 为准）；首次安装查询官方最新稳定 Release，冻结并校验官方 SHA-256，源码与许可证由上游提供 |

Google 补丁来源：

https://github.com/google/bbr/compare/c1c3d01e3a9038d3e8f497e773e1f7b5d6b8212a...5dee74110da392fc3e32208fdae50fc29886fa25.patch

本仓库提供下载地址、固定校验值、原始补丁、生成器与构建工具。当前 [最新 Release](https://github.com/lookfeeb/ubuntu-bbr-dd/releases/latest) 提供 Guard7 R2 的 amd64 内核包、完整对应源码和校验清单；实际配置、构建说明及验收证据统一放在开发资料包内。源码保留 COPYING、LICENSES 和文件内版权许可。组装方法见 `tools/package_recovery.py`，构建说明见 [docs/recovery-build.md](docs/recovery-build.md)。旧 WAN Release 已下架，历史源码与证据仍可通过 Git 历史查询。
