@tool
extends Control
class_name EditorConsole

const LOG_LEVEL_INFO := 0
const LOG_LEVEL_WARNING := 1
const LOG_LEVEL_ERROR := 2
const LOG_LEVEL_SUCCESS := 3

# Meta key for the log line buffer. We store the buffer in node metadata
# rather than as a class field so that hot-reload of @tool scripts doesn't
# leave the buffer uninitialized on existing instances. Metadata is owned
# by Object (not Script) and survives script reloads - adding new state
# this way means end users don't have to disable+re-enable the plugin
# whenever we touch this file.
const _META_LOG_BUFFER := "debug_console_log_buffer"
# bash polish - banner is emitted once per fresh _ready() of an instance.
# Tracked in meta so a @tool script reload that re-enters _ready() on the
# same Control instance doesn't double-banner. New EditorConsole instances
# always re-banner because they start without the meta flag.
const _META_BANNER_SHOWN := "debug_console_banner_shown"

# bash polish - terminal palette.
const _COLOR_BANNER_TEXT := "#5FBEE0"
const _COLOR_PROMPT_DIM := "#606060"
const _COLOR_PROMPT_USER := "#44FF44"
const _COLOR_PROMPT_HOST := "#44FF44"
const _COLOR_PROMPT_CWD := "#5FBEE0"
const _COLOR_COMMAND_NAME := "#F7DC6F"
const _COLOR_FLAG := "#FF6B9D"
const _COLOR_PIPE := "#FF6B9D"
const _COLOR_STRING_LITERAL := "#5FBEE0"
const _REVERSE_SEARCH_PROMPT_PREFIX := "(reverse-i-search)`"

@onready var output_text: RichTextLabel = $VBox/OutputPanel/OutputText
@onready var input_line: LineEdit = $VBox/InputPanel/InputLine
@onready var send_button: Button = $VBox/InputPanel/SendButton
@onready var clear_button: Button = $VBox/InputPanel/ClearButton
@onready var autocomplete_popup: PanelContainer = $AutocompletePopup
@onready var autocomplete_list: ItemList = $AutocompletePopup/AutocompleteList
# bash polish - optional in-panel hint Label for reverse-search mode.
@onready var reverse_search_hint: Label = get_node_or_null("VBox/InputPanel/ReverseSearchHint") as Label

var command_history: Array[String] = []
var history_index: int = -1
var max_output_lines: int = 1000

# - injected by plugin.gd at startup. When non-null, the EditorConsole
# loads its initial command_history from disk on set_persistence() and saves
# back after every successful command submission. Tests can inject a stub
# RefCounted that exposes save_history()/load_history() to verify the wiring
# without touching the real user:// file.
const COMMAND_HISTORY_CAP := 500
var _persistence: Object = null
var autocomplete_index: int = -1
var current_autocomplete_options: Array[String] = []

var _last_autocomplete_word: String = ""
var _matching_commands: Array[String] = []
var _autocomplete_mode: String = "commands"

# popup-driven autocomplete state. All fields are ephemeral session state
# that resets on every interaction, so plain class fields are safe - there is
# nothing to preserve across @tool script reloads.
var _user_draft: String = ""
var _popup_open: bool = false
# Test-tracking: last shortcut routed through _on_input_line_gui_input.
var _last_input_action: String = ""
# Suppresses text_changed signal during programmatic writes to input_line.
var _suppress_text_changed: bool = false
# Defers preview of index 0 until first Tab/Down after popup opens.
var _preview_pending: bool = false

# bash polish - reverse-history-search ephemeral state. Reset on every
# _enter / _exit transition; no need to survive @tool reload.
var _reverse_search_active: bool = false
var _reverse_search_query: String = ""
# Index in command_history where the last match was found. The next backward
# step starts from index - 1 so repeated Ctrl+R walks older entries.
var _reverse_search_index: int = -1
# LineEdit state captured on entry so Esc restores the user's pre-search
# input verbatim (text + caret + placeholder).
var _reverse_search_pre_input: String = ""
var _reverse_search_pre_caret: int = 0
var _reverse_search_pre_placeholder: String = ""

# readline: last killed text (single-slot kill ring, per-instance).
var _kill_ring: String = ""

const _MAX_POPUP_ITEMS := 12

func _command_registry() -> Node:
	return get_node_or_null("/root/CommandRegistry")

