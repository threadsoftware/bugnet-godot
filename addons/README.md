# Bugnet SDK for Godot

Bug reporting, crash analytics, session replay, and an in-game report widget for Godot 4.x games. Players submit bugs directly from your game with automatic screenshots, device info, and error capture — you triage them in the [Bugnet dashboard](https://bugnet.io).

## Features

- **Automatic crash capture** — Unhandled errors are reported with full stack traces and log context
- **In-game widget** — A built-in overlay lets players file bug reports without leaving the game
- **Screenshot capture** — The current viewport is captured and attached to reports automatically
- **Session replay** — Screen recording encoded as GIF and uploaded alongside bug reports
- **Freeze detection** — Auto-reports when a single frame exceeds 2 seconds
- **Performance snapshots** — FPS, frame time, and memory usage attached to every report
- **Scene load tracking** — Measure and report load times for levels and scenes
- **Log capture** — Recent engine output is attached to auto-reported bugs
- **GodotSteam integration** — Automatically detects Steam ID and player name if the GodotSteam plugin is present
- **Crash-free rate analytics** — Session start/end tracking for crash-free rate metrics in the dashboard
- **Zero dependencies** — Single GDScript file, no addons or third-party libraries required

## Requirements

- Godot 4.0+
- A Bugnet account and API key ([sign up free](https://bugnet.io))

## Installation

### Quick Install (Recommended)

Run one command from your Godot project root (where `project.godot` is located):

**Linux / macOS:**

```bash
curl -s https://bugnet.io/sdks/godot/install.sh | bash
```

**Windows (PowerShell):**

```powershell
powershell -ExecutionPolicy Bypass -c "& { iwr -useb https://bugnet.io/sdks/godot/install.ps1 -OutFile $env:TEMP\bugnet.ps1; & $env:TEMP\bugnet.ps1 }"
```

This downloads `BugnetSDK.gd` into `addons/bugnet/` and registers it as an autoload singleton.

### Manual Installation

1. Download [`BugnetSDK.gd`](https://bugnet.io/sdks/godot/BugnetSDK.gd)
2. Place it in `addons/bugnet/BugnetSDK.gd` in your project
3. In Godot, go to **Project > Project Settings > Autoload**
4. Add the script with the name **`Bugnet`** and enable it

### Godot Asset Library

Search for **Bugnet** in the Godot editor's AssetLib tab, or visit the [Godot Asset Library](https://godotengine.org/asset-library/asset) page.

## Quick Start

Once installed as an autoload, you can configure Bugnet entirely from the Inspector — select the Bugnet node and set your **API Key** and **Server URL**. No code required for basic setup.

Alternatively, initialize in code:

```gdscript
func _ready():
    Bugnet.bugnet_init("sk_live_YOUR_API_KEY", "https://api.bugnet.io")
```

### Show the Bug Report Widget

Bind it to a key so players can report bugs at any time:

```gdscript
func _input(event):
    if event.is_action_pressed("ui_cancel"):  # or any key
        Bugnet.show_widget()
```

### Report a Bug from Code

```gdscript
Bugnet.report_bug(
    "Player fell through floor",
    "Happens on level 3 near the bridge section",
    "gameplay",  # category: crash, visual, gameplay, performance, audio, ui, network, other
    "high",      # priority: low, medium, high, critical
    "1. Walk to bridge\n2. Jump near edge\n3. Fall through",
    true         # include_screenshot
)
```

### Track Scene Load Times

```gdscript
Bugnet.scene_load_start("level_3")
# ... load your scene ...
Bugnet.scene_load_end("level_3")
```

### Set Player Identity

If you're not using GodotSteam (which is auto-detected), set the player identity manually:

```gdscript
Bugnet.set_player("steam_id_12345", "PlayerName")
```

## API Reference

### Properties (Inspector)

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `api_key` | `String` | `""` | Your Bugnet API key (starts with `sk_live_`) |
| `server_url` | `String` | `"https://api.bugnet.io"` | Bugnet API server URL |
| `auto_capture_errors` | `bool` | `true` | Automatically capture and report engine errors |

### Methods

| Method | Description |
|--------|-------------|
| `bugnet_init(key: String, url: String)` | Initialize the SDK (called automatically if `api_key` is set in Inspector) |
| `report_bug(title, description, category, priority, steps, include_screenshot)` | Submit a bug report (runs in background) |
| `report_error(message: String, stack: String)` | Report an error manually |
| `show_widget()` | Show the in-game bug report overlay |
| `hide_widget()` | Hide the bug report overlay |
| `set_player(steam_id: String, player_name: String)` | Set player identity for reports |
| `scene_load_start(scene_name: String)` | Mark the beginning of a scene load |
| `scene_load_end(scene_name: String)` | Mark the end of a scene load and report its duration |

### Signals

| Signal | Description |
|--------|-------------|
| `bug_reported(title: String)` | Emitted when a bug report is successfully submitted |
| `bug_report_failed(error: String)` | Emitted when a bug report fails to submit |

## How It Works

1. **Autoload singleton** — `BugnetSDK.gd` extends `Node` and runs as a Godot autoload. It is available globally as `Bugnet`.
2. **Background HTTP** — All network requests use `HTTPRequest` nodes and run asynchronously. Nothing blocks the game loop.
3. **Error monitoring** — The SDK polls the engine error log once per second and auto-reports new errors with deduplication (same error is not re-reported within 30 seconds).
4. **Session replay** — When enabled (server-side setting, paid plan), the SDK captures viewport frames at 10 FPS, encodes them as a GIF on a background thread, and uploads alongside bug reports.
5. **Widget overlay** — The bug report widget is built entirely with Godot `Control` nodes (no scenes or external assets needed). It is added to the scene tree root as an overlay.

## Server-Side Settings

Some features are controlled by your project settings in the Bugnet dashboard:

| Setting | Description |
|---------|-------------|
| **Screenshot Capture** | Attach viewport screenshots to bug reports |
| **Session Capture** | Record and upload session replays (paid plan) |
| **Auto-File Errors** | Automatically create bug reports from captured errors |

These are fetched from the server on initialization and override local defaults.

## Troubleshooting

**"SDK not initialized" warnings:**
Make sure either (a) the `api_key` export var is set in the Inspector, or (b) you call `Bugnet.bugnet_init()` before using any other method.

**No errors being captured:**
Verify `auto_capture_errors` is `true` (the default). The SDK checks the engine error log once per second — errors that occur before initialization are not captured.

**Widget not appearing:**
The widget is added to the scene tree root. If your game uses a custom viewport or canvas layer setup, the overlay may render behind other elements. Call `show_widget()` and check the remote scene tree in the Godot debugger.

**Session replay not uploading:**
Session replay requires a paid plan and must be enabled in your project's server-side settings. Check the Bugnet dashboard under **Project Settings > Session Capture**.

## Documentation

- [Full SDK docs](https://bugnet.io/docs)
- [Godot SDK page](https://bugnet.io/for/godot/)
- [Bugnet Dashboard](https://bugnet.io/app/)

## License

MIT