# lightning-mouse-leak-fix

One-shot, idempotent fix for **terminal mouse-tracking garbage** on [Lightning AI](https://lightning.ai) Studios (code-server + GNU screen + TUI apps such as Grok Build).

## Symptom

Moving the mouse dumps literal junk into the shell or Grok prompt:

```text
80;5M79;5M77;6M57;10M48;12M40;15M...
```

## Quick start (any Lightning Studio)

```bash
# clone then install
git clone https://github.com/xiaoqianran/lightning-mouse-leak-fix.git
cd lightning-mouse-leak-fix
bash fix-lightning-mouse-leak.sh

# verify
bash fix-lightning-mouse-leak.sh --check
```

Or one-liner after copy:

```bash
bash fix-lightning-mouse-leak.sh
```

**Restart Grok after install** (`/exit` then `grok`) so the PTY filter wraps the real binary.

## Root cause (layers)

| Layer | What happens |
|-------|----------------|
| Protocol | xterm mouse modes `CSI ?1000/1002/1003/1005/1006/1015 h` make the terminal emit SGR/X10 reports on every motion |
| Lightning `LESS` | `/settings/.lightningrc` exports `LESS=...--mouse...` |
| Vim | Common `set mouse=a` + `ttymouse=xterm2` |
| GNU screen | Lightning uses `/settings/.screenrc` (not `~/.screenrc`) via `/settings/zsh` → `screen` |
| **Grok TUI** | Enables mouse capture on start; under code-server + screen, reports often leak into the input buffer as bare `80;5M...` (**primary user-visible cause**) |

## What the script installs

Defense in depth:

1. **Shell guard** — strip `--mouse` / `--wheel-lines=*` from `LESS` after Lightning rc; emit mouse-off CSI on interactive start  
2. **Vim / tmux / `~/.screenrc`** — mouse tracking off by default  
3. **`/settings/.screenrc`** — `mousetrack off` when writable (Lightning’s real screen config)  
4. **Grok PTY filter** (critical) — rewrite mouse-**enable** CSI to **disable**; strip inbound reports and bare `N;NM` bursts  
5. **Wrappers** — `~/.local/bin/grok` and `~/.grok/bin/grok` run the filter  

## CLI

```text
bash fix-lightning-mouse-leak.sh              # install + apply + self-test
bash fix-lightning-mouse-leak.sh --check      # verify only
bash fix-lightning-mouse-leak.sh --now        # immediate CSI mouse-off only
bash fix-lightning-mouse-leak.sh --uninstall  # remove hooks
bash fix-lightning-mouse-leak.sh --help
```

Manual reset anytime:

```bash
mouse_off                 # shell function after a new interactive shell
mouse-tracking-off        # CLI
```

Re-enable Grok mouse (may reintroduce the leak):

```bash
GROK_ALLOW_MOUSE=1 grok
```

## Requirements

- `bash`, `python3`, `awk`, `file`
- Optional: `zsh`, `screen`, Grok Build (`~/.grok`)

Portable: uses `$HOME` only; safe to re-run (idempotent markers).

## License

MIT