func _ready():
	if not Engine.is_editor_hint():
		return
	add_to_group("EditorConsole")  # Allows `font_size` command to locate us
	
	input_line.placeholder_text = "Enter command..."
	input_line.gui_input.connect(_on_input_line_gui_input)
	input_line.text_changed.connect(_on_input_text_changed)
	input_line.focus_exited.connect(_on_input_focus_exited)
	input_line.focus_mode = Control.FOCUS_ALL
	# bash polish - terminal-style blinking caret.
	input_line.caret_blink = true
	input_line.caret_blink_interval = 0.5
	send_button.pressed.connect(_on_send_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	
	output_text.focus_mode = Control.FOCUS_NONE
	output_text.bbcode_enabled = true
	output_text.scroll_following = true
	#  meta_clicked fires when the user clicks a [url=...] tag in the
	# RichTextLabel. We route to a handler that opens recognized resource
	# types in the appropriate editor panel.
	if not output_text.meta_clicked.is_connected(_on_output_meta_clicked):
		output_text.meta_clicked.connect(_on_output_meta_clicked)
	
	# bash polish - high-contrast off-white text on dark panel.
	output_text.add_theme_color_override("default_color", Color("#E0E0E0"))
	output_text.add_theme_color_override("font_color", Color("#E0E0E0"))
	output_text.add_theme_font_size_override("normal_font_size", 17)
	output_text.add_theme_constant_override("line_separation", 20)
	output_text.add_theme_constant_override("text_highlight_v_padding", 0)
	var output_panel: Panel = output_text.get_parent() as Panel
	if output_panel:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color("#1E1E1E")
		sb.corner_radius_top_left = 4
		sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4
		sb.corner_radius_bottom_right = 4
		output_panel.add_theme_stylebox_override("panel", sb)
	if is_instance_valid(reverse_search_hint):
		reverse_search_hint.visible = false
	
	if is_instance_valid(autocomplete_list):
		autocomplete_list.item_clicked.connect(_on_autocomplete_item_clicked)
		autocomplete_list.item_activated.connect(_on_autocomplete_item_activated)
	if is_instance_valid(autocomplete_popup):
		autocomplete_popup.visible = false
	resized.connect(_on_self_resized)
	
	# bash polish - multi-line welcome banner.
	_emit_welcome_banner()

func focus_command_input():
	if not is_inside_tree() or not input_line:
		return

	input_line.call_deferred("grab_focus")
	call_deferred("_apply_input_caret")

# - accept an external persistence manager (typically a
# DebugConsolePersistenceManager) so the editor console can rehydrate
# command_history on startup. Defensive against null and against stubs that
# don't fully implement the interface so tests can pass a minimal RefCounted.
# Loaded entries are normalized via str() and clamped to COMMAND_HISTORY_CAP
# so an oversized on-disk file never grows the in-memory buffer past the cap.
func set_persistence(p: Object) -> void:
	_persistence = p
	if p == null or not p.has_method("load_history"):
		return
	var loaded: Variant = p.load_history()
	if not (loaded is Array):
		return
	command_history.clear()
	for entry in (loaded as Array):
		command_history.append(str(entry))
	if command_history.size() > COMMAND_HISTORY_CAP:
		command_history = command_history.slice(-COMMAND_HISTORY_CAP)
	history_index = command_history.size()

func _apply_input_caret():
	if not input_line:
		return
	input_line.caret_column = input_line.text.length()

func _on_send_pressed():
	_execute_command(input_line.text)

func _on_clear_pressed():
	clear_output()

func _execute_command(command: String):
	if command.strip_edges().is_empty():
		return
	
	#  skip consecutive duplicates so up-arrow history stays useful, cap
	# at COMMAND_HISTORY_CAP entries (slice the oldest), and forward the new
	# state to the persistence layer if one was injected. history_index always
	# resets so up-arrow next starts at the most recent entry, even on a dup.
	var is_dup: bool = not command_history.is_empty() and command_history[command_history.size() - 1] == command
	if not is_dup:
		command_history.append(command)
		if command_history.size() > COMMAND_HISTORY_CAP:
			command_history = command_history.slice(-COMMAND_HISTORY_CAP)
		if _persistence and _persistence.has_method("save_history"):
			_persistence.save_history(command_history)
	history_index = command_history.size()
	
	add_log_message(_render_bash_prompt(command), LOG_LEVEL_INFO)
	
	var registry := _command_registry()
	if not registry:
		add_log_message("Command registry is not available.", LOG_LEVEL_ERROR)
		return

	var result = registry.execute_command(command)
	var result_text = "" if result == null else str(result)
	if not result_text.is_empty():
		add_log_message(result_text, LOG_LEVEL_INFO)
	
	input_line.clear()
	
	autocomplete_index = -1
	current_autocomplete_options.clear()
	_last_autocomplete_word = ""
	_matching_commands.clear()
	_dismiss_autocomplete_popup(false)
	
	focus_command_input()

func add_log_message(message: String, level: int = LOG_LEVEL_INFO):
	if not output_text:
		return
	var buffer: Array = _ensure_log_buffer()
	
	var color = _get_level_color(level)
	#  per-token category colorization (paths, numbers, Error/Warning
	# prefix). Runs BEFORE the level wrap so the outer color applies to any
	# uncolorized residue. _colorize_message no-ops when the caller already
	# embedded [color=...] tags.
	var decorated: String = _colorize_message(message)
	var formatted_line = "[color=%s]%s[/color]\n" % [color, decorated]
	output_text.append_text(formatted_line)
	buffer.append(formatted_line)
	
	if buffer.size() > max_output_lines:
		var trimmed: Array = buffer.slice(-max_output_lines)
		set_meta(_META_LOG_BUFFER, trimmed)
		output_text.clear()
		for line in trimmed:
			output_text.append_text(line)

func clear_output():
	if output_text:
		output_text.clear()
	set_meta(_META_LOG_BUFFER, [])

# Public accessor for the buffer; tests should call this instead of poking
# at internal storage so they remain stable across the field/meta refactor.
func get_log_buffer() -> Array:
	return _ensure_log_buffer()

# Returns the array stored in metadata, creating it on first access. The
# returned reference is live - mutating it (append/erase) mutates the meta
# storage. Use set_meta(_META_LOG_BUFFER, ...) to swap in a new array.
func _ensure_log_buffer() -> Array:
	if not has_meta(_META_LOG_BUFFER):
		set_meta(_META_LOG_BUFFER, [])
	return get_meta(_META_LOG_BUFFER)

func _get_level_color(level: int) -> String:
	match level:
		LOG_LEVEL_INFO: return "#808080"
		LOG_LEVEL_WARNING: return "#FFAA00"
		LOG_LEVEL_ERROR: return "#FF4444"
		LOG_LEVEL_SUCCESS: return "#44FF44"
		_: return "#FFFFFF"

# ---------------- T2.2 output renderer helpers ----------------
# Per-token category colorization plus clickable [url=...] wrapping for paths.
# All scanning runs once over the original message and collects non-overlapping
# (start, end, replacement) edits, which are then applied right-to-left so
# earlier positions stay valid. Hand-rolled instead of regex to keep per-log
# overhead negligible (regex compile + execute is overkill for these patterns).

const _COLOR_PATH := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_ERROR_TOKEN := "#FF4444"
const _COLOR_WARNING_TOKEN := "#FFAA00"

func _colorize_message(message: String) -> String:
	# Pre-colored caller - assume they know what they're doing and don't
	# re-wrap. This also protects us from accidentally matching the hex
	# digits inside an existing [color=#...] tag.
	if message.contains("[color="):
		return message
	if message.is_empty():
		return message
	
	var edits: Array = []
	var skip_ranges: Array = []
	
	var prefix_edit: Array = _detect_error_warning_prefix(message)
	if prefix_edit.size() == 3:
		edits.append(prefix_edit)
		skip_ranges.append([int(prefix_edit[0]), int(prefix_edit[1])])
	
	_detect_paths(message, edits, skip_ranges, true)
	_detect_numbers(message, edits, skip_ranges)
	
	# Apply edits right-to-left so untouched indices stay valid.
	edits.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	var result: String = message
	for e in edits:
		var start: int = int(e[0])
		var end_pos: int = int(e[1])
		var repl: String = str(e[2])
		result = result.substr(0, start) + repl + result.substr(end_pos)
	return result

# Returns [start, end, replacement] for an Error/Warning prefix or [] if none.
# Case-sensitive: matches "Error", "ERROR", "Warning", "WARNING". The token must
# be at index 0 and followed by a non-letter, non-digit character (or end of
# string) so substrings inside identifiers like "Errors" or "WarningSign" are
# left alone.
func _detect_error_warning_prefix(message: String) -> Array:
	var candidates: Array = [
		{"token": "Error", "color": _COLOR_ERROR_TOKEN},
		{"token": "ERROR", "color": _COLOR_ERROR_TOKEN},
		{"token": "Warning", "color": _COLOR_WARNING_TOKEN},
		{"token": "WARNING", "color": _COLOR_WARNING_TOKEN},
	]
	for c in candidates:
		var token: String = str(c["token"])
		if not message.begins_with(token):
			continue
		var after: int = token.length()
		if after < message.length() and _is_word_char(message[after]):
			continue
		return [0, after, "[color=%s]%s[/color]" % [str(c["color"]), token]]
	return []

# Scans for res:// and user:// URIs. Per spec, the trailing path matches the
# character set [letters, digits, _, -, ., /]. Each match is recorded as an
# edit AND its byte range is appended to skip_ranges so number detection won't
# fire on digits inside the path.
func _detect_paths(message: String, edits: Array, skip_ranges: Array, wrap_as_url: bool) -> void:
	var prefixes: Array = ["res://", "user://"]
	var i: int = 0
	var n: int = message.length()
	while i < n:
		var matched_prefix: String = ""
		for p in prefixes:
			if message.substr(i, p.length()) == p:
				matched_prefix = p
				break
		if matched_prefix.is_empty():
			i += 1
			continue
		var end_pos: int = i + matched_prefix.length()
		while end_pos < n and _is_path_char(message[end_pos]):
			end_pos += 1
		# Bail if we didn't capture at least one trailing char - bare "res://"
		# with nothing after is technically valid syntax but not a useful link.
		if end_pos == i + matched_prefix.length():
			i = end_pos
			continue
		var path: String = message.substr(i, end_pos - i)
		var colored: String = "[color=%s]%s[/color]" % [_COLOR_PATH, path]
		var replacement: String
		if wrap_as_url:
			replacement = "[url=%s]%s[/url]" % [path, colored]
		else:
			replacement = colored
		edits.append([i, end_pos, replacement])
		skip_ranges.append([i, end_pos])
		i = end_pos

# Scans for standalone numeric tokens with optional decimal and optional unit
# suffix. The leading digit must follow a word boundary (start of string or
# non-word char) so numbers inside identifiers like "vec2" or "Float32" are
# left alone. After the optional unit the next char must also be a word
# boundary (or end of string) to reject runs like "42abc".
func _detect_numbers(message: String, edits: Array, skip_ranges: Array) -> void:
	var units: Array = ["ms", "s", "KB", "MB", "GB", "%"]
	var n: int = message.length()
	var i: int = 0
	while i < n:
		if not _is_digit(message[i]):
			i += 1
			continue
		if _is_in_skip_range(i, skip_ranges):
			i += 1
			continue
		# Word-boundary check at the LEADING side: previous char (if any) must
		# not be a word char.
		if i > 0 and _is_word_char(message[i - 1]):
			i += 1
			continue
		var start: int = i
		while i < n and _is_digit(message[i]):
			i += 1
		# Optional .ddd fractional part. We only consume the '.' if it's
		# actually followed by a digit so "v1." (rare but possible) doesn't
		# eat the period.
		if i < n - 1 and message[i] == "." and _is_digit(message[i + 1]):
			i += 1
			while i < n and _is_digit(message[i]):
				i += 1
		# Optional unit suffix - longest match wins (so "ms" beats "s").
		var unit_end: int = i
		var best_unit_len: int = 0
		for u in units:
			var ulen: int = str(u).length()
			if message.substr(i, ulen) == str(u) and ulen > best_unit_len:
				best_unit_len = ulen
		if best_unit_len > 0:
			unit_end = i + best_unit_len
		# Trailing word-boundary check: next char (if any) must not be a word
		# char. Catches "42abc" - without this, we'd wrap "42" and visually
		# split the identifier.
		if unit_end < n and _is_word_char(message[unit_end]):
			# Skip this whole run - advance past the digits we already consumed
			# AND past any trailing word chars so we don't re-enter mid-token.
			i = unit_end
			while i < n and _is_word_char(message[i]):
				i += 1
			continue
		i = unit_end
		var token: String = message.substr(start, i - start)
		edits.append([start, i, "[color=%s]%s[/color]" % [_COLOR_NUMBER, token]])

func _is_path_char(c: String) -> bool:
	if c.length() != 1:
		return false
	if _is_word_char(c):
		return true
	return c == "-" or c == "." or c == "/"

func _is_word_char(c: String) -> bool:
	if c.length() != 1:
		return false
	if _is_digit(c):
		return true
	if c == "_":
		return true
	var ch: int = c.unicode_at(0)
	return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122)

