# ─────────────────────────────────────────────────────────────────────────────
#  Bugnet SDK for Godot 4.x
#  Add this as an Autoload singleton: Project > Project Settings > Autoload
#  Name it "Bugnet" and point to this script.
# ─────────────────────────────────────────────────────────────────────────────

extends Node

## Your Bugnet API key (starts with sk_live_)
@export var api_key: String = ""
## Bugnet API server URL
@export var server_url: String = "https://api.bugnet.io"
## Automatically capture and report errors/crashes
@export var auto_capture_errors: bool = true
## Include screenshots with reports (controlled by server settings)
var screenshot_capture: bool = false
## Record player sessions for replay (controlled by server settings, requires paid plan)
var session_capture: bool = false
## Auto-file errors as bug reports (controlled by server settings)
var auto_file_errors: bool = true

# ── Private state ────────────────────────────────────────────────────────
var _initialized: bool = false
var _widget_visible: bool = false
var _widget_panel: Control = null
var _reported_errors: Dictionary = {}
var _last_error_count: int = 0
var _logger_initialized: bool = false
var _error_check_timer: float = 0.0

# Freeze detection
var _freeze_reported: bool = false
const FREEZE_THRESHOLD_SEC: float = 2.0

# Scene/level load time tracking
var _scene_load_times: Dictionary = {}

# Log capture circular buffer
var _log_buffer: Array[String] = []
const MAX_LOG_ENTRIES: int = 100

# Steam identity (auto-detected if GodotSteam plugin is present)
var _steam_id: String = ""
var _steam_name: String = ""

# Session tracking for crash-free rate analytics
var _session_token: String = ""
var _session_crashed: bool = false

# Session replay screen recording
var _replay_frames: Array[PackedByteArray] = []
var _replay_start_time: float = 0.0
const MAX_REPLAY_FRAMES: int = 300  # ~30 seconds at 10 FPS
const FRAME_CAPTURE_SEC: float = 0.1  # 10 FPS
var _last_frame_capture_time: float = 0.0

# Threading for session replay encoding
var _replay_thread: Thread = null
var _replay_thread_result: PackedByteArray = PackedByteArray()
var _replay_pending_bug_id: String = ""
var _replay_pending_vp_size: Vector2 = Vector2.ZERO
var _replay_pending_duration: int = 0

# ── Signals ──────────────────────────────────────────────────────────────
signal bug_reported(title: String)
signal bug_report_failed(error: String)

# ── Lifecycle ────────────────────────────────────────────────────────────

func _ready() -> void:
	if api_key != "" and server_url != "":
		bugnet_init(api_key, server_url)

func _process(delta: float) -> void:
	if auto_capture_errors and _initialized and _logger_initialized:
		_error_check_timer += delta
		if _error_check_timer >= 1.0:
			_error_check_timer = 0.0
			_check_error_log()

	# Freeze detection: report if a single frame exceeds the threshold
	if _initialized and delta > FREEZE_THRESHOLD_SEC:
		if not _freeze_reported:
			_freeze_reported = true
			var ms = int(delta * 1000.0)
			var title = "[Freeze] Game frozen for %d ms" % ms
			var desc = "The game experienced a freeze of %d ms (%.2f seconds)." % [ms, delta]
			desc += "\nFPS at time of freeze: %d" % Engine.get_frames_per_second()
			desc += _get_recent_logs_section()
			_send_report(title, desc, "performance", "high", "", "")
			print("[Bugnet] Freeze detected: %d ms" % ms)
	elif _initialized and delta <= FREEZE_THRESHOLD_SEC:
		_freeze_reported = false

	if _initialized and session_capture:
		_capture_replay_frame()

func _capture_replay_frame() -> void:
	var now = Time.get_ticks_msec() / 1000.0
	if now - _last_frame_capture_time < FRAME_CAPTURE_SEC:
		return
	_last_frame_capture_time = now

	# Capture the viewport as an image
	var img = get_viewport().get_texture().get_image()
	if img == null:
		return

	# Downscale for smaller file size
	var max_width = 640
	if img.get_width() > max_width:
		var scale = float(max_width) / img.get_width()
		img.resize(max_width, int(img.get_height() * scale))

	# Encode as JPEG and store the frame
	var jpg_data = img.save_jpg_to_buffer(0.5)
	if jpg_data.size() > 0:
		_replay_frames.append(jpg_data)

		# Discard oldest frames to keep a rolling window of recent footage
		while _replay_frames.size() > MAX_REPLAY_FRAMES:
			_replay_frames.remove_at(0)

