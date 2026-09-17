# GLM Quota — Omarchy bar plugin

Thermometer-style GLM token quota for the [Omarchy](https://omarchy.org/) bar.
The mercury fill shows how much of the **weekly** quota is spent; a floating
caret marks how far through the window's *time* you are. Click it for the
5-hour window and weekly breakdown.

On the desktop — the gauge sits in the bar's center section, click opens the popup:

![overview](docs/overview.png)

Close-up — bar gauge (fill + time caret + ruler ticks) and the popup detail:

![preview](docs/preview.png)

- **Bar widget** — weekly usage as a thermometer gauge: fill = quota spent,
  floating caret = time through the week, ruler ticks at 0/25/50/75/100 %.
  The mercury shifts from the theme accent to orange and red as usage climbs
  past 75 % and 90 %.
- **Popup panel** — two gauges (5-hour window + this week) with used / quota /
  remaining, time progress, and reset countdowns. `r` refreshes, middle-click
  on the bar forces a refresh.
- **No natural-day concept** — every number is window-based (5 h / 7 d), as
  the BigModel quota API reports them.

中文用户：面板默认跟随系统语言显示中文，也可在配置里强制 `language: "zh"`。

## Install

```bash
omarchy plugin add https://github.com/tomasWade/omarchy-glm-quota.git --enable
```

Requires `bash`, `curl`, and `jq` (all in the Arch base repos / omarchy).

## Set up the API key

The plugin never reads keys from environment variables.

1. Create an API key in the [BigModel console](https://open.bigmodel.cn/)
   (账户 → API Keys).
2. Save it — one bare key on a single line — into `api.key` in the plugin
   folder and lock it down:

   ```bash
   echo -n "YOUR_KEY" > ~/.config/omarchy/plugins/tomaswade.glm-quota/api.key
   chmod 600 ~/.config/omarchy/plugins/tomaswade.glm-quota/api.key
   ```

   These permissions are enforced, not suggested: the key file must be a
   regular file (no symlinks) owned by you with no group/other access
   (`chmod 600`), otherwise the plugin reports `badkey` and refuses to use it.

   The panel shows a red hint with the exact expected path when the key is
   missing, unsafe, invalid, or expired.

## Settings

Inline in `~/.config/omarchy/shell.json`, e.g.

```json
{ "id": "tomaswade.glm-quota", "refreshMinutes": 10, "language": "auto" }
```

| Setting | Default | Description |
| --- | --- | --- |
| `refreshMinutes` | `10` | How often the bar polls. The script layer caches responses for 4 minutes, so shorter intervals reuse the same numbers. Minimum 2. |
| `keyFile` | `""` | Override path for the key file. Empty uses `api.key` in the plugin folder. |
| `language` | `"auto"` | `auto` follows the system locale; `zh` / `en` force a language. |
| `demo` | `false` | Render canned numbers instead of fetching, for previewing the visuals. |

## How it works

- `bin/glm-quota` (bash + curl + jq) calls
  `open.bigmodel.cn/api/monitor/usage/quota/limit`, caches the response in
  `~/.cache/glm-quota.json` for 240 s, and always prints one valid JSON
  object — network or auth failures fall back to the cached report marked
  `stale` with a machine-readable error code (`nokey`, `badkey`,
  `unauthorized`, `network`, `badresp`).
- The QML side computes the time carets locally from `nextResetTime`, so
  they keep moving between polls without any requests.

## Security

- All file access is fused check-and-use on file descriptors via
  `bin/glm-quota-secio.py`: paths are resolved one component at a time with
  `O_NOFOLLOW|O_DIRECTORY`, the verified directory descriptor is kept open,
  and every file is `fstat(2)`-verified *after* opening — never before.
  Swapping a pathname (or a parent directory component) for a symlink
  between a check and a use is therefore structurally impossible.
- The API key is fed to curl through a private pipe (`curl -K`), so it never
  appears in any process's `argv` (no leak via `ps`) or environment, and its
  charset is validated before use.
- The key file must pass a strict check: regular file (never followed
  through a symlink), owned by the current user, no group/other permission
  bits — `chmod 600` it and keep it that way.
- API responses are capped on the producer side at 64 KiB; anything larger
  is rejected before parsing, so a hostile endpoint cannot exhaust disk or
  memory.
- Cache updates are published through an exclusive, unpredictable
  same-directory temporary (`secrets`-random name, `O_CREAT|O_EXCL|
  O_NOFOLLOW`, mode 600) that is created and `rename(2)`d relative to the
  pinned cache-directory descriptor; planted symlinks on the cache path are
  replaced, never followed.
- Threat boundary: these measures defeat path-race attacks from other local
  principals or untrusted code swapping paths out from under the plugin.
  A process already running as your own user can of course read your files
  directly; that class of compromise is out of scope.

## Uninstall

```bash
omarchy plugin remove tomaswade.glm-quota
rm -f ~/.cache/glm-quota.json
```

## License

[MIT](LICENSE) © tomasWade
