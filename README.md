# VertexPath

Turn what you write into a clean checklist.

Paste notes, bullets, or comma separated tasks. VertexPath turns them into a flat checklist with progress, hide/delete checked, and autosave.

![License](https://img.shields.io/badge/license-MIT-blue)
![Platform](https://img.shields.io/badge/desktop-Windows-0078D4)
![Web](https://img.shields.io/badge/web-GitHub%20Pages-222)

## Features

- **Drop or open `.txt` / `.json`** lines become checks; JSON reloads a saved list
- **Extract from your text** lines, bullets, commas, `+` `/` `&`, and short `and` lists
- **Skips fluff** filters pure “why / because” explanations so only work items remain
- **Flat checklist UI** progress bar, toggle all, hide checked, delete checked
- **Autosave** desktop: `Documents\VertexPath` · web: `localStorage`
- **Save / Open JSON · Export Markdown**
- **Configurable Ctrl keybinds** (Settings)
- **One-click Update from GitHub** (desktop downloads + restarts)
- **Optional AI** on desktop only (off by default). **Never** on the website

## Desktop (Windows)

### Requirements

- Windows 10/11
- PowerShell 5.1+ (built-in) or PowerShell 7 (`pwsh`)

### Install

1. Download this repo (or the latest release).
2. Keep these files in the **same folder**:
   - `VertexPath.ps1`
   - `VertexPath.cmd`
   - `background.jpg` (optional, light blur behind the UI)
   - `icon.png` (optional)
3. Double-click `VertexPath.cmd`.

If scripts are blocked:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### Data location

`Documents\VertexPath`

- `settings.json` — AI toggle, key, keybinds  
- `autosave.json` — last session  

### Update

**Settings → Update from GitHub** downloads `VertexPath.ps1` / `VertexPath.cmd` from this repo and restarts.

## How checklist extraction works

| Input | Result |
|--------|--------|
| One task per line / bullet | One check each |
| `a, b, c` or `a + b` | Split into checks |
| Long “because / why…” text | Skipped when it is only rationale |
| Your wording | Kept (light cleanup + capitalize) |

## JSON format

```json
{
  "Title": "My list",
  "Idea": "original text",
  "Items": [
    { "Id": "...", "Text": "Task", "Checked": false }
  ]
}
```

Desktop and web share the same shape. Older phase-tree files are flattened on load.

## Security

- Desktop AI is optional, HTTPS-only (or localhost), keys stored only on your PC.
- Update downloads only from `raw.githubusercontent.com/herfavknife/vertexpath`.

## License

MIT [LICENSE](https://github.com/herfavknife/vertexpath/blob/main/LICENSE) free to use modify with attribution appreciated.