func _is_digit(c: String) -> bool:
	if c.length() != 1:
		return false
	var ch: int = c.unicode_at(0)
	return ch >= 48 and ch <= 57

func _is_in_skip_range(idx: int, ranges: Array) -> bool:
	for r in ranges:
		if idx >= int(r[0]) and idx < int(r[1]):
			return true
	return false

# Handler for [url=...] clicks in the output. Resolves the path extension and
# routes to the matching EditorInterface call. Unknown extensions fall through
# to a friendly log message rather than crashing or silently doing nothing.
func _on_output_meta_clicked(meta: Variant) -> void:
	var path: String = str(meta)
	if path.is_empty():
		return
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return
	if not FileAccess.file_exists(path):
		add_log_message("File not found: %s" % path, LOG_LEVEL_WARNING)
		return
	var ext: String = path.get_extension().to_lower()
	# Visible breadcrumb so the user can see the click was received even
	# if the editor doesn't visibly switch (e.g., script editor already open
	# on that file). Logged at SUCCESS level for distinct color.
	add_log_message("Opening %s" % path, LOG_LEVEL_SUCCESS)
	match ext:
		"tscn", "scn":
			EditorInterface.open_scene_from_path(path)
		"gd", "cs":
			var script: Script = load(path) as Script
			if script:
				# edit_script in Godot 4.6 requires (script, line, column,
				# grab_focus). Calling with one arg silently fails - be explicit.
				EditorInterface.edit_script(script, 0, 0, true)
				EditorInterface.set_main_screen_editor("Script")
			else:
				add_log_message("Could not load script: %s" % path, LOG_LEVEL_ERROR)
		"tres", "res":
			var res: Resource = load(path)
			if res:
				EditorInterface.edit_resource(res)
			else:
				add_log_message("Could not load resource: %s" % path, LOG_LEVEL_ERROR)
		_:
			add_log_message("File type not editable: %s" % path, LOG_LEVEL_INFO)
# ---------------- end T2.2 output renderer helpers ----------------

