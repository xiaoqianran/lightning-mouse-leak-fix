# lightning-mouse-leak-fix

用于解决 [Lightning AI](https://lightning.ai) Studio（code-server + GNU screen + OpenCode / Grok Build）中**终端鼠标追踪乱码**的一次性、幂等修复工具。

## 问题表现

移动鼠标时，Shell 或 Grok 输入框会出现以下乱码：

```text
80;5M79;5M77;6M57;10M48;12M40;15M...
```

## 快速开始（适用于任意 Lightning Studio）

```bash
# 克隆并安装
git clone https://github.com/xiaoqianran/lightning-mouse-leak-fix.git
cd lightning-mouse-leak-fix
bash fix-lightning-mouse-leak.sh

# 验证
bash fix-lightning-mouse-leak.sh --check
```

请将安装脚本与 `grok-mouse-filter.py` 放在同一目录。安装完成后需要**重新启动 OpenCode/Grok**，以便应用新的环境变量和包装器。

## 根本原因（分层说明）

| 层级 | 具体原因 |
|------|----------|
| 终端协议 | xterm 鼠标模式 `CSI ?1000/1002/1003/1005/1006/1015 h` 会让终端在每次鼠标移动时发送 SGR/X10 报告 |
| Lightning `LESS` | `/settings/.lightningrc` 会导出包含 `--mouse` 的 `LESS` |
| Vim | 常见配置中包含 `set mouse=a` 和 `ttymouse=xterm2` |
| GNU screen | Lightning 通过 `/settings/zsh` → `screen` 使用 `/settings/.screenrc`，而不是 `~/.screenrc` |
| **OpenCode TUI** | 默认启用鼠标，但提供原生的 `OPENCODE_DISABLE_MOUSE` 开关 |
| **Grok TUI** | 会启用鼠标捕获；在 code-server + screen 下，报告可能以裸 `80;5M...` 片段泄漏到输入缓冲区 |

## 脚本安装的内容

脚本采用多层防护：

1. **Shell 防护**——在 Lightning 启动脚本之后，从 `LESS` 中移除 `--mouse` 和 `--wheel-lines=*`；交互式 Shell 启动时发送关闭鼠标的 CSI。
2. **Vim / tmux / `~/.screenrc`**——默认关闭鼠标追踪。
3. **`/settings/.screenrc`**——文件可写时加入 `mousetrack off`，这是 Lightning 实际使用的 screen 配置。
4. **OpenCode 原生模式**——导出 `OPENCODE_DISABLE_MOUSE=1`；不使用包装器，因此所有 CLI/TUI 功能均保留原生标准输入输出、键盘、剪贴板和更新行为。
5. **选择性 Grok 包装器**——只有交互式 TUI/dashboard 会使用 PTY 过滤器；无界面模式及所有管理子命令均直接执行真实二进制文件。
6. **安全协议过滤器**——将鼠标“启用”CSI 改写为“禁用”，只剥离带 ESC 前缀的明确鼠标报告，同时保留焦点事件、OSC 52、括号粘贴、Kitty/CSI 按键及普通文本。
7. **Grok 自主管理程序文件**——不替换 `~/.grok/bin/grok` 和 `agent`，确保 `update`、补全以及基于 `argv` 的入口分派正常工作。

## 命令行用法

```text
bash fix-lightning-mouse-leak.sh              # 安装、立即应用并自检
bash fix-lightning-mouse-leak.sh --check      # 仅验证
bash fix-lightning-mouse-leak.sh --now        # 仅立即关闭 CSI 鼠标模式
bash fix-lightning-mouse-leak.sh --uninstall  # 移除安装钩子
bash fix-lightning-mouse-leak.sh --help       # 显示帮助
```

需要时可手动重置：

```bash
mouse_off                 # 新交互式 Shell 中提供的函数
mouse-tracking-off        # 命令行工具
```

只为单次运行重新启用鼠标（可能再次出现乱码）：

```bash
GROK_ALLOW_MOUSE=1 grok
env -u OPENCODE_DISABLE_MOUSE opencode
```

## 运行要求

- 必需：`bash`、`python3`、`awk`、`file`
- 可选：`zsh`、`screen`、OpenCode、Grok Build（`~/.grok`）

## 测试

```bash
python3 tests/test_mouse_filter.py
bash tests/test_installer.sh
```

脚本只使用 `$HOME`，可以安全地重复运行（通过标记块保证幂等）。

## 许可证

MIT

## Troubleshooting

### `grok` hangs / Ctrl+C shows traceback in `grok-mouse-filter.py` / `import signal`

**Cause (v2.0 and earlier):** the wrapper called PATH `python3` (often Lightning
`/commands/python3` or conda), which can hang on import; or the real binary path
was baked in at install time before Grok was downloaded.

**Fix:** upgrade to **v2.2+** and re-run:

```bash
git pull
bash fix-lightning-mouse-leak.sh
```

Emergency bypass (always works if Grok is installed):

```bash
# option A
GROK_ALLOW_MOUSE=1 grok

# option B — call the real binary directly
~/.grok/downloads/grok-linux-x86_64
# or
~/.grok/bin/grok
```

### Installed the fix **before** downloading Grok

v2.1+ wrappers resolve the ELF **at runtime**. After Grok finishes installing:

```bash
bash fix-lightning-mouse-leak.sh   # refresh optional
grok --version                     # should print version, not hang
```

### Still broken

```bash
rm -f ~/.local/bin/grok            # remove PATH shadow
hash -r
~/.grok/bin/grok                   # vendor entry
```


### `grok: 未找到真实 Grok 二进制（ELF）`

Lightning often makes `$HOME/.local` → `/home/zeus/.local` (**shared** across Studios).
The wrapper lives there, but the **real Grok binary is per-studio** under:

```text
$HOME/.grok/downloads/grok-linux-x86_64
$HOME/.grok/bin/grok
```

1. Confirm the binary exists:

```bash
ls -la ~/.grok/downloads/ ~/.grok/bin/
```

2. If missing, install Grok Build first, then:

```bash
bash fix-lightning-mouse-leak.sh
grok --version
```

3. Or set an absolute path:

```bash
export GROK_REAL_BIN=$HOME/.grok/downloads/grok-linux-x86_64
grok --version
```

### Prompt shows `1000l1002l...` after running the fix

Older versions sprayed mouse-off CSI to every PTY. **v2.2+** only writes to `/dev/tty`.
Open a new terminal tab or run `reset`.
