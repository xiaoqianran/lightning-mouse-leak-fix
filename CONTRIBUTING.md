# Contributing

## Commit message (Alibaba / Conventional Commits)

Format:

```text
<type>(<scope>): <subject>

<body>

<footer>
```

### Type

| type | meaning |
|------|---------|
| `feat` | new feature |
| `fix` | bug fix |
| `docs` | documentation only |
| `style` | formatting; no code change |
| `refactor` | neither fix nor feature |
| `perf` | performance |
| `test` | tests |
| `chore` | build / tools / misc |
| `ci` | CI |
| `revert` | revert a commit |

### Rules

1. **subject**: imperative mood, no trailing period, ≤ 50 chars preferred  
2. **scope** (optional): e.g. `filter`, `shell`, `docs`  
3. **body**: what / why, wrap at ~72 chars  
4. **footer**: `BREAKING CHANGE:` or `Closes #123` when needed  

### Examples

```text
feat(filter): strip bare SGR mouse report bursts from stdin

code-server leaves fragments like 80;5M79;5M when the ESC prefix
is partially consumed. Drop multi-token bare patterns before they
reach the TUI prompt.

fix(shell): sanitize LESS after Lightning rc sources --mouse

docs: add one-liner install for new Studios
```
