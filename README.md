# INVAXION Offline

音灵 INVAXION 的 Windows 本地离线补丁：跳过已停运的运营服务器，进入快速游玩，保留原生 Steam 成就和统计，并提供自动演奏入口与实时调试日志。

版本：**2.0-steam-achievements**。支持本项目验证过的 Unity 5.6.0f3 / Steam build 4958506；补丁按 SHA-256 严格匹配，未知游戏版本不会被覆盖。

## 快速开始

需要自己的完整游戏安装、Windows PowerShell 5.1。正常使用无需 Python、编译器、模拟服务器或管理员权限。

1. 下载本仓库 ZIP 并解压，或运行 `git clone https://github.com/sdfsfsk/INVAXION-Offline.git`。
2. 关闭游戏。需要 Steam 成就时，先登录拥有本游戏的 Steam 账号。
3. 双击 **启动-音灵-离线.bat**，或 **启动-音灵-离线自动演奏.bat**。

启动器通过 Steam 注册表、游戏库和 AppID **921630** 定位安装。首次运行从本机原版 `Assembly-CSharp.dll` 创建备份，再按公开的增量清单生成并校验两个补丁变体。

本仓库发布补丁源码和变更清单。原版及修改后的游戏 DLL、游戏资源、反编译输出、个人日志与 Steam 快照均留在本地；克隆仓库本身不提供游戏。

如果自动定位失败，可以显式指定目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\offline.ps1 -GamePath "D:\SteamLibrary\steamapps\common\音灵 INVAXION" -Action Launch -Autoplay -LiveLog
```

如果游戏已经装过补丁，但当前工具目录没有原件备份，请将已验证的原件放到 `original/Assembly-CSharp.dll`，或先用 Steam 验证文件恢复原版。不要将补丁版当作原版备份。

## 入口与操作

| 入口 / 按键 | 行为 |
| --- | --- |
| 启动-音灵-离线.bat | 每首歌曲初始为手动模式 |
| 启动-音灵-离线自动演奏.bat | 每首歌曲初始开启自动演奏，持续显示实时日志 |
| 恢复-音灵-原版.bat | 校验备份后恢复原版程序集 |
| F8 | 歌曲中切换自动演奏 |
| F9 | 关闭本首自动演奏；自动演奏入口下一首或重试时重新开启 |
| Esc | 使用游戏原生暂停菜单 |

两个启动入口切换同一个游戏 DLL 的变体，切换或还原前应退出游戏。补丁安装后，从 Steam 或 EXE 启动也会使用最后安装的版本；Steam 验证文件可能将其恢复为原版。

其他命令：

```powershell
# 检查安装状态；首次使用会准备本地备份和补丁，不改写游戏文件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\offline.ps1 -Action Check
# 只安装，不启动游戏
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\offline.ps1 -Action Install -Autoplay
# 手动模式同样可以持续查看日志
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\offline.ps1 -Action Launch -LiveLog
```

## 离线与 Steam 成就

运营服务器的登录、网关、连接探测、重连、DNS 入口及远程资源下载已停用；使用本地资源和游戏原生无账号初始化。

**Steam 初始化、回调、统计请求、成就设置及统计提交仍然启用。** 因而这是运营服务器离线模式，不是完全禁止联网模式。离线结算进入原生条件判定，不直接批量解锁成就；Steam 累计统计只允许增加，避免新离线档覆盖较高的既有进度。

原生自动演奏采用 `PlayData.isAuto` 和游戏已有音符处理分支，**保留不计分规则**：可以显示命中、连击与准确率，但自动演奏结算分数为 0，评级可能为 TBD。它不是模拟真人按键的独立输入调度器，因此不保证达成分数门槛成就。

在线排行榜、多人、社交、云存档和商城没有重建。离线玩家数据每次从默认值初始化，没有新增跨启动本地成绩存档；依赖服务器或跨启动累计进度的成就不保证可完成。

## 实时日志

自动演奏入口约每 200 ms 读取游戏 `output_log.txt`，显示场景、资源信息和异常，支持 UTF-8 中文、日志截断及 Steam 重启交接。游戏退出或启动失败后窗口保留，便于查看错误。

每次日志保存到 `logs/<日期时间>-autoplay.log`，会话信息保存到 `logs/last-debug-session.json`。同一补丁版本的游戏正在运行时，再开调试入口会接上当前日志。关闭调试窗口不关闭游戏；这里显示游戏实际输出，不额外生成逐音符判定记录。

## 源码构建与验证

`bin/patch-manifest.json` 是随源码发布的版本指纹与字节修改清单。`tools/prepare-patch.ps1` 从原件应用增量，验证完整输出 SHA-256 后才写入本地 `bin/`。`offline.ps1` 再对备份、补丁和安装目标检查哈希，通过临时文件替换目标。

需要重新生成修改清单时，安装 Python 3.10+ 并运行：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
# 先运行 offline.ps1 -Action Check，建立已校验的本地原件备份
.\.venv\Scripts\python.exe tools\build_offline.py
.\.venv\Scripts\python.exe tools\verify_patch.py
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test-live-log.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\test-prepare-patch.ps1
```

`build_offline.py` 在受保护的原始布局中修改方法体，检查共享方法、原字节及空间边界；`recover_headers.py` 只为分析副本还原文件头和 IL，不将分析程序集安装进游戏。验证工具检查变更范围、完整哈希、IL 指令边界与方法命名。

## 已有实测

- Garden of Eden / 4K Standard 2：完整演奏、暂停恢复、结算返回，311/311 连击、311 Maximum+、0 Miss。
- Garden of Eden / 6K Hard 6：458/458 连击、0 Miss；结算后经只读 Steam 会话确认首次 6K Hard 通关、Hard Full Combo、6K Full Combo 三项成就由实际游玩解锁。
- 6K 的 F8/F9 开关、8K 的部分演奏及失败路径已检查；未逐首覆盖全部曲目、难度和皮肤。
- 首次发布的本地构建结果：两种变体各 36 项方法补丁，分别改变 360 / 364 字节，均通过二进制验证。

## 许可证与依赖

项目原创工具与补丁实现使用 [MIT](LICENSE) 许可证；该许可不覆盖游戏程序、资源或商标。

开发依赖：[dnfile](https://github.com/malwarefrank/dnfile)、[dncil](https://github.com/mandiant/dncil)。这些依赖按各自许可证分发，本仓库通过依赖清单安装，不附带第三方包副本。