# ── Public API ───────────────────────────────────────────────────────────

## Initialize the SDK with your API key and server URL.
func bugnet_init(key: String, url: String) -> void:
	api_key = key
	server_url = url.rstrip("/")
	_initialized = true

	# Auto-detect Steam identity via GodotSteam plugin (no hard dependency)
	if Engine.has_singleton("Steam"):
		var steam = Engine.get_singleton("Steam")
		if steam.has_method("isSteamRunning") and steam.isSteamRunning():
			if steam.has_method("getSteamID"):
				_steam_id = str(steam.getSteamID()).substr(0, 30)
			if steam.has_method("getPersonaName"):
				_steam_name = steam.getPersonaName().substr(0, 100)
			if _steam_id != "":
				print("[Bugnet] Steam identity detected: ", _steam_name, " (", _steam_id, ")")

	# Hook into error output via the logger
	if auto_capture_errors:
		_last_error_count = 0
		_logger_initialized = true

	# Fetch server settings
	_fetch_settings()

	# Start a game session for crash-free rate tracking
	_session_token = _generate_uuid()
	_session_crashed = false
	_send_session_start()

	# Start session replay screen recording
	_replay_frames.clear()
	_replay_start_time = Time.get_ticks_msec() / 1000.0
	_last_frame_capture_time = 0.0

	# Connect to scene tree changes for auto-detecting scene loads
	get_tree().tree_changed.connect(_on_scene_tree_changed)

	print("[Bugnet] SDK initialized — server: ", server_url)

## Manually set the player's Steam identity (if auto-detection is unavailable).
func set_player(steam_id: String, player_name: String) -> void:
	_steam_id = steam_id.substr(0, 30)
	_steam_name = player_name.substr(0, 100)

## Show the in-game bug report widget overlay.
func show_widget() -> void:
	if _widget_panel != null:
		_widget_panel.queue_free()
	_widget_panel = _create_widget()
	get_tree().root.add_child(_widget_panel)
	_widget_visible = true

## Hide the bug report widget.
func hide_widget() -> void:
	if _widget_panel != null:
		_widget_panel.queue_free()
		_widget_panel = null
	_widget_visible = false

## Submit a bug report.
## This runs fully in the background and will not block the gameplay loop.
func report_bug(title: String, description: String,
	category: String = "other", priority: String = "medium",
	steps: String = "", include_screenshot: bool = false) -> void:

	if not _initialized:
		push_warning("[Bugnet] SDK not initialized. Call bugnet_init() first.")
		return

	# Run the entire report flow asynchronously so calling code is never blocked
	_report_bug_async(title, description, category, priority, steps, include_screenshot)

func _report_bug_async(title: String, description: String,
	category: String, priority: String,
	steps: String, include_screenshot: bool) -> void:

	var screenshot_b64 = ""
	if include_screenshot and screenshot_capture:
		screenshot_b64 = await _capture_screenshot()

	_send_report(title, description, category, priority, steps, screenshot_b64)

## Report a crash/error automatically.
func report_error(message: String, stack: String = "") -> void:
	if not auto_file_errors:
		return
	var key = str(message.hash())
	var now = Time.get_ticks_msec() / 1000.0
	if _reported_errors.has(key) and now - _reported_errors[key] < 30.0:
		return
	_reported_errors[key] = now

	# Mark session as crashed for analytics
	if not _session_crashed:
		_session_crashed = true
		_send_session_end()

	var title = "[Error] " + message.substr(0, 120)
	var desc = message
	if stack != "":
		desc += "\n\n--- Stack Trace ---\n" + stack
	desc += _get_recent_logs_section()

	# Capture a screenshot automatically if screenshot capture is enabled
	_report_error_async(title, desc)

func _report_error_async(title: String, desc: String) -> void:
	var screenshot_b64 = ""
	if screenshot_capture:
		screenshot_b64 = await _capture_screenshot()
	_send_report(title, desc, "crash", "critical", "", screenshot_b64)

