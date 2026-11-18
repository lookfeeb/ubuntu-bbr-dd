# Guard 构建与验证

v3.3.13 使用 Linux 7.3.5 / Guard7 R2，内核及 Nginx 核对散列后复用 v3.3.12 的相同包和对应源码，本次没有重新编译或验收整机。原构建和验收只在本地 Linux / WSL 及独立来宾执行。R2 按维护者授权合入骤降候选，完整网络性能门槛仍未通过，详见 [Release 发布说明](https://github.com/lookfeeb/ubuntu-bbr-dd/releases/tag/v3.3.13)。本文列出当前构建身份及验收要求；R4 / R5 身份与历史验证记录见 [Git 历史](https://github.com/lookfeeb/ubuntu-bbr-dd/blob/923da13f3b12515c01e62b937e9af63d257f26ab/docs/recovery-build.md)，重建历史包时使用对应版本的工具。

当前构建身份如下。菜单 1 → 2 按固定 7.3.5 源码构建；菜单 1 → 1 需要同 tag 已发布的完整新包与清单，缺少对应资产时停止，不能回退下载旧内核。使用未发布工作区时需设置 `BBR_DD_AUTO_UPDATE=0`。

本版源码与回归记录、复用产物的构建配置、日志、manifest、原验收报告和研究归档已统一收纳于 [开发资料包](https://github.com/lookfeeb/ubuntu-bbr-dd/releases/download/v3.3.13/development-details-v3.3.13.tar.gz)，历史证据保留原字节、提交身份和清单。内核与 Nginx 对应源码继续单独提供；文中提到的验证文件均可在开发资料包中找到。

| 项目 | Guard7 R2 |
| --- | --- |
| 内核 | `7.3.5-bbrguard7r2only-674859761ded` |
| Debian 包版本 | `7.3.5-guard7r2.1` |
| 模块版本 | `3-guard7-r2-experimental` |
| 生成 C 的 SHA-256 | `7de65dffbaeb7dfcbc0d21d2b820227efb1232747f64abbbacff0f84d17f7d42` |

预编译只提供 Guard7 R2 amd64；源码支持 amd64 / arm64。R2 保留 R1 热路径 v3，增加带宽骤降时的临时 pacing/cwnd 限制，不含 64 包补偿。新增状态与时钟、退出和控制路径有独立回归，网络实验失败结果完整保留。

R1 的恢复子路径与冻结 R5 的对比覆盖两种 HZ 共 4,020,000 个状态、299,520 个时钟推进/回绕组合，UBSan 通过；该子路径回归继续保留。R1 历史微基准的局部函数混合耗时降低约 9.4%～11.2%，不是 R2 新策略或完整网络吞吐收益。R2 新策略另有布局、时钟和 main 控制路径检查，不能把局部等价测试写成完整 R2 与 R5 行为相同；这些检查均不能代替实际包安装、启动及回退验收。

Guard7 R1 发布前，249 项代码回归通过。生产算法名模块完成恢复、持续丢包、ECN、断流、带宽下降、CUBIC 竞争和低速共 7 场景的独立串行验证，21 条流通过功能、计时及采集门槛；最大采样间隔 0.297 秒、采集耗时 0.021 秒，真实 ECN/RTO 覆盖及版本读回通过。原 4 来宾并发批次出现采集停顿，失败完整保留，不与串行批次拼接。该验证没有证明吞吐非劣效或公平性改善，CUBIC 竞争份额仍低。

64 包补偿 v2 的独立无插桩验证完成 24 组、72 条恢复流：3 条对照流采集超限，相同 R5 的首 5 秒中位差异达 29.77%，候选相对两个对照的收益区间均跨过零。采集、同算法对照和收益门槛未通过，未纳入 Guard7 R1；这不等于证明策略在所有网络条件下无效。

## 本地构建与发布

正式内核在本地 Linux / WSL 编译。GitHub Actions 只做代码检查；云端内核构建与自动发布工作流已移除。安装、模块加载与引导验证只在独立 QEMU 来宾执行，不修改开发宿主内核或引导。

准备 Python 3、GCC、make、bc、bison、flex、OpenSSL/ELF/ncurses 开发库、rsync、cpio、kmod、xz、zstd、fakeroot、dpkg-dev、debhelper、patch、QEMU、cloud-image-utils、OpenSSH 客户端和 GnuPG。更新版本、发布说明和嵌入脚本，运行回归并提交本地代码后：

```bash
bash tools/build_release.sh /var/tmp/guard-release-new
# 可选：独立复制现有 Linux 构建树，复用未改变的编译产物：
bash tools/build_release.sh /var/tmp/guard-release-new /path/to/previous/linux
```

构建目录必须是尚不存在的绝对路径。工具校验官方 Linux 7.3.5 源码散列，重新应用固定 Google TCP 补丁和 Guard7 R2，并按内容覆盖复用树的上游及补丁源码；不使用可写硬链接，不改动旧构建与证据。内容变化的源文件使用新的修改时间，保证 Make 使旧产物失效；未变化文件保留原时间以复用缓存。配置使用 `tools/release/config-amd64`，编译并发按可用内存和 CPU 限定。`source-commit` 记录构建提交，打包时必须与当前干净工作区一致。

构建器依次完成 image / headers、实际包无盘启动、完整来宾验收和发布资产生成。`tools/release_vm.py` 验证 Ubuntu 官方签名日期快照，以临时 qcow2 磁盘和仅绑定 127.0.0.1 的 SSH 端口启动来宾。私钥和来宾磁盘不进入发布资产。

成功资产位于构建目录的 `assets/`。复核 SHA256SUMS 后推送已验证的提交与 tag，在 GitHub 创建草稿 Release、上传完整资产，确认完成后再公开为 latest；失败不发布，不覆盖历史版本。脚本的内核包散列从同 tag 的 Release 清单读取，无需手工回填。每版必须携带固定内核的 image / headers、对应源码及原验收证据；复用未变更产物时先核对原散列。

编译器、配置、时间和模块签名密钥会影响散列，不承诺逐字节可复现。官方源码 tar.xz SHA-256 为 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`。

配置仅启用 `CONFIG_TCP_CONG_BBR_GUARD=m`，禁用原版 BBR、BBR3 和旧 WAN 模块，保留 CUBIC / Reno、GVE、ENA、VirtIO、NVMe 和 fq。上游 BBR3 源码仍是生成输入，不能删除。包内有驱动不等于已通过所有云机型验收。

只安装 image / headers，不替换系统 `linux-libc-dev`。内核未经 Ubuntu Secure Boot 签名，也不会自动接收 Ubuntu 内核安全更新。

## 实际包检查与导出

构建目录应包含 `linux/`、image / headers 包及正确的 `kernel-release`：

```bash
python3 tools/recovery_smoke.py --build /path/to/build \
  --image-package /path/to/build/linux-image-7.3.5-bbrguard7r2only-674859761ded_7.3.5-guard7r2.1_amd64.deb
python3 -B tools/release_vm.py --build /path/to/build
python3 -B tools/package_recovery.py --build /path/to/build \
  --upstream /path/to/linux-7.3.5.tar.xz --out /path/to/new-artifacts
```

使用新的输出目录，检查器拒绝覆盖旧证据。启动检查使用实际包内的内核和模块，无磁盘、无外部网卡，验证 socket 可选 `bbrguard` 且不可选旧算法。当前打包器强制检查同一 image / headers 的来宾安装、四次独立重启与新 SSH、HTTPS、headers、清理前旧内核回退、返回新内核及清理后的单内核启动记录，绑定实际包散列及提交。它核对测试后散列、包元数据、驱动、旧模块缺失和私钥缺失；从干净上游重新生成对应源码，与构建树比对后导出源码、配置、包、构建说明及清单。

发行前必须用同一组包在独立虚拟机或测试机完成安装、首次启动、外部 SSH/HTTPS、headers 编译、再次启动及实际旧内核回退。测试时在来宾中禁用 `bbr-kernel-cleanup.timer`，先完成回退并返回 Guard，再显式调用正式清理路径；确认只剩当前内核后再次启动并重复清理。不得在开发宿主执行内核安装或 DD。历史包的三次启动报告保持原样，不冒充新清理策略的验收。

## v3.3.8 的本地来宾验收

7.3.5 R1 阶段的本地实际包安装、headers、回退、清理和四次启动验收保留在开发资料包内的 `guard735-research-report.md`。其后按维护者授权合入 R2，并为 R2 独立构建及验收；R1 的通过不代替 R2 验收。以下 v3.3.8 记录属于历史产物。

v3.3.8 的历史 `validation.json` 记录当时的提交、本地构建环境、官方镜像 URL/SHA、包散列、原内核、三次重启及各验收阶段。当前开发资料包根层的 `kernel-validation.json` 和 `kernel-vm-validation.tar.gz` 属于 v3.3.12 构建的 Guard7 R2，记录四次重启和清理后启动，不能与 R5 历史报告混用。这些均属于 Ubuntu 24.04 amd64 / VirtIO / BIOS 的包安装验收，不是新的性能或云平台普适性证据。本地构建目录保留编译日志和验收证据；失败结果不与后续复验覆盖混算。

## 历史验证与性能边界

R5 的本地包验收、netem 性能试验、原计时失败及采样复验详情保留在 [历史验证记录](https://github.com/lookfeeb/ubuntu-bbr-dd/blob/923da13f3b12515c01e62b937e9af63d257f26ab/docs/recovery-build.md#已发布-r5-的验收与性能边界)。这些结果只支持相应本地实验结论，不能代表公网普遍提速；当前平台覆盖见 [README](../README.md#平台条件与实测范围)。Release 附带实际包、对应源码、验证报告和原始研究归档，保留原失败记录及覆盖范围。源码包内 `BBR-BUILD.md` 保留构建时说明，发行说明以独立的 `BUILD.md` 为准。