func _on_input_line_gui_input(event):
	if not (event is InputEventKey) or not event.pressed:
		return
	var key_event: InputEventKey = event as InputEventKey
	var ctrl: bool = key_event.ctrl_pressed
	var shift: bool = key_event.shift_pressed or Input.is_key_pressed(KEY_SHIFT)
	
	# bash polish - reverse-i-search mode: input line owned by search loop.
	if _reverse_search_active:
		_handle_reverse_search_key(key_event)
		accept_event()
		return
	
	# Ctrl-modifier shortcuts are checked before plain keycodes so Ctrl+A / Ctrl+U
	# aren't shadowed by a future plain-A/U branch.
	if ctrl:
		match key_event.keycode:
			KEY_A:
				_last_input_action = "select_all"
				if is_instance_valid(input_line):
					input_line.select_all()
				accept_event()
				return
			KEY_U:
				_last_input_action = "clear_line"
				if is_instance_valid(input_line):
					input_line.text = ""
					input_line.caret_column = 0
				_user_draft = ""
				_dismiss_autocomplete_popup(false)
				accept_event()
				return
			KEY_L:
				# bash polish - Ctrl+L clears scrollback; input preserved.
				_last_input_action = "clear_output"
				clear_output()
				accept_event()
				return
			KEY_R:
				# bash polish - Ctrl+R enters reverse-history-search mode.
				_last_input_action = "reverse_search"
				_enter_reverse_search()
				accept_event()
				return
			# --- T5 readline shortcuts (Ctrl+W / Ctrl+K / Ctrl+Y) ---
			KEY_W:
				_last_input_action = "kill_word_backward"
				_t5_kill_word_backward()
				accept_event()
				return
			KEY_K:
				_last_input_action = "kill_to_end_of_line"
				_t5_kill_to_end_of_line()
				accept_event()
				return
			KEY_Y:
				_last_input_action = "yank"
				_t5_yank()
				accept_event()
				return
	
	# --- T5 readline shortcuts: Alt+B / Alt+F word navigation ---
	# Require alt without ctrl so Ctrl+Alt+B isn't accidentally captured.
	# The reverse-search guard above already short-circuits during search,
	# so these branches are inert in that mode.
	if key_event.alt_pressed and not ctrl:
		match key_event.keycode:
			KEY_B:
				_last_input_action = "word_back"
				_t5_move_word_back()
				accept_event()
				return
			KEY_F:
				_last_input_action = "word_forward"
				_t5_move_word_forward()
				accept_event()
				return
	
	match key_event.keycode:
		KEY_ENTER, KEY_KP_ENTER:
			# Enter always submits the input AS-TYPED - never picks the popup
			# highlight. This is correct UX for "I changed my mind, run what
			# I typed."
			_last_input_action = "submit"
			_dismiss_autocomplete_popup(false)
			send_button.pressed.emit()
			accept_event()
		KEY_TAB:
			if _popup_open and not _matching_commands.is_empty():
				if shift:
					_last_input_action = "cycle_prev"
					_cycle_autocomplete_selection(-1)
				elif _preview_pending:
					# Preview index 0 without cycling on first Tab after popup opens.
					_last_input_action = "preview_current"
					_preview_pending = false
				else:
					_last_input_action = "cycle_next"
					_cycle_autocomplete_selection(1)
				_preview_autocomplete_selection()
			else:
				# Bash-style shared-prefix advance before opening popup.
				_refresh_autocomplete_matches()
				var advanced: bool = _try_advance_to_common_prefix()
				if advanced:
					_last_input_action = "advance_common_prefix"
				else:
					_last_input_action = "open_popup"
					_show_autocomplete_popup()
					if _popup_open and not _matching_commands.is_empty():
						# Preview index 0 immediately after opening popup via Tab.
						_preview_pending = false
						_preview_autocomplete_selection()
			accept_event()
		KEY_UP:
			if _popup_open:
				_last_input_action = "cycle_prev"
				_cycle_autocomplete_selection(-1)
				_preview_pending = false
				_preview_autocomplete_selection()
			else:
				_last_input_action = "history_back"
				_navigate_history(-1)
			accept_event()
		KEY_DOWN:
			if _popup_open:
				if _preview_pending:
					_last_input_action = "preview_current"
					_preview_pending = false
				else:
					_last_input_action = "cycle_next"
					_cycle_autocomplete_selection(1)
				_preview_autocomplete_selection()
			else:
				_last_input_action = "history_forward"
				_navigate_history(1)
			accept_event()
		KEY_ESCAPE:
			if _popup_open:
				_last_input_action = "dismiss_popup"
				_dismiss_autocomplete_popup(true)
				accept_event()
			# When the popup is closed, Esc has no special EditorConsole meaning
			# and is left for the editor itself to handle.
		KEY_HOME:
			_last_input_action = "caret_home"
			if is_instance_valid(input_line):
				input_line.caret_column = 0
			accept_event()
		KEY_END:
			_last_input_action = "caret_end"
			if is_instance_valid(input_line):
				input_line.caret_column = input_line.text.length()
			accept_event()

func _navigate_history(direction: int):
	if command_history.is_empty():
		return
	
	history_index = clamp(history_index + direction, 0, command_history.size())
	
	if history_index < command_history.size():
		input_line.text = command_history[history_index]
		input_line.caret_column = input_line.text.length()
	else:
		input_line.clear()

func _on_input_text_changed(new_text: String):
	# Every direct user keystroke updates the saved draft so Esc can restore
	# whatever they last typed. _preview_autocomplete_selection suppresses
	# this update via _suppress_text_changed so cycling doesn't clobber the
	# original draft.
	if _suppress_text_changed:
		return
	_user_draft = new_text
	_show_autocomplete_popup()

# Refresh _matching_commands based on the current word fragment under the
# caret. Does NOT touch popup visibility - callers decide whether to show it.
func _refresh_autocomplete_matches() -> void:
	if not is_instance_valid(input_line):
		_matching_commands = []
		return
	var current_text: String = input_line.text
	var caret_pos: int = input_line.caret_column
	var word_start: int = caret_pos
	while word_start > 0 and current_text[word_start - 1] != " ":
		word_start -= 1
	var current_word: String = current_text.substr(word_start, caret_pos - word_start)
	var mode: String = _determine_autocomplete_mode(current_text, caret_pos)
	_autocomplete_mode = mode
	
	match mode:
		"commands":
			_get_command_suggestions(current_word)
		"directories":
			_get_directory_suggestions(current_word)
		"files":
			_get_file_suggestions(current_word)
		"filenames_only":
			_get_filename_suggestions(current_word)
		"node_types":
			_get_node_type_suggestions(current_word)
		"node_paths":
			_get_node_path_suggestions(current_word)
	
	if _matching_commands.size() > _MAX_POPUP_ITEMS:
		_matching_commands = _matching_commands.slice(0, _MAX_POPUP_ITEMS)

func _show_autocomplete_popup() -> void:
	if not is_instance_valid(input_line) or not is_instance_valid(autocomplete_popup):
		return
	if input_line.text.strip_edges().is_empty():
		_matching_commands.clear()
		_dismiss_autocomplete_popup(false)
		return
	_refresh_autocomplete_matches()
	if _matching_commands.is_empty():
		_dismiss_autocomplete_popup(false)
		return
	_populate_popup_list()
	autocomplete_popup.visible = true
	_popup_open = true
	# Preview pending flag set on first use by Tab/Down handler.
	_preview_pending = true
	autocomplete_index = 0
	if is_instance_valid(autocomplete_list) and autocomplete_list.item_count > 0:
		autocomplete_list.select(0)
		autocomplete_list.ensure_current_is_visible()
	_position_autocomplete_popup()

func _populate_popup_list() -> void:
	if not is_instance_valid(autocomplete_list):
		return
	autocomplete_list.clear()
	for suggestion in _matching_commands:
		autocomplete_list.add_item(str(suggestion))
	# Reset size and defer shrink to let ItemList recompute minimum_size.
	autocomplete_list.size = Vector2.ZERO
	if is_instance_valid(autocomplete_popup):
		autocomplete_popup.size = Vector2.ZERO
		var min_w: float = autocomplete_popup.custom_minimum_size.x
		autocomplete_popup.custom_minimum_size = Vector2(min_w, 0)
	call_deferred("_force_popup_shrink_to_fit")

func _force_popup_shrink_to_fit() -> void:
	if is_instance_valid(autocomplete_list):
		autocomplete_list.reset_size()
	if is_instance_valid(autocomplete_popup):
		autocomplete_popup.reset_size()
		# Reposition after the shrink so the popup stays anchored to the
		# input line rather than drifting upward as it gets shorter.
		if is_instance_valid(input_line) and is_inside_tree():
			_finalize_popup_position(input_line.get_global_rect())

func _position_autocomplete_popup() -> void:
	if not is_instance_valid(autocomplete_popup) or not is_instance_valid(input_line):
		return
	if not is_inside_tree():
		return
	var input_global: Rect2 = input_line.get_global_rect()
	var popup_min_width: float = max(input_global.size.x, 200.0)
	# Width is min-clamped; height is left at 0 so reset_size() can shrink.
	autocomplete_popup.custom_minimum_size = Vector2(popup_min_width, 0)
	# Defer placement after layout finishes to know popup's real height.
	call_deferred("_finalize_popup_position", input_global)