# ── Scene/Level Load Time Tracking ──────────────────────────────────────

## Call before starting to load a scene to begin tracking load time.
func scene_load_start(scene_name: String) -> void:
	_scene_load_times[scene_name] = Time.get_ticks_msec()
	print("[Bugnet] Scene load started: ", scene_name)

## Call after a scene finishes loading to record the load duration.
func scene_load_end(scene_name: String) -> void:
	if not _scene_load_times.has(scene_name):
		push_warning("[Bugnet] scene_load_end called without matching scene_load_start for: ", scene_name)
		return
	var start_ms: int = _scene_load_times[scene_name]
	var duration_ms: int = Time.get_ticks_msec() - start_ms
	_scene_load_times.erase(scene_name)
	print("[Bugnet] Scene load finished: %s in %d ms" % [scene_name, duration_ms])

	if not _initialized:
		return

	# Send a performance snapshot with scene load metrics
	var perf_data = {
		"fps": Engine.get_frames_per_second(),
		"frame_time_ms": 1000.0 / max(Engine.get_frames_per_second(), 1),
		"memory_used_mb": OS.get_static_memory_usage() / (1024.0 * 1024.0),
		"custom_metrics": {
			"scene_name": scene_name,
			"scene_load_time_ms": duration_ms
		}
	}

	var body = JSON.stringify(perf_data)
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_perf_response.bind(http))
	http.request(
		server_url + "/api/perf/snapshot",
		["Content-Type: application/json", "X-API-Key: " + api_key],
		HTTPClient.METHOD_POST,
		body
	)

func _on_scene_tree_changed() -> void:
	# Auto-detect scene changes via tree_changed signal
	var current_scene = get_tree().current_scene
	if current_scene == null:
		return
	var scene_path = current_scene.scene_file_path
	if scene_path == "":
		return
	# Use the scene file path as a unique key; auto-track if not already being tracked manually
	if not _scene_load_times.has(scene_path):
		# Record the scene arrival time as a minimal load-end event
		var perf_data = {
			"fps": Engine.get_frames_per_second(),
			"frame_time_ms": 1000.0 / max(Engine.get_frames_per_second(), 1),
			"memory_used_mb": OS.get_static_memory_usage() / (1024.0 * 1024.0),
			"custom_metrics": {
				"scene_name": scene_path.get_file(),
				"scene_detected": true
			}
		}
		var body = JSON.stringify(perf_data)
		var http = HTTPRequest.new()
		add_child(http)
		http.request_completed.connect(_on_perf_response.bind(http))
		http.request(
			server_url + "/api/perf/snapshot",
			["Content-Type: application/json", "X-API-Key: " + api_key],
			HTTPClient.METHOD_POST,
			body
		)

# ── Log Capture ─────────────────────────────────────────────────────────

func _add_log_entry(message: String) -> void:
	var timestamp = Time.get_datetime_string_from_system()
	_log_buffer.append("[%s] %s" % [timestamp, message])
	while _log_buffer.size() > MAX_LOG_ENTRIES:
		_log_buffer.remove_at(0)

func _get_recent_logs_section() -> String:
	if _log_buffer.size() == 0:
		return ""
	return "\n\n--- Recent Logs ---\n" + "\n".join(_log_buffer)

# ── Error Log Capture ────────────────────────────────────────────────────

func _check_error_log() -> void:
	# Godot 4.x: read the engine log file for new error lines
	var log_path = OS.get_user_data_dir().path_join("logs/godot.log")
	if not FileAccess.file_exists(log_path):
		return
	var file = FileAccess.open(log_path, FileAccess.READ)
	if file == null:
		return
	var content = file.get_as_text()
	file.close()

	var lines = content.split("\n")
	var current_count = lines.size()
	if current_count <= _last_error_count:
		_last_error_count = current_count
		return

	# Check only new lines since last check and feed into log buffer
	for i in range(_last_error_count, current_count):
		var line = lines[i].strip_edges()
		if line == "":
			continue
		# Capture all log lines into the circular buffer
		_add_log_entry(line)
		# Detect error/crash lines in the Godot log
		var is_error = false
		var error_type = "Error"
		for keyword in ["ERROR:", "SCRIPT ERROR:", "FATAL:", "Segmentation fault", "Crashed"]:
			if line.find(keyword) >= 0:
				is_error = true
				if keyword == "SCRIPT ERROR:":
					error_type = "Script Error"
				elif keyword == "FATAL:" or keyword == "Crashed" or keyword == "Segmentation fault":
					error_type = "Crash"
				break
		if is_error:
			# Gather context: include a few lines around the error
			var context_start = max(0, i - 2)
			var context_end = min(lines.size() - 1, i + 5)
			var context_lines = []
			for j in range(context_start, context_end + 1):
				context_lines.append(lines[j])
			var stack = "\n".join(context_lines)
			report_error("[" + error_type + "] " + line.substr(0, 120), stack)

	_last_error_count = current_count

# ── Screenshot ───────────────────────────────────────────────────────────

func _capture_screenshot() -> String:
	await RenderingServer.frame_post_draw
	var img = get_viewport().get_texture().get_image()
	var png = img.save_png_to_buffer()
	return "data:image/png;base64," + Marshalls.raw_to_base64(png)

# ── Network ──────────────────────────────────────────────────────────────

func _fetch_settings() -> void:
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_settings_response.bind(http))
	http.request(
		server_url + "/api/bugs/settings",
		["X-API-Key: " + api_key],
		HTTPClient.METHOD_GET
	)

func _on_settings_response(_result: int, code: int, _headers: PackedStringArray,
	body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		if json and json.has("data") and json["data"].has("screenshot_capture"):
			screenshot_capture = json["data"]["screenshot_capture"]
			if json["data"].has("session_capture"):
				session_capture = json["data"]["session_capture"]
			if json["data"].has("auto_file_errors"):
				auto_file_errors = json["data"]["auto_file_errors"]
			print("[Bugnet] Screenshot capture: ", screenshot_capture, " | Session capture: ", session_capture, " | Auto-file errors: ", auto_file_errors)

func _send_report(title: String, description: String, category: String,
	priority: String, steps: String, screenshot: String) -> void:

	var payload = {
		"title": title.substr(0, 300),
		"description": description,
		"category": category,
		"priority": priority,
		"steps_to_reproduce": steps,
		"platform": OS.get_name().substr(0, 50),
		"game_version": str(ProjectSettings.get_setting("application/config/version", "unknown")).substr(0, 50),
		"os_info": (OS.get_name() + " " + OS.get_version()).substr(0, 100),
		"device_info": OS.get_model_name().substr(0, 200)
	}
	if screenshot != "":
		payload["screenshot"] = screenshot
	if _steam_id != "":
		payload["steam_id"] = _steam_id
		payload["reporter_name"] = _steam_name

	var body = JSON.stringify(payload)
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_submit_response.bind(http, title))

	http.request(
		server_url + "/api/bugs/submit",
		["Content-Type: application/json", "X-API-Key: " + api_key],
		HTTPClient.METHOD_POST,
		body
	)

func _on_submit_response(_result: int, code: int, _headers: PackedStringArray,
	body_bytes: PackedByteArray, http: HTTPRequest, title: String) -> void:
	http.queue_free()
	if code == 200 or code == 201:
		print("[Bugnet] Bug reported: ", title)
		bug_reported.emit(title)
		# Send performance snapshot and session replay alongside the bug report
		var json = JSON.parse_string(body_bytes.get_string_from_utf8())
		if json and json.has("data") and json["data"].has("id"):
			_send_perf_snapshot(json["data"]["id"])
			_send_session_replay(json["data"]["id"])
	else:
		push_error("[Bugnet] Failed to report bug: HTTP " + str(code))
		bug_report_failed.emit("HTTP " + str(code))

# ── Session Tracking (Crash Analytics) ──────────────────────────────────

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_EXIT_TREE:
		if _initialized and _session_token != "":
			_send_session_end()
		# Clean up replay encoding thread
		if _replay_thread != null and _replay_thread.is_started():
			_replay_thread.wait_to_finish()
			_replay_thread = null