func _finalize_popup_position(input_global: Rect2) -> void:
	if not is_instance_valid(autocomplete_popup) or not is_inside_tree():
		return
	var popup_size: Vector2 = autocomplete_popup.size
	var viewport_size: Vector2 = get_viewport_rect().size
	# Prefer above input; drop below if popup clips off top of viewport.
	var above_y: float = input_global.position.y - popup_size.y
	var below_y: float = input_global.position.y + input_global.size.y
	var y: float = above_y
	if above_y < 0.0:
		y = below_y
	# Clamp horizontally so we don't drift off-screen on narrow viewports.
	var x: float = clamp(input_global.position.x, 0.0, max(0.0, viewport_size.x - popup_size.x))
	autocomplete_popup.global_position = Vector2(x, y)

func _dismiss_autocomplete_popup(restore_draft: bool) -> void:
	if is_instance_valid(autocomplete_popup):
		autocomplete_popup.visible = false
	_popup_open = false
	autocomplete_index = -1
	if restore_draft and is_instance_valid(input_line):
		input_line.text = _user_draft
		input_line.caret_column = input_line.text.length()
	# _user_draft persists for next keystroke; clears on text_changed.

func _cycle_autocomplete_selection(delta: int) -> void:
	if _matching_commands.is_empty():
		return
	var count: int = _matching_commands.size()
	# Positive-wrap modulo: Shift+Tab at index 0 lands on last item, not -1.
	autocomplete_index = ((autocomplete_index + delta) % count + count) % count
	if is_instance_valid(autocomplete_list) and autocomplete_index < autocomplete_list.item_count:
		autocomplete_list.select(autocomplete_index)
		autocomplete_list.ensure_current_is_visible()

func _apply_autocomplete_selection() -> void:
	if _matching_commands.is_empty() or autocomplete_index < 0:
		_dismiss_autocomplete_popup(false)
		return
	var idx: int = clamp(autocomplete_index, 0, _matching_commands.size() - 1)
	var selected: String = str(_matching_commands[idx])
	var current_text: String = input_line.text
	var caret_pos: int = input_line.caret_column
	var word_start: int = caret_pos
	while word_start > 0 and current_text[word_start - 1] != " ":
		word_start -= 1
	var new_text: String = current_text.substr(0, word_start) + selected + current_text.substr(caret_pos)
	input_line.text = new_text
	input_line.caret_column = word_start + selected.length()
	_dismiss_autocomplete_popup(false)

# Preview the current highlighted suggestion without dismissing popup.
# User can cycle and preview (bash-style); Esc restores draft.
func _preview_autocomplete_selection() -> void:
	if _matching_commands.is_empty() or autocomplete_index < 0:
		return
	if not is_instance_valid(input_line):
		return
	var idx: int = clamp(autocomplete_index, 0, _matching_commands.size() - 1)
	var selected: String = str(_matching_commands[idx])
	# Rebuild preview from original draft each time for consistent cycling.
	var draft: String = _user_draft
	# Find the last whitespace-delimited word in the draft.
	var word_start: int = draft.length()
	while word_start > 0 and draft[word_start - 1] != " ":
		word_start -= 1
	var new_text: String = draft.substr(0, word_start) + selected
	# Block text_changed handler from overwriting _user_draft during preview write.
	_suppress_text_changed = true
	input_line.text = new_text
	input_line.caret_column = new_text.length()
	_suppress_text_changed = false

func _on_input_focus_exited() -> void:
	# Defer dismiss to allow ItemList to handle click before hiding popup.
	call_deferred("_dismiss_if_focus_not_in_popup")

func _dismiss_if_focus_not_in_popup() -> void:
	if not is_instance_valid(autocomplete_popup) or not is_inside_tree():
		return
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	if focus_owner == input_line:
		return
	if focus_owner and autocomplete_popup.is_ancestor_of(focus_owner):
		return
	_dismiss_autocomplete_popup(false)

func _on_autocomplete_item_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	autocomplete_index = index
	_apply_autocomplete_selection()
	if is_instance_valid(input_line):
		input_line.grab_focus()
		input_line.caret_column = input_line.text.length()

func _on_autocomplete_item_activated(index: int) -> void:
	autocomplete_index = index
	_apply_autocomplete_selection()
	if is_instance_valid(input_line):
		input_line.grab_focus()
		input_line.caret_column = input_line.text.length()

func _on_self_resized() -> void:
	if _popup_open:
		_position_autocomplete_popup()

# - commands whose first arg should be completed against the filesystem.
const _FILE_ARG_COMMANDS := [
	"ls", "cat", "grep", "head", "tail", "stat", "wc", "open", "diff",
	"find", "rm", "mv", "cp", "touch", "run_project"
]

# - commands whose first arg is a live node path.
# FUTURE: For `get`/`set`, syntax is `<target>.<property>` requiring per-target reflection.
const _NODE_PATH_ARG_COMMANDS := [
	"inspect", "get", "set", "watch", "scene_tree", "signals", "properties"
]

# Depth cap for scene-tree descendant walks; prevents suggestion balloon.
const _NODE_PATH_DEPTH_CAP := 4

# Hard cap on node-path suggestions; popup applies its own smaller cap.
const _NODE_PATH_MAX_SUGGESTIONS := 20

func _determine_autocomplete_mode(text: String, caret_pos: int) -> String:
	# We're "on arg N" when there are N spaces left of the caret. Counting
	# spaces is robust against trailing whitespace, multi-character commands,
	# and the existing split(" ", false) which silently collapses runs and
	# trims trailing empties - that collapse made the old dispatch
	# incorrectly classify "new_script " (trailing space, no second word) the
	# same as "new_script".
	var typed: String = text.substr(0, caret_pos)
	var arg_index: int = typed.count(" ")
	if arg_index == 0:
		return "commands"
	var parts: PackedStringArray = typed.split(" ", false)
	if parts.is_empty():
		return "commands"
	var command: String = parts[0].to_lower()
	
	# new_script / new_scene: arg 1 → "filenames_only", arg 2 → "node_types".
	# new_resource: no useful 2nd-arg completion (falls through to "commands").
	if command in ["new_script", "new_scene", "new_resource"]:
		if arg_index >= 2 and command in ["new_script", "new_scene"]:
			return "node_types"
		return "filenames_only"
	
	if command == "cd" or command == "mkdir":
		return "directories"
	
	if command in _FILE_ARG_COMMANDS:
		return "files"
	
	if command in _NODE_PATH_ARG_COMMANDS:
		return "node_paths"
	
	return "commands"

func _get_command_suggestions(current_word: String):
	var registry := _command_registry()
	current_autocomplete_options = registry.get_available_commands() if registry else []
	var matching_commands: Array[String] = []
	for cmd in current_autocomplete_options:
		if cmd.begins_with(current_word):
			matching_commands.append(cmd)
	
	_matching_commands = matching_commands
	_last_autocomplete_word = current_word