func _send_session_start() -> void:
	var payload = {
		"api_key": api_key,
		"session_token": _session_token,
		"platform": OS.get_name(),
		"game_version": ProjectSettings.get_setting("application/config/version", "unknown"),
		"device_info": OS.get_model_name(),
		"os_info": OS.get_name() + " " + OS.get_version()
	}
	var body = JSON.stringify(payload)
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_session_response.bind(http, "start"))
	http.request(
		server_url + "/api/sessions/start",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body
	)

func _send_session_end() -> void:
	var payload = {
		"api_key": api_key,
		"session_token": _session_token,
		"crashed": _session_crashed
	}
	var body = JSON.stringify(payload)
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_session_response.bind(http, "end"))
	http.request(
		server_url + "/api/sessions/end",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		body
	)

func _on_session_response(_result: int, code: int, _headers: PackedStringArray,
	_body: PackedByteArray, http: HTTPRequest, action: String) -> void:
	http.queue_free()
	if code == 200 or code == 201:
		print("[Bugnet] Session ", action, " recorded")
	else:
		push_warning("[Bugnet] Session ", action, " failed: HTTP ", code)

func _generate_uuid() -> String:
	var hex = "0123456789abcdef"
	var result = ""
	for i in 32:
		result += hex[randi() % 16]
		if i == 7 or i == 11 or i == 15 or i == 19:
			result += "-"
	return result

# ── Widget UI ────────────────────────────────────────────────────────────

func _create_widget() -> Control:
	var overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.5)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)

	# CenterContainer keeps the panel centered at any resolution
	var center = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)

	# Limit panel width to 90% of viewport or 420px, whichever is smaller
	var vp_size = get_viewport().get_visible_rect().size
	var panel_w = mini(420, int(vp_size.x * 0.9))
	var panel_h = mini(540, int(vp_size.y * 0.9))

	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(panel_w, 0)
	center.add_child(panel)

	# ScrollContainer so the form is usable even on very small screens
	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(panel_w, panel_h)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)

	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(vbox)

	# Header
	var header = Label.new()
	header.text = "Report a Bug"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_theme_font_size_override("font_size", 20)
	vbox.add_child(header)

	# Title
	vbox.add_child(_make_label("Title *"))
	var title_input = LineEdit.new()
	title_input.placeholder_text = "Short, descriptive title"
	title_input.name = "TitleInput"
	title_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(title_input)

	# Description
	vbox.add_child(_make_label("Description *"))
	var desc_input = TextEdit.new()
	desc_input.placeholder_text = "What happened?"
	desc_input.custom_minimum_size.y = 80
	desc_input.name = "DescInput"
	desc_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(desc_input)

	# Steps
	vbox.add_child(_make_label("Steps to Reproduce"))
	var steps_input = TextEdit.new()
	steps_input.placeholder_text = "1. Go to...\n2. Click on..."
	steps_input.custom_minimum_size.y = 60
	steps_input.name = "StepsInput"
	steps_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(steps_input)

	# Category
	vbox.add_child(_make_label("Category"))
	var cat_option = OptionButton.new()
	cat_option.name = "CategoryOption"
	for cat in ["crash", "visual", "gameplay", "performance", "audio", "ui", "network", "other"]:
		cat_option.add_item(cat)
	cat_option.selected = 7
	vbox.add_child(cat_option)

	# Priority
	vbox.add_child(_make_label("Priority"))
	var pri_option = OptionButton.new()
	pri_option.name = "PriorityOption"
	for pri in ["low", "medium", "high", "critical"]:
		pri_option.add_item(pri)
	pri_option.selected = 1
	vbox.add_child(pri_option)

	# Buttons
	var btn_row = HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)

	var submit_btn = Button.new()
	submit_btn.text = "Submit"
	submit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	submit_btn.pressed.connect(_on_widget_submit.bind(overlay))
	btn_row.add_child(submit_btn)

	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(hide_widget)
	btn_row.add_child(cancel_btn)

	vbox.add_child(btn_row)

	# Status label
	var status = Label.new()
	status.name = "StatusLabel"
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(status)

	return overlay

func _on_widget_submit(overlay: Control) -> void:
	var title_input = overlay.find_child("TitleInput", true, false) as LineEdit
	var desc_input = overlay.find_child("DescInput", true, false) as TextEdit
	var steps_input = overlay.find_child("StepsInput", true, false) as TextEdit
	var cat_option = overlay.find_child("CategoryOption", true, false) as OptionButton
	var pri_option = overlay.find_child("PriorityOption", true, false) as OptionButton
	var status_label = overlay.find_child("StatusLabel", true, false) as Label

	if title_input.text.strip_edges() == "" or desc_input.text.strip_edges() == "":
		status_label.text = "Title and description are required."
		return

	report_bug(
		title_input.text,
		desc_input.text,
		cat_option.get_item_text(cat_option.selected),
		pri_option.get_item_text(pri_option.selected),
		steps_input.text,
		screenshot_capture
	)
	hide_widget()

# ── Performance Profiling Snapshot ────────────────────────────────────

func _send_perf_snapshot(bug_report_id: String) -> void:
	var perf_data = {
		"bug_report_id": bug_report_id,
		"fps": Engine.get_frames_per_second(),
		"frame_time_ms": 1000.0 / max(Engine.get_frames_per_second(), 1),
		"memory_used_mb": OS.get_static_memory_usage() / (1024.0 * 1024.0),
	}

	var body = JSON.stringify(perf_data)
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_perf_response.bind(http))
	http.request(
		server_url + "/api/perf/snapshot",
		["Content-Type: application/json", "X-API-Key: " + api_key],
		HTTPClient.METHOD_POST,
		body
	)

func _on_perf_response(_result: int, code: int, _headers: PackedStringArray,
	_body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if code == 201:
		print("[Bugnet] Performance snapshot sent")
	else:
		push_warning("[Bugnet] Failed to send perf snapshot: HTTP ", code)

# ── Session Replay Submission ──────────────────────────────────────────

func _send_session_replay(bug_report_id: String) -> void:
	if not session_capture:
		return
	if _replay_frames.size() == 0:
		return

	# Wait for any previous replay thread to finish before starting a new one
	if _replay_thread != null and _replay_thread.is_started():
		_replay_thread.wait_to_finish()
		_replay_thread = null

	# Copy frames and reset immediately so recording can continue without lag
	var frames_to_send = _replay_frames.duplicate()
	_replay_pending_duration = int((Time.get_ticks_msec() / 1000.0 - _replay_start_time))
	_replay_pending_vp_size = get_viewport().get_visible_rect().size
	_replay_pending_bug_id = bug_report_id
	_replay_frames.clear()
	_replay_start_time = Time.get_ticks_msec() / 1000.0

	# Pre-decode JPEG frames on main thread (Image API is not fully thread-safe)
	var decoded_frames: Array[PackedByteArray] = []
	var out_w = mini(int(_replay_pending_vp_size.x), 640)
	var out_h = int(out_w * float(_replay_pending_vp_size.y) / float(_replay_pending_vp_size.x)) if _replay_pending_vp_size.x > 0 else out_w
	for jpg_data in frames_to_send:
		var img = Image.new()
		if img.load_jpg_from_buffer(jpg_data) != OK:
			continue
		if img.get_width() != out_w or img.get_height() != out_h:
			img.resize(out_w, out_h)
		decoded_frames.append(img.get_data())

	# Run GIF encoding on a separate thread to avoid blocking the game loop
	_replay_thread = Thread.new()
	_replay_thread.start(_encode_replay_thread.bind(decoded_frames, out_w, out_h))

	# Poll for thread completion without blocking
	_poll_replay_thread()

func _poll_replay_thread() -> void:
	if _replay_thread == null or not _replay_thread.is_started():
		return
	if not _replay_thread.is_alive():
		_replay_thread_result = _replay_thread.wait_to_finish()
		_replay_thread = null
		_upload_session_replay()
	else:
		# Check again next frame without blocking
		get_tree().create_timer(0.05).timeout.connect(_poll_replay_thread)

func _encode_replay_thread(decoded_frames: Array[PackedByteArray], width: int, height: int) -> PackedByteArray:
	return _encode_raw_frames_to_gif(decoded_frames, width, height)

func _upload_session_replay() -> void:
	var gif_data = _replay_thread_result
	_replay_thread_result = PackedByteArray()
	if gif_data.size() == 0:
		return

	var bug_report_id = _replay_pending_bug_id
	var vp_size = _replay_pending_vp_size
	var duration_sec = _replay_pending_duration

	var metadata = JSON.stringify({
		"platform": OS.get_name(),
		"resolution": str(int(vp_size.x)) + "x" + str(int(vp_size.y))
	})

	# Build multipart form body
	var boundary = "----BugnetBoundary" + _generate_uuid().replace("-", "")
	var body = PackedByteArray()

	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array("Content-Disposition: form-data; name=\"bug_report_id\"\r\n\r\n".to_utf8_buffer())
	body.append_array((bug_report_id + "\r\n").to_utf8_buffer())

	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array("Content-Disposition: form-data; name=\"duration_sec\"\r\n\r\n".to_utf8_buffer())
	body.append_array((str(duration_sec) + "\r\n").to_utf8_buffer())

	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array("Content-Disposition: form-data; name=\"metadata\"\r\n\r\n".to_utf8_buffer())
	body.append_array((metadata + "\r\n").to_utf8_buffer())

	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array("Content-Disposition: form-data; name=\"file\"; filename=\"session-replay.gif\"\r\n".to_utf8_buffer())
	body.append_array("Content-Type: image/gif\r\n\r\n".to_utf8_buffer())
	body.append_array(gif_data)
	body.append_array(("\r\n--" + boundary + "--\r\n").to_utf8_buffer())

	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_replay_response.bind(http))
	http.request_raw(
		server_url + "/api/session-replays",
		["Content-Type: multipart/form-data; boundary=" + boundary, "X-API-Key: " + api_key],
		HTTPClient.METHOD_POST,
		body
	)