func _get_file_suggestions(current_word: String):
	var current_dir = BuiltInCommands.get_current_directory()
	
	if current_word.contains("/"):
		var path_parts = current_word.split("/")
		var partial_path = "/".join(path_parts.slice(0, -1))
		var search_term = path_parts[-1]
		
		var base_path = current_dir
		if partial_path != "":
			base_path = current_dir.path_join(partial_path)
		
		var dir = DirAccess.open(base_path)
		if not dir:
			_matching_commands = []
			return
		
		var files: Array[String] = []
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			if not file_name.begins_with(".") and file_name.begins_with(search_term):
				var full_path = partial_path + "/" + file_name if partial_path != "" else file_name
				files.append(full_path)
			file_name = dir.get_next()
		
		dir.list_dir_end()
		files.sort()
		_matching_commands = files
		_last_autocomplete_word = current_word
		return

	var dir = DirAccess.open(current_dir)
	if not dir:
		_matching_commands = []
		return
	
	var files: Array[String] = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not file_name.begins_with(".") and file_name.begins_with(current_word):
			files.append(file_name)
		file_name = dir.get_next()
	
	dir.list_dir_end()
	files.sort()
	_matching_commands = files
	_last_autocomplete_word = current_word

func _get_directory_suggestions(current_word: String):
	var current_dir = BuiltInCommands.get_current_directory()
	
	if current_word.contains("/"):
		var path_parts = current_word.split("/")
		var partial_path = "/".join(path_parts.slice(0, -1))
		var search_term = path_parts[-1]
		
		var base_path = current_dir
		if partial_path != "":
			base_path = current_dir.path_join(partial_path)
		
		var dir = DirAccess.open(base_path)
		if not dir:
			_matching_commands = []
			return
		
		var directories: Array[String] = []
		dir.list_dir_begin()
		var file_name = dir.get_next()
		
		while file_name != "":
			if not file_name.begins_with(".") and file_name.begins_with(search_term):
				if dir.current_is_dir():
					var full_path = partial_path + "/" + file_name if partial_path != "" else file_name
					directories.append(full_path)
			file_name = dir.get_next()
		
		dir.list_dir_end()
		directories.sort()
		_matching_commands = directories
		_last_autocomplete_word = current_word
		return
	
	var dir = DirAccess.open(current_dir)
	if not dir:
		_matching_commands = []
		return
	
	var directories: Array[String] = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	while file_name != "":
		if not file_name.begins_with(".") and file_name.begins_with(current_word):
			if dir.current_is_dir():
				directories.append(file_name)
		file_name = dir.get_next()
	
	dir.list_dir_end()
	directories.sort()
	_matching_commands = directories
	_last_autocomplete_word = current_word

func _get_node_type_suggestions(current_word: String):
	var valid_types = ["Node", "Node2D", "Node3D", "Control", "CanvasItem", "CanvasLayer", "Viewport", "Window", "SubViewport", "Area2D", "Area3D", "CollisionShape2D", "CollisionShape3D", "Sprite2D", "Sprite3D", "Label", "Button", "LineEdit", "TextEdit", "RichTextLabel", "Panel", "VBoxContainer", "HBoxContainer", "GridContainer", "CenterContainer", "MarginContainer", "ScrollContainer", "TabContainer", "SplitContainer", "AspectRatioContainer", "TextureRect", "ColorRect", "NinePatchRect", "ProgressBar", "Slider", "SpinBox", "CheckBox", "CheckButton", "OptionButton", "ItemList", "Tree", "TreeItem", "FileDialog", "ColorPicker", "ColorPickerButton", "MenuButton", "PopupMenu", "MenuBar", "ToolButton", "LinkButton", "TextureButton", "TextureProgressBar", "AnimationPlayer", "AnimationTree", "Tween", "Timer", "Camera2D", "Camera3D", "Light2D", "Light3D", "AudioStreamPlayer", "AudioStreamPlayer2D", "AudioStreamPlayer3D", "AudioListener2D", "AudioListener3D", "RigidBody2D", "RigidBody3D", "CharacterBody2D", "CharacterBody3D", "StaticBody2D", "StaticBody3D", "KinematicBody2D", "KinematicBody3D", "Path2D", "Path3D", "NavigationAgent2D", "NavigationAgent3D", "NavigationRegion2D", "NavigationRegion3D", "NavigationPolygon", "NavigationMesh", "NavigationLink2D", "NavigationLink3D", "NavigationObstacle2D", "NavigationObstacle3D", "NavigationPathQueryParameters2D", "NavigationPathQueryParameters3D", "NavigationPathQueryResult2D", "NavigationPathQueryResult3D", "NavigationMeshSourceGeometry2D", "NavigationMeshSourceGeometry3D", "NavigationMeshSourceGeometryData2D", "NavigationMeshSourceGeometryData3D"]
	
	var matching_types: Array[String] = []
	for type_name in valid_types:
		if type_name.begins_with(current_word):
			matching_types.append(type_name)
	
	_matching_commands = matching_types
	_last_autocomplete_word = current_word


func _get_filename_suggestions(current_word: String) -> void:
	# - first arg of `new_*`: user invents NEW names; empty list encourages typing.
	_matching_commands = []
	_last_autocomplete_word = current_word

func _get_node_path_suggestions(current_word: String) -> void:
	# - node paths for `inspect`, `get`, `set`, `watch`, etc.
	# Sources: "Engine" (global), autoload short names, and /root/... absolute paths (depth capped).
	var suggestions: Array[String] = []
	
	if current_word.is_empty() or "Engine".begins_with(current_word):
		suggestions.append("Engine")
	
	# Engine.get_main_loop().root === SceneTree.root in BOTH editor and
	# runtime, so this branch works in either context without further
	# gating. The descendant walk below is what differs.
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		for child in tree.root.get_children():
			if not is_instance_valid(child):
				continue
			var nm: String = str(child.name)
			if current_word.is_empty() or nm.begins_with(current_word):
				if not suggestions.has(nm):
					suggestions.append(nm)
	
	var scene_root: Node = null
	if Engine.is_editor_hint():
		# EditorInterface is the editor global singleton.
		scene_root = EditorInterface.get_edited_scene_root()
	elif tree:
		scene_root = tree.root
	if scene_root:
		_collect_node_path_descendants(scene_root, current_word, suggestions, 0)
	
	if suggestions.size() > _NODE_PATH_MAX_SUGGESTIONS:
		suggestions = suggestions.slice(0, _NODE_PATH_MAX_SUGGESTIONS)
	
	_matching_commands = suggestions
	_last_autocomplete_word = current_word

func _collect_node_path_descendants(node: Node, current_word: String, suggestions: Array[String], depth: int) -> void:
	# Capped recursive walk; adds descendants as absolute /root/... paths.
	# Recurses even if parent path doesn't match; deeper descendants may match.
	if depth >= _NODE_PATH_DEPTH_CAP:
		return
	if not is_instance_valid(node):
		return
	for child in node.get_children():
		if not is_instance_valid(child):
			continue
		var path: String = str(child.get_path())
		if current_word.is_empty() or path.begins_with(current_word):
			if not suggestions.has(path):
				suggestions.append(path)
		_collect_node_path_descendants(child, current_word, suggestions, depth + 1)


# ================================================================
# bash polish - banner, prompt, syntax highlighting, common-prefix
# Tab, reverse-i-search. Each helper is self-contained and safe to
# call without the @onready node refs being live (used by tests).
# ================================================================