func _encode_raw_frames_to_gif(raw_frames: Array[PackedByteArray], out_w: int, out_h: int) -> PackedByteArray:
	# Thread-safe GIF encoder that works with pre-decoded raw RGBA pixel data.
	var gif = PackedByteArray()

	# GIF89a header
	gif.append_array("GIF89a".to_utf8_buffer())
	gif.append(out_w & 0xFF)
	gif.append((out_w >> 8) & 0xFF)
	gif.append(out_h & 0xFF)
	gif.append((out_h >> 8) & 0xFF)
	gif.append(0xF6)  # GCT flag, 7-bit (128 colors)
	gif.append(0)     # bg color
	gif.append(0)     # pixel aspect ratio

	# Global color table (128 entries = 384 bytes)
	for i in range(128):
		var r = ((i >> 4) & 0x07) * 36
		var g = ((i >> 1) & 0x07) * 36
		var b = (i & 0x01) * 255
		gif.append(r)
		gif.append(g)
		gif.append(b)

	# Netscape looping extension
	gif.append(0x21)  # extension
	gif.append(0xFF)  # application
	gif.append(11)
	gif.append_array("NETSCAPE2.0".to_utf8_buffer())
	gif.append(3)
	gif.append(1)
	gif.append(0)  # loop count low
	gif.append(0)  # loop count high
	gif.append(0)  # terminator

	for raw_data in raw_frames:
		# Raw data is RGBA, 4 bytes per pixel
		var expected_size = out_w * out_h * 4
		if raw_data.size() < expected_size:
			continue

		# Graphic control extension (100ms delay)
		gif.append(0x21)
		gif.append(0xF9)
		gif.append(4)
		gif.append(0x00)
		gif.append(10)   # delay low (centiseconds)
		gif.append(0)    # delay high
		gif.append(0)    # transparent color
		gif.append(0)    # terminator

		# Image descriptor
		gif.append(0x2C)
		gif.append(0); gif.append(0)  # left
		gif.append(0); gif.append(0)  # top
		gif.append(out_w & 0xFF); gif.append((out_w >> 8) & 0xFF)
		gif.append(out_h & 0xFF); gif.append((out_h >> 8) & 0xFF)
		gif.append(0)  # no local color table

		# LZW minimum code size
		gif.append(7)

		# Quantize pixels from raw RGBA data and write as sub-blocks
		var pixels = PackedByteArray()
		for y in range(out_h):
			for x in range(out_w):
				var offset = (y * out_w + x) * 4
				var r_val = raw_data[offset]
				var g_val = raw_data[offset + 1]
				var b_val = raw_data[offset + 2]
				var idx = (int(r_val / 255.0 * 7) << 4) | (int(g_val / 255.0 * 7) << 1) | int(b_val / 255.0)
				pixels.append(clampi(idx, 0, 127))

		var pos = 0
		while pos < pixels.size():
			var block_size = mini(254, pixels.size() - pos)
			gif.append(block_size + 1)
			gif.append(0x80)  # clear code
			gif.append_array(pixels.slice(pos, pos + block_size))
			pos += block_size
		gif.append(1)
		gif.append(0x81)  # EOI
		gif.append(0)     # block terminator

	# GIF trailer
	gif.append(0x3B)
	return gif

func _encode_frames_to_gif(frames: Array[PackedByteArray], width: int, height: int) -> PackedByteArray:
	# Encode captured JPEG frames as a minimal animated GIF.
	# Uses a simple 128-color palette with uncompressed LZW.
	var gif = PackedByteArray()

	# Determine output dimensions (capped at 640px wide)
	var out_w = mini(width, 640)
	var out_h = int(out_w * float(height) / float(width)) if width > 0 else out_w

	# GIF89a header
	gif.append_array("GIF89a".to_utf8_buffer())
	gif.append(out_w & 0xFF)
	gif.append((out_w >> 8) & 0xFF)
	gif.append(out_h & 0xFF)
	gif.append((out_h >> 8) & 0xFF)
	gif.append(0xF6)  # GCT flag, 7-bit (128 colors)
	gif.append(0)     # bg color
	gif.append(0)     # pixel aspect ratio

	# Global color table (128 entries = 384 bytes)
	for i in range(128):
		var r = ((i >> 4) & 0x07) * 36
		var g = ((i >> 1) & 0x07) * 36
		var b = (i & 0x01) * 255
		gif.append(r)
		gif.append(g)
		gif.append(b)

	# Netscape looping extension
	gif.append(0x21)  # extension
	gif.append(0xFF)  # application
	gif.append(11)
	gif.append_array("NETSCAPE2.0".to_utf8_buffer())
	gif.append(3)
	gif.append(1)
	gif.append(0)  # loop count low
	gif.append(0)  # loop count high
	gif.append(0)  # terminator

	for jpg_data in frames:
		var img = Image.new()
		if img.load_jpg_from_buffer(jpg_data) != OK:
			continue
		if img.get_width() != out_w or img.get_height() != out_h:
			img.resize(out_w, out_h)

		# Graphic control extension (100ms delay)
		gif.append(0x21)
		gif.append(0xF9)
		gif.append(4)
		gif.append(0x00)
		gif.append(10)   # delay low (centiseconds)
		gif.append(0)    # delay high
		gif.append(0)    # transparent color
		gif.append(0)    # terminator

		# Image descriptor
		gif.append(0x2C)
		gif.append(0); gif.append(0)  # left
		gif.append(0); gif.append(0)  # top
		gif.append(out_w & 0xFF); gif.append((out_w >> 8) & 0xFF)
		gif.append(out_h & 0xFF); gif.append((out_h >> 8) & 0xFF)
		gif.append(0)  # no local color table

		# LZW minimum code size
		gif.append(7)

		# Quantize pixels and write as sub-blocks
		var pixels = PackedByteArray()
		for y in range(out_h):
			for x in range(out_w):
				var c = img.get_pixel(x, y)
				var idx = (int(c.r * 7) << 4) | (int(c.g * 7) << 1) | int(c.b)
				pixels.append(clampi(idx, 0, 127))

		var pos = 0
		while pos < pixels.size():
			var block_size = mini(254, pixels.size() - pos)
			gif.append(block_size + 1)
			gif.append(0x80)  # clear code
			gif.append_array(pixels.slice(pos, pos + block_size))
			pos += block_size
		gif.append(1)
		gif.append(0x81)  # EOI
		gif.append(0)     # block terminator

	# GIF trailer
	gif.append(0x3B)
	return gif

func _on_replay_response(_result: int, code: int, _headers: PackedStringArray,
	_body: PackedByteArray, http: HTTPRequest) -> void:
	http.queue_free()
	if code == 201:
		print("[Bugnet] Session replay video sent")
	else:
		push_warning("[Bugnet] Failed to send session replay: HTTP ", code)

func _make_label(text: String) -> Label:
	var l = Label.new()
	l.text = text
	return l