# Emits multi-line welcome banner once per console instance (enforced via _META_BANNER_SHOWN).
func _emit_welcome_banner() -> void:
	if has_meta(_META_BANNER_SHOWN):
		return
	set_meta(_META_BANNER_SHOWN, true)
	var version: String = _read_addon_version()
	var hdr: String = "[color=%s]+-- Debug Console v%s -- Type 'help' for commands --+[/color]" % [_COLOR_BANNER_TEXT, version]
	var body: String = "[color=%s]| Bash shortcuts: Ctrl+L clear * Ctrl+R reverse-search * Tab complete |[/color]" % _COLOR_BANNER_TEXT
	var ftr: String = "[color=%s]+----------------------------------------------------------------------+[/color]" % _COLOR_BANNER_TEXT
	add_log_message(hdr, LOG_LEVEL_INFO)
	add_log_message(body, LOG_LEVEL_INFO)
	add_log_message(ftr, LOG_LEVEL_INFO)

# Reads version from plugin.cfg; returns "1.2.0" on any failure.
func _read_addon_version() -> String:
	var cfg := ConfigFile.new()
	var err: int = cfg.load("res://addons/debug_console/plugin.cfg")
	if err != OK:
		return "1.2.0"
	var v = cfg.get_value("plugin", "version", "1.2.0")
	return str(v)

# Render bash-style prompt line. Bracket glyphs use [lb]/[rb] for literal text rendering.
func _render_bash_prompt(command: String) -> String:
	var user: String = _get_prompt_user()
	var host: String = "godot"
	var cwd: String = _get_prompt_cwd()
	var lb: String = "[lb]"
	var rb: String = "[rb]"
	var prompt: String = "[color=%s]%s[/color][color=%s]%s@%s[/color][color=%s] %s[/color][color=%s]%s[/color][color=%s]$[/color] " % [
		_COLOR_PROMPT_DIM, lb,
		_COLOR_PROMPT_USER, user, host,
		_COLOR_PROMPT_CWD, cwd,
		_COLOR_PROMPT_DIM, rb,
		_COLOR_PROMPT_DIM,
	]
	return prompt + _colorize_command_input(command)

# Username for prompt; falls back to "user" if both USER and USERNAME are unset.
func _get_prompt_user() -> String:
	var u: String = OS.get_environment("USER")
	if u.is_empty():
		u = OS.get_environment("USERNAME")
	if u.is_empty():
		u = "user"
	return u

# Current working directory for prompt; shared with BuiltInCommands.
# Falls back to "res://" if BuiltInCommands is unavailable.
func _get_prompt_cwd() -> String:
	var cwd: String = ""
	var script: GDScript = load("res://addons/debug_console/core/BuiltInCommands.gd") as GDScript
	if script:
		cwd = str(BuiltInCommands.get_current_directory())
	if cwd.is_empty():
		cwd = "res://"
	return cwd

# Per-token colorization of the command line echoed back.
# Token 0 → command (yellow); "-*" → flag (magenta); "|/>/>/>/<" → pipe/redirect (magenta);
# quoted strings → literal (cyan); else → plain.
func _colorize_command_input(command: String) -> String:
	if command.is_empty():
		return command
	var tokens: Array[String] = _tokenize_command_preserving_quotes(command)
	var out_parts: Array[String] = []
	for i in range(tokens.size()):
		var tok: String = tokens[i]
		if tok.strip_edges().is_empty():
			out_parts.append(tok)
			continue
		var color: String = ""
		if tok == "|" or tok == ">" or tok == ">>" or tok == "<":
			color = _COLOR_PIPE
		elif tok.begins_with("-"):
			color = _COLOR_FLAG
		elif (tok.length() >= 2 and tok.begins_with("\"") and tok.ends_with("\"")) or \
			(tok.length() >= 2 and tok.begins_with("'") and tok.ends_with("'")):
			color = _COLOR_STRING_LITERAL
		elif _is_first_non_blank_token(tokens, i):
			color = _COLOR_COMMAND_NAME
		if color.is_empty():
			out_parts.append(tok)
		else:
			out_parts.append("[color=%s]%s[/color]" % [color, tok])
	return "".join(out_parts)

# True if tokens[index] is the first non-blank token (i.e. the command name).
func _is_first_non_blank_token(tokens: Array[String], index: int) -> bool:
	for j in range(index):
		if not tokens[j].strip_edges().is_empty():
			return false
	return not tokens[index].strip_edges().is_empty()

# Tokenize command line preserving whitespace runs and quoted strings as single tokens.
func _tokenize_command_preserving_quotes(command: String) -> Array[String]:
	var result: Array[String] = []
	var i: int = 0
	var n: int = command.length()
	while i < n:
		var c: String = command[i]
		if c == " " or c == "\t":
			var j: int = i
			while j < n and (command[j] == " " or command[j] == "\t"):
				j += 1
			result.append(command.substr(i, j - i))
			i = j
			continue
		if c == "\"" or c == "'":
			var quote: String = c
			var j2: int = i + 1
			while j2 < n and command[j2] != quote:
				j2 += 1
			var end_idx: int = j2 + 1 if j2 < n else n
			result.append(command.substr(i, end_idx - i))
			i = end_idx
			continue
		var k: int = i
		while k < n and command[k] != " " and command[k] != "\t" and command[k] != "\"" and command[k] != "'":
			k += 1
		result.append(command.substr(i, k - i))
		i = k
	return result

# Longest common prefix across array of strings. Used by Tab prefix advance.
func _longest_common_prefix(words: Array) -> String:
	if words.is_empty():
		return ""
	var prefix: String = str(words[0])
	for i in range(1, words.size()):
		var w: String = str(words[i])
		var lim: int = min(prefix.length(), w.length())
		var k: int = 0
		while k < lim and prefix[k] == w[k]:
			k += 1
		prefix = prefix.substr(0, k)
		if prefix.is_empty():
			return ""
	return prefix

# Tab: advance current word to longest common prefix if popup not yet open.
# Returns true if text was inserted (bash UX: second Tab opens menu).
func _try_advance_to_common_prefix() -> bool:
	if _matching_commands.size() < 2:
		return false
	if not is_instance_valid(input_line):
		return false
	var current_text: String = input_line.text
	var caret_pos: int = input_line.caret_column
	var word_start: int = caret_pos
	while word_start > 0 and current_text[word_start - 1] != " ":
		word_start -= 1
	var current_word: String = current_text.substr(word_start, caret_pos - word_start)
	var lcp: String = _longest_common_prefix(_matching_commands)
	if lcp.length() <= current_word.length():
		return false
	for m in _matching_commands:
		if not str(m).begins_with(current_word):
			return false
	var new_text: String = current_text.substr(0, word_start) + lcp + current_text.substr(caret_pos)
	_suppress_text_changed = true
	input_line.text = new_text
	input_line.caret_column = word_start + lcp.length()
	_user_draft = new_text
	_suppress_text_changed = false
	return true

# ---------------- reverse-i-search ----------------
# Enter reverse-i-search mode: capture state and route keystrokes to _handle_reverse_search_key.
func _enter_reverse_search() -> void:
	if not is_instance_valid(input_line):
		return
	_reverse_search_active = true
	_reverse_search_query = ""
	_reverse_search_index = command_history.size()
	_reverse_search_pre_input = input_line.text
	_reverse_search_pre_caret = input_line.caret_column
	_reverse_search_pre_placeholder = input_line.placeholder_text
	_dismiss_autocomplete_popup(false)
	_suppress_text_changed = true
	input_line.text = ""
	input_line.caret_column = 0
	_suppress_text_changed = false
	_apply_reverse_search_placeholder()
	if is_instance_valid(reverse_search_hint):
		reverse_search_hint.visible = true
		reverse_search_hint.text = _build_reverse_search_hint_text()

# Exit reverse-search mode. If commit=false, restore original input_line (Esc).
# If true, leave matched command in input_line.
func _exit_reverse_search(commit: bool) -> void:
	if not _reverse_search_active:
		return
	_reverse_search_active = false
	if is_instance_valid(input_line):
		input_line.placeholder_text = _reverse_search_pre_placeholder
		if not commit:
			_suppress_text_changed = true
			input_line.text = _reverse_search_pre_input
			input_line.caret_column = clamp(_reverse_search_pre_caret, 0, input_line.text.length())
			_suppress_text_changed = false
		else:
			input_line.caret_column = input_line.text.length()
	if is_instance_valid(reverse_search_hint):
		reverse_search_hint.visible = false
	_reverse_search_query = ""
	_reverse_search_index = -1
	_reverse_search_pre_input = ""
	_reverse_search_pre_caret = 0
	_reverse_search_pre_placeholder = ""

# Rebuild placeholder text using current query. Bash format: "(reverse-i-search)`query':"
func _apply_reverse_search_placeholder() -> void:
	if not is_instance_valid(input_line):
		return
	input_line.placeholder_text = "%s%s':" % [_REVERSE_SEARCH_PROMPT_PREFIX, _reverse_search_query]
	if is_instance_valid(reverse_search_hint):
		reverse_search_hint.text = _build_reverse_search_hint_text()

func _build_reverse_search_hint_text() -> String:
	return "%s%s':" % [_REVERSE_SEARCH_PROMPT_PREFIX, _reverse_search_query]

# Walk command_history backward looking for most recent entry containing query (case-insensitive).
# Return true on hit, false on miss.
func _apply_reverse_search() -> bool:
	if _reverse_search_query.is_empty() or command_history.is_empty():
		return false
	var needle: String = _reverse_search_query.to_lower()
	var start: int = clamp(_reverse_search_index, 0, command_history.size())
	for i in range(start - 1, -1, -1):
		var entry: String = command_history[i]
		if entry.to_lower().contains(needle):
			_reverse_search_index = i
			if is_instance_valid(input_line):
				_suppress_text_changed = true
				input_line.text = entry
				input_line.caret_column = entry.length()
				_suppress_text_changed = false
			return true
	return false

# Ctrl+R in reverse-search: step to next older match. No-op if no older match found.
func _step_reverse_search_older() -> bool:
	if not _reverse_search_active or _reverse_search_query.is_empty():
		return false
	var saved: int = _reverse_search_index
	if _apply_reverse_search():
		return true
	_reverse_search_index = saved
	return false

# Route key events in reverse-search mode. Ctrl+R step older, Ctrl+C/Esc cancel.
# Enter commits; Tab/arrows/Home/End commit and exit. Backspace trims query.
func _handle_reverse_search_key(key_event: InputEventKey) -> void:
	var ctrl: bool = key_event.ctrl_pressed
	if ctrl and key_event.keycode == KEY_R:
		_step_reverse_search_older()
		_apply_reverse_search_placeholder()
		return
	if ctrl and key_event.keycode == KEY_C:
		_exit_reverse_search(false)
		return
	match key_event.keycode:
		KEY_ESCAPE:
			_exit_reverse_search(false)
			return
		KEY_ENTER, KEY_KP_ENTER:
			_exit_reverse_search(true)
			send_button.pressed.emit()
			return
		KEY_TAB, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END:
			_exit_reverse_search(true)
			return
		KEY_BACKSPACE:
			if _reverse_search_query.length() > 0:
				_reverse_search_query = _reverse_search_query.substr(0, _reverse_search_query.length() - 1)
				_reverse_search_index = command_history.size()
				if _reverse_search_query.is_empty():
					if is_instance_valid(input_line):
						_suppress_text_changed = true
						input_line.text = ""
						input_line.caret_column = 0
						_suppress_text_changed = false
				else:
					_apply_reverse_search()
			_apply_reverse_search_placeholder()
			return
		_:
			var u: int = key_event.unicode
			if u >= 32 and u != 127:
				_reverse_search_query += String.chr(u)
				_reverse_search_index = command_history.size()
				_apply_reverse_search()
				_apply_reverse_search_placeholder()

# readline: Ctrl+W delete word back, Ctrl+K kill to EOL, Ctrl+Y yank.
# Alt+B/F move word back/forward. Word boundaries: whitespace + shell metas.
const _T5_WORD_BOUNDARY_CHARS := " \t|><&;/"

func _t5_is_word_boundary(ch: String) -> bool:
	return ch.length() > 0 and _T5_WORD_BOUNDARY_CHARS.contains(ch)

func _t5_word_back_index(text: String, caret: int) -> int:
	# Skip boundary chars left, then non-boundary chars left.
	var i: int = clamp(caret, 0, text.length())
	while i > 0 and _t5_is_word_boundary(text.substr(i - 1, 1)):
		i -= 1
	while i > 0 and not _t5_is_word_boundary(text.substr(i - 1, 1)):
		i -= 1
	return i

func _t5_word_forward_index(text: String, caret: int) -> int:
	# Skip boundary chars right, then non-boundary chars right.
	var n: int = text.length()
	var i: int = clamp(caret, 0, n)
	while i < n and _t5_is_word_boundary(text.substr(i, 1)):
		i += 1
	while i < n and not _t5_is_word_boundary(text.substr(i, 1)):
		i += 1
	return i

func _t5_kill_word_backward() -> void:
	if not is_instance_valid(input_line):
		return
	input_line.deselect()
	var text: String = input_line.text
	var caret: int = input_line.get_caret_column()
	var new_caret: int = _t5_word_back_index(text, caret)
	if new_caret == caret:
		return
	_kill_ring = text.substr(new_caret, caret - new_caret)
	input_line.text = text.substr(0, new_caret) + text.substr(caret)
	input_line.set_caret_column(new_caret)
	_user_draft = input_line.text

func _t5_kill_to_end_of_line() -> void:
	if not is_instance_valid(input_line):
		return
	input_line.deselect()
	var text: String = input_line.text
	var caret: int = input_line.get_caret_column()
	if caret >= text.length():
		return
	_kill_ring = text.substr(caret)
	input_line.text = text.substr(0, caret)
	input_line.set_caret_column(caret)
	_user_draft = input_line.text

func _t5_yank() -> void:
	if not is_instance_valid(input_line) or _kill_ring.is_empty():
		return
	input_line.deselect()
	var text: String = input_line.text
	var caret: int = input_line.get_caret_column()
	input_line.text = text.substr(0, caret) + _kill_ring + text.substr(caret)
	input_line.set_caret_column(caret + _kill_ring.length())
	_user_draft = input_line.text

func _t5_move_word_back() -> void:
	if not is_instance_valid(input_line):
		return
	var new_caret: int = _t5_word_back_index(input_line.text, input_line.get_caret_column())
	input_line.set_caret_column(new_caret)

func _t5_move_word_forward() -> void:
	if not is_instance_valid(input_line):
		return
	var new_caret: int = _t5_word_forward_index(input_line.text, input_line.get_caret_column())
	input_line.set_caret_column(new_caret)
# --- end T5 readline shortcuts ---
