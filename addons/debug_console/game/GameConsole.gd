
extends Control
class_name GameConsole

const LOG_LEVEL_INFO := 0
const LOG_LEVEL_WARNING := 1
const LOG_LEVEL_ERROR := 2
const LOG_LEVEL_SUCCESS := 3

# Meta key for the log line buffer. We mirror every logged line into Node
# metadata so tests (and future overlay widgets) can inspect what was logged
# without depending on RichTextLabel's render state - which in headless
# run_scene contexts may not reflect appended content immediately. Same
# pattern as EditorConsole; survives @tool script reloads.
const _META_LOG_BUFFER := "debug_console_log_buffer"

# - opacity and resize bounds. Floor on opacity keeps the console at
# least faintly visible so a stray scroll can't make it invisible. Min
# height keeps the input line reachable; max is computed against the live
# viewport at apply time (80% of viewport height).
const _MIN_OPACITY := 0.1
const _MAX_OPACITY := 1.0
const _MIN_HEIGHT := 150.0
const _OPACITY_SCROLL_STEP := 0.05
const _CONSOLE_CONFIG_PATH := "user://debug_console_config.cfg"
const _CONSOLE_CONFIG_SECTION := "console"

@onready var background: ColorRect = $Background
@onready var output_text: RichTextLabel = $VBox/OutputText
@onready var input_container: HBoxContainer = $VBox/InputContainer
@onready var input_line: LineEdit = $VBox/InputContainer/InputLine
@onready var close_button: Button = $VBox/InputContainer/CloseButton
@onready var autocomplete_popup: PanelContainer = $AutocompletePopup
@onready var autocomplete_list: ItemList = $AutocompletePopup/AutocompleteList
@onready var resize_handle: Control = $ResizeHandle

var command_history: Array[String] = []
var history_index: int = -1
var is_animating: bool = false
var target_height: float = 400.0

# resize-handle drag state. Plain runtime-only fields; GameConsole is
# NOT a @tool script, so hot-reload survival via meta isn't needed here.
var _is_resizing: bool = false
var _resize_start_mouse_y: float = 0.0
var _resize_start_height: float = 0.0

# print interception. Re-entry guard prevents the callback from
# recursing when add_log_message itself emits a log (e.g., DebugCore.Log
# pushing through Output). _logger_instance holds the attached Logger
# subclass (lazily created on first `intercept on`); Godot 4.6 has no
# remove_logger from GDScript, so once attached it stays for the
# application lifetime and _intercept_enabled gates forwarding.
var _intercept_enabled: bool = false
var _in_logger_callback: bool = false
var _logger_instance: Object = null
var _logger_unavailable: bool = false

# popup-driven autocomplete state. Ephemeral session fields - see the
# matching block in EditorConsole.gd for rationale.
var _matching_commands: Array[String] = []
var _user_draft: String = ""
var _popup_open: bool = false
var _last_input_action: String = ""
# True while _preview_autocomplete_selection writes to input_line so the
# resulting text_changed signal doesn't overwrite _user_draft.
var _suppress_text_changed: bool = false
# See EditorConsole._preview_pending for rationale.
var _preview_pending: bool = false

const _MAX_POPUP_ITEMS := 12

# --- W1 bash polish: shared color palette ----------------------------------
# Welcome banner + bash-style prompt + per-token command coloring. Kept as
# module constants so the test suite and future themers can reference the
# exact hex values rather than scraping render output.
const _COLOR_BANNER_TEXT := "#5FBEE0"
const _COLOR_PROMPT_DIM := "#606060"
const _COLOR_PROMPT_USER := "#44FF44"
const _COLOR_PROMPT_CWD := "#5FBEE0"
const _COLOR_COMMAND_NAME := "#F7DC6F"
const _COLOR_FLAG_OR_PIPE := "#FF6B9D"
const _COLOR_STRING_LITERAL := "#5FBEE0"
const _REVERSE_SEARCH_PROMPT_PREFIX := "(reverse-i-search)`"

# bash polish: Ctrl+R reverse-history-search state. Plain runtime-only
# fields; GameConsole is NOT a @tool script. _reverse_search_index points
# at the slot in command_history we last matched at; the next backward
# step starts from index - 1. pre_input / pre_caret / pre_placeholder hold
# the LineEdit state at search-start so Esc can restore it exactly.
var _reverse_search_active: bool = false
var _reverse_search_query: String = ""
var _reverse_search_index: int = -1
var _reverse_search_pre_input: String = ""
var _reverse_search_pre_caret: int = 0
var _reverse_search_pre_placeholder: String = ""

# --- T5 readline shortcuts: kill ring (single-slot, per-instance) ---
# Holds the last killed text from Ctrl+W / Ctrl+K for Ctrl+Y to yank back
# at the caret. Bash uses a multi-slot ring; one slot is enough here since
# nothing in the addon needs ring rotation today. Independent per console
# instance - no global sharing between GameConsole and EditorConsole.
var _kill_ring: String = ""

func _command_registry() -> Node:
	return get_node_or_null("/root/CommandRegistry")

func _ready():
	set_process_mode(Node.PROCESS_MODE_ALWAYS)
	add_to_group("GameConsole")
	
	_setup_ui()
	
	input_line.text_submitted.connect(_on_command_submitted)
	input_line.gui_input.connect(_on_input_line_gui_input)
	input_line.text_changed.connect(_on_input_text_changed)
	input_line.focus_exited.connect(_on_input_focus_exited)
	close_button.pressed.connect(hide_console)
	
	if is_instance_valid(autocomplete_list):
		autocomplete_list.item_clicked.connect(_on_autocomplete_item_clicked)
		autocomplete_list.item_activated.connect(_on_autocomplete_item_activated)
	if is_instance_valid(autocomplete_popup):
		autocomplete_popup.visible = false
	if is_instance_valid(resize_handle):
		resize_handle.mouse_default_cursor_shape = Control.CURSOR_VSIZE
		resize_handle.gui_input.connect(_on_resize_handle_gui_input)
	resized.connect(_on_self_resized)
	
	_apply_persisted_config()
	_show_welcome_banner()
	call_deferred("_set_initial_size")
	

func _set_initial_size():
	custom_minimum_size.y = 0
	set_deferred("size.y", 0)

func _setup_ui():
	background.color = Color(0, 0, 0, 0.85)
	
	output_text.bbcode_enabled = true
	output_text.scroll_following = true
	#  high-contrast defaults for the runtime overlay. The 85% black
	# background from GameConsole.tscn stays; we lift the unmarked text
	# color toward white and bump the base font size so logs read cleanly
	# at 1080p without having to override every category color.
	output_text.add_theme_color_override("default_color", Color("#F0F0F0"))
	# Bumped progressively (14 -> 16 -> 18). Tunable at runtime via the
	# `font_size` command.
	output_text.add_theme_font_size_override("normal_font_size", 18)
	# Bumped progressively (5 -> 12 -> 20 -> 22). Game console is slightly
	# larger than editor since it overlays gameplay at 1080p.
	output_text.add_theme_constant_override("line_separation", 22)
	output_text.add_theme_constant_override("text_highlight_v_padding", 0)
	
	input_line.placeholder_text = "Enter command... (F12 to close)"
	#  blinking caret so the input always feels "alive" - Godot defaults
	# to no blink on LineEdit which makes the cursor easy to lose.
	input_line.caret_blink = true
	input_line.caret_blink_interval = 0.5
	
	close_button.text = "×"
	close_button.custom_minimum_size = Vector2(30, 30)

func _input(event):
	if not visible:
		return
	
	#  Ctrl+Scroll on the GameConsole adjusts opacity. We use _input
	# (not _gui_input) because most descendant Controls have MOUSE_FILTER_STOP
	# and would otherwise block the wheel event from bubbling to the parent.
	# The rect check keeps the hook scoped to the console's actual area.
	if event is InputEventMouseButton and event.pressed and event.ctrl_pressed:
		var mouse_event: InputEventMouseButton = event as InputEventMouseButton
		var btn: int = mouse_event.button_index
		if btn == MOUSE_BUTTON_WHEEL_UP or btn == MOUSE_BUTTON_WHEEL_DOWN:
			if get_global_rect().has_point(mouse_event.global_position):
				var delta: float = _OPACITY_SCROLL_STEP if btn == MOUSE_BUTTON_WHEEL_UP else -_OPACITY_SCROLL_STEP
				_adjust_opacity_by(delta)
				get_viewport().set_input_as_handled()
				return
	
	if event is InputEventKey and event.pressed:
		# ESC: when the autocomplete popup is open, gui_input handles dismissal
		# and we must not also close the console. F12 and Ctrl+` always close
		# regardless of popup state - those are dedicated console toggles, not
		# popup escape.
		#  while a Ctrl+R reverse search is active, Esc cancels the search
		# (handled in _on_input_line_gui_input). It must NOT also close the
		# console, otherwise the user loses both the search state AND the
		# whole overlay in one keystroke.
		var is_escape_close: bool = event.keycode == KEY_ESCAPE and not _popup_open and not _reverse_search_active
		var is_close_combo: bool = is_escape_close \
			or event.keycode == KEY_F12 \
			or (event.keycode == KEY_QUOTELEFT and event.ctrl_pressed)
		if is_close_combo:
			hide_console()
			get_viewport().set_input_as_handled()
			return
		
		# UP/DOWN history navigation now lives in _on_input_line_gui_input so
		# the popup-open / popup-closed disambiguation is centralized. _input
		# only retains the close-console combos above.

func toggle_visibility():
	if visible and not is_animating:
		hide_console()
	elif not visible and not is_animating:
		show_console()

func show_console():
	if is_animating:
		return
	
	visible = true
	is_animating = true
	focus_command_input()
	
	var tween = create_tween()
	tween.tween_method(_update_height, 0.0, target_height, 0.3)
	tween.tween_callback(_on_show_complete)

func hide_console():
	if is_animating:
		return
	
	_dismiss_autocomplete_popup(false)
	is_animating = true
	
	var tween = create_tween()
	tween.tween_method(_update_height, size.y, 0.0, 0.2)
	tween.tween_callback(_on_hide_complete)

func _update_height(height: float):
	custom_minimum_size.y = height
	size.y = height

func focus_command_input():
	if not input_line:
		return
	input_line.call_deferred("grab_focus")
	call_deferred("_apply_input_caret")

func _apply_input_caret():
	if input_line:
		input_line.caret_column = input_line.text.length()

func _on_show_complete():
	is_animating = false
	focus_command_input()

func _on_hide_complete():
	is_animating = false
	visible = false

func _on_command_submitted(command: String):
	_dismiss_autocomplete_popup(false)
	_execute_command(command)

func _execute_command(command: String):
	if command.strip_edges().is_empty():
		return
	
	_dismiss_autocomplete_popup(false)
	command_history.append(command)
	history_index = command_history.size()
	
	#  bash-style echoed prompt. _format_bash_prompt produces a fully
	# BBCode-colorized line; _colorize_message in add_log_message early-outs
	# on strings that already contain [color=], so we won't double-wrap.
	add_log_message(_format_bash_prompt(command), LOG_LEVEL_INFO)
	
	var registry := _command_registry()
	if not registry:
		add_log_message("Command registry is not available.", LOG_LEVEL_ERROR)
		return

	var result = registry.execute_command(command)
	if result != null and not str(result).is_empty():
		add_log_message(str(result), LOG_LEVEL_INFO)
	
	input_line.clear()
	focus_command_input()

func add_log_message(message: String, level: int = LOG_LEVEL_INFO):
	if not output_text:
		return
	var color = _get_level_color(level)
	#  per-token category colorization. GameConsole intentionally skips
	# the [url=...] click-wrap that EditorConsole applies - runtime overlays
	# can't call EditorInterface, and a styled-but-inert link would mislead
	# end users. Paths still get the cyan color treatment.
	var decorated: String = _colorize_message(message)
	var formatted_line := "[color=%s]%s[/color]\n" % [color, decorated]
	output_text.append_text(formatted_line)
	# Mirror to meta buffer for test inspectability and future overlay use.
	# RichTextLabel.text doesn't reflect append_text content in Godot 4, and
	# get_parsed_text() may lag in headless contexts.
	var buffer: Array = _ensure_log_buffer()
	buffer.append(formatted_line)

func clear_output():
	if output_text:
		output_text.clear()
	set_meta(_META_LOG_BUFFER, [])

# Public accessor for the log buffer. Tests should use this rather than
# poking at RichTextLabel state, which is unreliable in headless runs.
func get_log_buffer() -> Array:
	return _ensure_log_buffer()

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
# Near-duplicate of the EditorConsole helpers, but path detection skips the
# [url=...] click-wrap (runtime context can't open files in the editor). All
# scanning runs once over the original message and collects non-overlapping
# (start, end, replacement) edits, which are then applied right-to-left.

const _COLOR_PATH := "#5FBEE0"
const _COLOR_NUMBER := "#F7DC6F"
const _COLOR_ERROR_TOKEN := "#FF4444"
const _COLOR_WARNING_TOKEN := "#FFAA00"

func _colorize_message(message: String) -> String:
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
	
	_detect_paths(message, edits, skip_ranges, false)
	_detect_numbers(message, edits, skip_ranges)
	
	edits.sort_custom(func(a, b): return int(a[0]) > int(b[0]))
	var result: String = message
	for e in edits:
		var start: int = int(e[0])
		var end_pos: int = int(e[1])
		var repl: String = str(e[2])
		result = result.substr(0, start) + repl + result.substr(end_pos)
	return result

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
		if i > 0 and _is_word_char(message[i - 1]):
			i += 1
			continue
		var start: int = i
		while i < n and _is_digit(message[i]):
			i += 1
		if i < n - 1 and message[i] == "." and _is_digit(message[i + 1]):
			i += 1
			while i < n and _is_digit(message[i]):
				i += 1
		var unit_end: int = i
		var best_unit_len: int = 0
		for u in units:
			var ulen: int = str(u).length()
			if message.substr(i, ulen) == str(u) and ulen > best_unit_len:
				best_unit_len = ulen
		if best_unit_len > 0:
			unit_end = i + best_unit_len
		if unit_end < n and _is_word_char(message[unit_end]):
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
# ---------------- end T2.2 output renderer helpers ----------------

func _navigate_history(direction: int):
	if command_history.is_empty():
		return
	
	history_index = clamp(history_index + direction, 0, command_history.size())
	
	if history_index < command_history.size():
		input_line.text = command_history[history_index]
		input_line.caret_column = input_line.text.length()
	else:
		input_line.clear()

# ---------------- T2.1 popup-driven autocomplete (commands + node paths) ----------------
# Until T3.2, GameConsole supported only "commands" mode. T3.2 added
# "node_paths" so commands like `inspect` / `get` / `set` can suggest live
# scene-tree paths at runtime. Other editor-only modes (files, directories,
# node_types) intentionally aren't mirrored - there's no filesystem-editing
# story at runtime.

func _on_input_line_gui_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	var key_event: InputEventKey = event as InputEventKey
	var ctrl: bool = key_event.ctrl_pressed
	var shift: bool = key_event.shift_pressed or Input.is_key_pressed(KEY_SHIFT)
	
	#  reverse search has highest priority. While active, ALL keys funnel
	# through the search handler so typing builds the query, Tab/arrows
	# commit, Enter executes, Esc cancels, and Ctrl+R steps to the next
	# older match. Bypasses the popup machinery and Ctrl-prefix branch
	# below to keep search UX isolated from autocomplete UX.
	if _reverse_search_active:
		_handle_reverse_search_key(key_event, ctrl)
		return
	
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
				#  bash-style Ctrl+L clears the scrollback. We deliberately
				# keep the current input_line text untouched so a half-typed
				# command isn't lost when the user just wants a clean view.
				_last_input_action = "clear_console"
				clear_output()
				accept_event()
				return
			KEY_R:
				#  enter reverse history search mode. _reverse_search_start
				# captures the current input/caret/placeholder for Esc-restore
				# and resets the popup; the handler at the top of this method
				# takes over key dispatch on the next event.
				_last_input_action = "reverse_search_start"
				_reverse_search_start()
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
		KEY_TAB:
			if _popup_open and not _matching_commands.is_empty():
				if shift:
					_last_input_action = "cycle_prev"
					_cycle_autocomplete_selection(-1)
					_preview_autocomplete_selection()
				elif _preview_pending:
					# bash-style: first Tab after the popup opens tries to
					# advance the typed word to the longest common prefix
					# across all matches BEFORE previewing any single item.
					# If we advance, leave _preview_pending true so a follow-up
					# Tab will re-try LCP (no-op once we're at it) and then
					# fall through to preview-and-cycle.
					if _maybe_advance_to_common_prefix():
						_last_input_action = "advance_to_prefix"
					else:
						_last_input_action = "preview_current"
						_preview_pending = false
						_preview_autocomplete_selection()
				else:
					_last_input_action = "cycle_next"
					_cycle_autocomplete_selection(1)
					_preview_autocomplete_selection()
			else:
				_last_input_action = "open_popup"
				_show_autocomplete_popup()
				if _popup_open and not _matching_commands.is_empty():
					# Same LCP-first behavior on the popup-not-yet-open path:
					# the user pressed Tab on raw input; if there's a shared
					# prefix to extend toward, do that instead of jumping
					# straight to the first item.
					if _maybe_advance_to_common_prefix():
						_last_input_action = "advance_to_prefix"
					else:
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
			# When popup is closed, _input() handles ESC as the close-console
			# combo. We do nothing here so the event keeps propagating.
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
		# Enter is intentionally NOT handled here: input_line.text_submitted
		# fires for Enter and routes through _on_command_submitted, which
		# dismisses the popup and executes the command.

func _on_input_text_changed(new_text: String) -> void:
	if _suppress_text_changed:
		return
	_user_draft = new_text
	_show_autocomplete_popup()

func _on_input_focus_exited() -> void:
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

func _show_autocomplete_popup() -> void:
	if not is_instance_valid(input_line) or not is_instance_valid(autocomplete_popup):
		return
	if input_line.text.strip_edges().is_empty():
		_matching_commands.clear()
		_dismiss_autocomplete_popup(false)
		return
	_refresh_command_matches()
	if _matching_commands.is_empty():
		_dismiss_autocomplete_popup(false)
		return
	_populate_popup_list()
	autocomplete_popup.visible = true
	_popup_open = true
	_preview_pending = true
	if is_instance_valid(autocomplete_list) and autocomplete_list.item_count > 0:
		autocomplete_list.select(0)
		autocomplete_list.ensure_current_is_visible()
	_position_autocomplete_popup()

func _refresh_command_matches() -> void:
	# - dispatch by mode. The runtime console supports two modes:
	# "commands" (the legacy default) and "node_paths" (for inspect, get,
	# set, watch, scene_tree, signals, properties). Editor-only modes
	# (files, directories, filenames_only, node_types) make no sense at
	# runtime and aren't mirrored here.
	_matching_commands.clear()
	if not is_instance_valid(input_line):
		return
	var current_text: String = input_line.text
	var caret_pos: int = input_line.caret_column
	var word_start: int = caret_pos
	while word_start > 0 and current_text[word_start - 1] != " ":
		word_start -= 1
	var current_word: String = current_text.substr(word_start, caret_pos - word_start)
	
	var mode: String = _determine_autocomplete_mode(current_text, caret_pos)
	match mode:
		"node_paths":
			_get_node_path_suggestions(current_word)
		_:
			_get_command_suggestions(current_word)
	
	if _matching_commands.size() > _MAX_POPUP_ITEMS:
		_matching_commands = _matching_commands.slice(0, _MAX_POPUP_ITEMS)

# - commands whose first arg is a live node path. PUNT: per-target
# property completion for `get <target>.<property>` is intentionally not
# implemented - see EditorConsole._determine_autocomplete_mode for the
# same note. We always suggest node paths for the first arg.
const _NODE_PATH_ARG_COMMANDS := [
	"inspect", "get", "set", "watch", "scene_tree", "signals", "properties"
]
const _NODE_PATH_DEPTH_CAP := 4
const _NODE_PATH_MAX_SUGGESTIONS := 20

func _determine_autocomplete_mode(text: String, caret_pos: int) -> String:
	var typed: String = text.substr(0, caret_pos)
	var arg_index: int = typed.count(" ")
	if arg_index == 0:
		return "commands"
	var parts: PackedStringArray = typed.split(" ", false)
	if parts.is_empty():
		return "commands"
	var command: String = parts[0].to_lower()
	if command in _NODE_PATH_ARG_COMMANDS:
		return "node_paths"
	return "commands"

func _get_command_suggestions(current_word: String) -> void:
	_matching_commands = []
	var registry := _command_registry()
	if not registry:
		return
	var available: Array = registry.get_available_commands()
	var matches: Array[String] = []
	for cmd in available:
		if str(cmd).begins_with(current_word):
			matches.append(str(cmd))
	_matching_commands = matches

func _get_node_path_suggestions(current_word: String) -> void:
	# - runtime parity with EditorConsole._get_node_path_suggestions.
	# We merge three sources:
	#   1) "Engine" - global singleton (always offered, prefix-filtered)
	#   2) Direct children of /root - autoload short names + the current
	#      scene's top node. Addressable by short name.
	#   3) Descendants of /root as absolute /root/... paths, capped at
	#      depth 4 so an instanced UI scene can't balloon the popup.
	# Runtime has no EditorInterface, so the descendant walk always uses
	# the live SceneTree root.
	var suggestions: Array[String] = []
	
	if current_word.is_empty() or "Engine".begins_with(current_word):
		suggestions.append("Engine")
	
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		for child in tree.root.get_children():
			if not is_instance_valid(child):
				continue
			var nm: String = str(child.name)
			if current_word.is_empty() or nm.begins_with(current_word):
				if not suggestions.has(nm):
					suggestions.append(nm)
		_collect_node_path_descendants(tree.root, current_word, suggestions, 0)
	
	if suggestions.size() > _NODE_PATH_MAX_SUGGESTIONS:
		suggestions = suggestions.slice(0, _NODE_PATH_MAX_SUGGESTIONS)
	
	_matching_commands = suggestions

func _collect_node_path_descendants(node: Node, current_word: String, suggestions: Array[String], depth: int) -> void:
	# Capped recursive walk. Each descendant is added as its absolute
	# `/root/...` path. We keep recursing even when the parent's path
	# doesn't match the prefix, because a deeper descendant's full path
	# may still match.
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

func _populate_popup_list() -> void:
	if not is_instance_valid(autocomplete_list):
		return
	autocomplete_list.clear()
	for suggestion in _matching_commands:
		autocomplete_list.add_item(str(suggestion))
	# See EditorConsole._populate_popup_list for rationale.
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
		if is_instance_valid(input_line) and is_inside_tree():
			_finalize_popup_position(input_line.get_global_rect())

func _position_autocomplete_popup() -> void:
	if not is_instance_valid(autocomplete_popup) or not is_instance_valid(input_line):
		return
	if not is_inside_tree():
		return
	var input_global: Rect2 = input_line.get_global_rect()
	var popup_min_width: float = max(input_global.size.x, 200.0)
	autocomplete_popup.custom_minimum_size = Vector2(popup_min_width, 0)
	call_deferred("_finalize_popup_position", input_global)

func _finalize_popup_position(input_global: Rect2) -> void:
	if not is_instance_valid(autocomplete_popup) or not is_inside_tree():
		return
	var popup_size: Vector2 = autocomplete_popup.size
	var viewport_size: Vector2 = get_viewport_rect().size
	var above_y: float = input_global.position.y - popup_size.y
	var below_y: float = input_global.position.y + input_global.size.y
	var y: float = above_y
	if above_y < 0.0:
		y = below_y
	var x: float = clamp(input_global.position.x, 0.0, max(0.0, viewport_size.x - popup_size.x))
	autocomplete_popup.global_position = Vector2(x, y)

func _dismiss_autocomplete_popup(restore_draft: bool) -> void:
	if is_instance_valid(autocomplete_popup):
		autocomplete_popup.visible = false
	_popup_open = false
	if restore_draft and is_instance_valid(input_line):
		input_line.text = _user_draft
		input_line.caret_column = input_line.text.length()

func _cycle_autocomplete_selection(delta: int) -> void:
	if _matching_commands.is_empty() or not is_instance_valid(autocomplete_list):
		return
	var count: int = _matching_commands.size()
	var current: int = autocomplete_list.get_selected_items()[0] if autocomplete_list.get_selected_items().size() > 0 else 0
	var next_idx: int = ((current + delta) % count + count) % count
	if next_idx < autocomplete_list.item_count:
		autocomplete_list.select(next_idx)
		autocomplete_list.ensure_current_is_visible()

func _apply_autocomplete_selection() -> void:
	if _matching_commands.is_empty() or not is_instance_valid(autocomplete_list):
		_dismiss_autocomplete_popup(false)
		return
	var selected_items: PackedInt32Array = autocomplete_list.get_selected_items()
	if selected_items.is_empty():
		_dismiss_autocomplete_popup(false)
		return
	var idx: int = clamp(selected_items[0], 0, _matching_commands.size() - 1)
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

# Writes the current highlighted suggestion into input_line WITHOUT dismissing
# the popup. Used by Tab/Up/Down cycling so the user gets bash-style live
# preview. Esc still restores _user_draft.
func _preview_autocomplete_selection() -> void:
	if _matching_commands.is_empty() or not is_instance_valid(autocomplete_list):
		return
	if not is_instance_valid(input_line):
		return
	var selected_items: PackedInt32Array = autocomplete_list.get_selected_items()
	if selected_items.is_empty():
		return
	var idx: int = clamp(selected_items[0], 0, _matching_commands.size() - 1)
	var selected: String = str(_matching_commands[idx])
	var draft: String = _user_draft
	var word_start: int = draft.length()
	while word_start > 0 and draft[word_start - 1] != " ":
		word_start -= 1
	var new_text: String = draft.substr(0, word_start) + selected
	_suppress_text_changed = true
	input_line.text = new_text
	input_line.caret_column = new_text.length()
	_suppress_text_changed = false

func _on_autocomplete_item_clicked(index: int, _at_position: Vector2, _mouse_button_index: int) -> void:
	if is_instance_valid(autocomplete_list):
		autocomplete_list.select(index)
	_apply_autocomplete_selection()
	if is_instance_valid(input_line):
		input_line.grab_focus()
		input_line.caret_column = input_line.text.length()

func _on_autocomplete_item_activated(index: int) -> void:
	if is_instance_valid(autocomplete_list):
		autocomplete_list.select(index)
	_apply_autocomplete_selection()
	if is_instance_valid(input_line):
		input_line.grab_focus()
		input_line.caret_column = input_line.text.length()

func _on_self_resized() -> void:
	if _popup_open:
		_position_autocomplete_popup()

# ---------------- W1 bash polish: banner, prompt, token coloring ----------
# Welcome banner is written via add_log_message so it lands in both the
# RichTextLabel and the meta log buffer that tests inspect. The banner
# message already contains [color=] BBCode, so _colorize_message early-outs
# and we keep our exact per-glyph palette.

func _show_welcome_banner() -> void:
	if not is_instance_valid(output_text):
		return
	# Box-drawing characters use the dim gray default that LOG_LEVEL_INFO's
	# outer wrap supplies; the text inside the box is explicitly cyan.
	var banner_lines: Array = [
		"[color=%s]╔═════════════════════════════════════════════════╗[/color]" % _COLOR_PROMPT_DIM,
		"[color=%s]║[/color]  [color=%s]Debug Console (Runtime)[/color]                        [color=%s]║[/color]" % [_COLOR_PROMPT_DIM, _COLOR_BANNER_TEXT, _COLOR_PROMPT_DIM],
		"[color=%s]║[/color]  [color=%s]F12 close • Tab cycle • Ctrl+R history search[/color]  [color=%s]║[/color]" % [_COLOR_PROMPT_DIM, _COLOR_BANNER_TEXT, _COLOR_PROMPT_DIM],
		"[color=%s]╚═════════════════════════════════════════════════╝[/color]" % _COLOR_PROMPT_DIM,
	]
	for line in banner_lines:
		add_log_message(str(line), LOG_LEVEL_INFO)

# Build the colored prompt prefix `[player@runtime cwd]$ ` followed by the
# per-token colored command. BuiltInCommands.get_current_directory is a
# static method on a class_name RefCounted - it's safe to reference at
# runtime (no autoload dependency).
func _format_bash_prompt(command: String) -> String:
	# BuiltInCommands is a `class_name extends RefCounted` static helper
	# (not an autoload). Calling its static `get_current_directory` directly
	# is the pattern EditorConsole.gd already uses.
	var cwd: String = BuiltInCommands.get_current_directory()
	var prompt: String = "[color=%s][[/color][color=%s]player[/color][color=%s]@[/color][color=%s]runtime[/color] [color=%s]%s[/color][color=%s]]$[/color] " % [
		_COLOR_PROMPT_DIM,
		_COLOR_PROMPT_USER,
		_COLOR_PROMPT_DIM,
		_COLOR_PROMPT_USER,
		_COLOR_PROMPT_CWD,
		cwd,
		_COLOR_PROMPT_DIM,
	]
	return prompt + _colorize_command_input(command)

# Per-token coloring for the echoed command line. Rules mirror the
# EditorConsole bash polish:
#   - first non-special token (and the token after any `|`) = command name → yellow
#   - tokens beginning with `-` (flags) → pink/red
#   - bare `|` token (pipe) → pink/red
#   - tokens fully wrapped in matching quotes → cyan
#   - everything else stays unwrapped (inherits surrounding default color)
func _colorize_command_input(command: String) -> String:
	if command.is_empty():
		return command
	var tokens: Array = _tokenize_command(command)
	var parts: Array = []
	var command_token_used: bool = false
	for raw in tokens:
		var t: String = str(raw)
		if t == "|":
			parts.append("[color=%s]|[/color]" % _COLOR_FLAG_OR_PIPE)
			# Reset so the next bare word after a pipe is treated as a new
			# command name (matches bash pipeline behavior).
			command_token_used = false
			continue
		if _is_quoted_string(t):
			parts.append("[color=%s]%s[/color]" % [_COLOR_STRING_LITERAL, t])
			continue
		if t.begins_with("-"):
			parts.append("[color=%s]%s[/color]" % [_COLOR_FLAG_OR_PIPE, t])
			continue
		if not command_token_used:
			parts.append("[color=%s]%s[/color]" % [_COLOR_COMMAND_NAME, t])
			command_token_used = true
			continue
		parts.append(t)
	return " ".join(parts)

func _is_quoted_string(token: String) -> bool:
	if token.length() < 2:
		return false
	var first: String = token.substr(0, 1)
	var last: String = token.substr(token.length() - 1, 1)
	if first == "\"" and last == "\"":
		return true
	if first == "'" and last == "'":
		return true
	return false

# Minimal shell-like tokenizer: splits on spaces but keeps quoted strings
# (single or double) together and treats `|` as its own token. Sufficient
# for the highlighting needs - we do NOT try to be a complete shell parser
# (no escapes, no $vars, no redirects). The actual command execution still
# happens via CommandRegistry.execute_command(command) on the raw string.
func _tokenize_command(command: String) -> Array:
	var tokens: Array = []
	var n: int = command.length()
	var i: int = 0
	while i < n:
		while i < n and command[i] == " ":
			i += 1
		if i >= n:
			break
		var start: int = i
		var first: String = command[i]
		if first == "\"" or first == "'":
			var quote: String = first
			i += 1
			while i < n and command[i] != quote:
				i += 1
			if i < n:
				i += 1
			tokens.append(command.substr(start, i - start))
			continue
		if first == "|":
			tokens.append("|")
			i += 1
			continue
		while i < n and command[i] != " " and command[i] != "|":
			i += 1
		tokens.append(command.substr(start, i - start))
	return tokens

# ---------------- W1 bash polish: shared-prefix Tab + reverse search ------

# Computes the longest common starting substring across an Array of
# Strings. Returns "" for an empty input or whenever any pair of strings
# differs at position 0. Used by the Tab handler to advance the typed
# word toward the LCP before previewing individual matches.
func _longest_common_prefix(strings: Array) -> String:
	if strings.is_empty():
		return ""
	var prefix: String = str(strings[0])
	for idx in range(1, strings.size()):
		var s: String = str(strings[idx])
		var max_len: int = min(prefix.length(), s.length())
		var j: int = 0
		while j < max_len and prefix[j] == s[j]:
			j += 1
		prefix = prefix.substr(0, j)
		if prefix.is_empty():
			break
	return prefix

# Attempts to replace the word at the caret with the longest common
# prefix of _matching_commands. Returns true ONLY when the word was
# actually advanced (multi-match, LCP longer than the typed word, and
# LCP begins with the typed word). Callers leave _preview_pending in its
# pre-call state on success so the popup item highlight isn't disturbed.
func _maybe_advance_to_common_prefix() -> bool:
	if _matching_commands.size() < 2:
		return false
	if not is_instance_valid(input_line):
		return false
	var lcp: String = _longest_common_prefix(_matching_commands)
	if lcp.is_empty():
		return false
	var current_text: String = input_line.text
	var caret_pos: int = input_line.caret_column
	var word_start: int = caret_pos
	while word_start > 0 and current_text[word_start - 1] != " ":
		word_start -= 1
	var current_word: String = current_text.substr(word_start, caret_pos - word_start)
	if lcp.length() <= current_word.length():
		return false
	if not lcp.begins_with(current_word):
		return false
	var new_text: String = current_text.substr(0, word_start) + lcp + current_text.substr(caret_pos)
	var new_caret: int = word_start + lcp.length()
	_suppress_text_changed = true
	input_line.text = new_text
	input_line.caret_column = new_caret
	_suppress_text_changed = false
	_user_draft = new_text
	_refresh_command_matches()
	if _matching_commands.is_empty():
		_dismiss_autocomplete_popup(false)
	else:
		_populate_popup_list()
		if is_instance_valid(autocomplete_list) and autocomplete_list.item_count > 0:
			autocomplete_list.select(0)
			autocomplete_list.ensure_current_is_visible()
		_position_autocomplete_popup()
	return true

# ---- Reverse history search (Ctrl+R) -------------------------------------
# Bash-style incremental backward search through command_history. Entering
# search mode snapshots the LineEdit state so Esc can restore it; each
# query character (or backspace) re-searches from the end of history; a
# subsequent Ctrl+R steps to the NEXT older match for the same query;
# Tab/arrow/Home/End commit the matched command and exit search mode
# (typing continues normally); Enter executes the match.

func _reverse_search_start() -> void:
	if _reverse_search_active:
		return
	_reverse_search_active = true
	_reverse_search_query = ""
	_reverse_search_index = command_history.size()
	if is_instance_valid(input_line):
		_reverse_search_pre_input = input_line.text
		_reverse_search_pre_caret = input_line.caret_column
		_reverse_search_pre_placeholder = input_line.placeholder_text
		_suppress_text_changed = true
		input_line.text = ""
		input_line.caret_column = 0
		_suppress_text_changed = false
		input_line.placeholder_text = _REVERSE_SEARCH_PROMPT_PREFIX + "': "
	_dismiss_autocomplete_popup(false)

func _reverse_search_set_query(query: String) -> void:
	if not _reverse_search_active:
		return
	_reverse_search_query = query
	_reverse_search_index = command_history.size()
	_reverse_search_step()

# Walks backward from _reverse_search_index - 1 looking for the first
# history entry that contains the current query. Updates input_line to
# show the match (or empties it when there's no match, leaving only the
# placeholder hint visible).
func _reverse_search_step() -> void:
	if not _reverse_search_active:
		return
	if is_instance_valid(input_line):
		input_line.placeholder_text = _REVERSE_SEARCH_PROMPT_PREFIX + _reverse_search_query + "': "
	var match_idx: int = -1
	if not _reverse_search_query.is_empty():
		var i: int = _reverse_search_index - 1
		while i >= 0:
			if str(command_history[i]).contains(_reverse_search_query):
				match_idx = i
				break
			i -= 1
	if match_idx >= 0:
		_reverse_search_index = match_idx
		if is_instance_valid(input_line):
			_suppress_text_changed = true
			input_line.text = str(command_history[match_idx])
			input_line.caret_column = input_line.text.length()
			_suppress_text_changed = false
	else:
		if is_instance_valid(input_line):
			_suppress_text_changed = true
			input_line.text = ""
			input_line.caret_column = 0
			_suppress_text_changed = false

# Esc: restore everything the user typed/saw before entering search mode.
func _reverse_search_cancel() -> void:
	if not _reverse_search_active:
		return
	_reverse_search_active = false
	var saved_input: String = _reverse_search_pre_input
	var saved_caret: int = _reverse_search_pre_caret
	var saved_placeholder: String = _reverse_search_pre_placeholder
	_reverse_search_query = ""
	_reverse_search_index = -1
	if is_instance_valid(input_line):
		_suppress_text_changed = true
		input_line.text = saved_input
		input_line.caret_column = saved_caret
		input_line.placeholder_text = saved_placeholder
		_suppress_text_changed = false
	_user_draft = saved_input

# Tab/arrow/Home/End: exit search mode but keep the matched command in
# the input line so the user can edit it before submitting.
func _reverse_search_commit_keep_text() -> void:
	if not _reverse_search_active:
		return
	_reverse_search_active = false
	var current: String = ""
	if is_instance_valid(input_line):
		current = input_line.text
		input_line.placeholder_text = _reverse_search_pre_placeholder
	_user_draft = current
	_reverse_search_query = ""
	_reverse_search_index = -1

# Enter: exit search mode AND execute the matched command immediately.
func _reverse_search_commit_and_execute() -> void:
	var cmd: String = ""
	if is_instance_valid(input_line):
		cmd = input_line.text
		input_line.placeholder_text = _reverse_search_pre_placeholder
	_reverse_search_active = false
	_reverse_search_query = ""
	_reverse_search_index = -1
	_user_draft = ""
	if not cmd.strip_edges().is_empty():
		_execute_command(cmd)

# Dispatch invoked from _on_input_line_gui_input while a reverse search
# is active. Unicode-bearing keys append to the query; Backspace strips
# the last char; control keys commit/cancel/step.
func _handle_reverse_search_key(key_event: InputEventKey, ctrl: bool) -> void:
	var kc: int = key_event.keycode
	if ctrl and kc == KEY_R:
		_last_input_action = "reverse_search_next"
		_reverse_search_step()
		accept_event()
		return
	match kc:
		KEY_ESCAPE:
			_last_input_action = "reverse_search_cancel"
			_reverse_search_cancel()
			accept_event()
			return
		KEY_ENTER, KEY_KP_ENTER:
			_last_input_action = "reverse_search_execute"
			_reverse_search_commit_and_execute()
			accept_event()
			return
		KEY_BACKSPACE:
			if _reverse_search_query.length() > 0:
				_reverse_search_set_query(_reverse_search_query.substr(0, _reverse_search_query.length() - 1))
			accept_event()
			return
		KEY_TAB, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END:
			_last_input_action = "reverse_search_commit"
			_reverse_search_commit_keep_text()
			accept_event()
			return
		_:
			if key_event.unicode > 0 and not ctrl and not key_event.alt_pressed:
				_reverse_search_set_query(_reverse_search_query + String.chr(key_event.unicode))
				accept_event()
				return
# ---------------- end W1 bash polish helpers ------------------------------

# ---------------- T2.3 opacity, resize, intercept ----------------
# Public method: clamp value to [_MIN_OPACITY, _MAX_OPACITY] and apply to the
# background ColorRect's alpha. Returns the clamped value so callers can
# report what was actually applied (useful for the `opacity` command output
# and for tests).
func set_opacity(value: float) -> float:
	var clamped: float = clamp(value, _MIN_OPACITY, _MAX_OPACITY)
	if is_instance_valid(background):
		var c: Color = background.color
		c.a = clamped
		background.color = c
	return clamped

func get_opacity() -> float:
	if is_instance_valid(background):
		return background.color.a
	return 0.85

func _adjust_opacity_by(delta: float) -> void:
	var current: float = get_opacity()
	var new_val: float = set_opacity(current + delta)
	_persist_console_value("opacity", new_val)

# resize-handle drag. Left-click + drag on the handle updates
# target_height live and applies it through the same _update_height() the
# show/hide tweens use, so the size you drag to becomes the new "open"
# height for subsequent show animations.
func _on_resize_handle_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var btn_event: InputEventMouseButton = event as InputEventMouseButton
		if btn_event.button_index == MOUSE_BUTTON_LEFT:
			if btn_event.pressed:
				_is_resizing = true
				_resize_start_mouse_y = btn_event.global_position.y
				_resize_start_height = target_height
			else:
				if _is_resizing:
					_is_resizing = false
					_persist_console_value("height", target_height)
	elif event is InputEventMouseMotion and _is_resizing:
		var motion_event: InputEventMouseMotion = event as InputEventMouseMotion
		var delta_y: float = motion_event.global_position.y - _resize_start_mouse_y
		var new_h: float = _resize_start_height + delta_y
		_set_height_clamped(new_h)

# Clamps a requested height to [_MIN_HEIGHT, 0.8 * viewport_height], stores
# it in target_height, and applies it live if the console is currently
# shown and not in the middle of a show/hide tween. Tweens capture the
# height value when they start; mid-tween mutations don't disturb the
# active animation but do take effect for the next show/hide.
func _set_height_clamped(h: float) -> void:
	target_height = _clamp_height(h)
	if visible and not is_animating:
		_update_height(target_height)

func _clamp_height(h: float) -> float:
	var vp: Viewport = get_viewport()
	var vp_h: float = 0.0
	if vp:
		vp_h = vp.get_visible_rect().size.y
	# If the viewport reports a non-meaningful size (early _ready, headless
	# test fixture, not-yet-sized window), don't clamp aggressively - just
	# enforce the minimum. The drag handle re-clamps against the live
	# viewport when the user actually resizes, so a stale max here only
	# matters until the first drag.
	if vp_h < 200.0:
		return max(_MIN_HEIGHT, h)
	var max_h: float = max(_MIN_HEIGHT, vp_h * 0.8)
	return clamp(h, _MIN_HEIGHT, max_h)

# Reads opacity + height from user://debug_console_config.cfg and applies
# them. Called once during _ready(). Failure modes (missing file, missing
# section, missing key) all silently fall through to defaults - this is
# a UX preference store, not a critical path.
func _apply_persisted_config() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load(_CONSOLE_CONFIG_PATH) != OK:
		return
	if not cfg.has_section(_CONSOLE_CONFIG_SECTION):
		return
	if cfg.has_section_key(_CONSOLE_CONFIG_SECTION, "opacity"):
		var raw_op: Variant = cfg.get_value(_CONSOLE_CONFIG_SECTION, "opacity", 0.85)
		var op_f: float = float(raw_op)
		# Accept either 0.0..1.0 or 0..100 - the `opacity` command accepts
		# both formats too, and we normalize for backward compat.
		if op_f > 1.0:
			op_f = op_f / 100.0
		set_opacity(op_f)
	if cfg.has_section_key(_CONSOLE_CONFIG_SECTION, "height"):
		var raw_h: Variant = cfg.get_value(_CONSOLE_CONFIG_SECTION, "height", 400)
		target_height = _clamp_height(float(raw_h))

# Writes a single key into the existing console config section. We load
# first so we don't blow away other keys (font_size, etc.) that might be
# set via the `config` command.
func _persist_console_value(key: String, value: Variant) -> void:
	var cfg: ConfigFile = ConfigFile.new()
	cfg.load(_CONSOLE_CONFIG_PATH)
	cfg.set_value(_CONSOLE_CONFIG_SECTION, key, value)
	cfg.save(_CONSOLE_CONFIG_PATH)

# print interception.
#
# Godot 4.5+ exposes the Logger class to GDScript and OS.add_logger
# accepts a Logger subclass. We conditionally load GameConsoleLogger.gd
# (which `extends Logger`) only when both are available; on older
# engines, intercept becomes a no-op that returns false.
#
# There is no OS.remove_logger from GDScript in 4.6, so once attached
# the Logger instance stays for the application lifetime. Toggling
# intercept off flips _intercept_enabled and the Logger discards events
# at the source.
#
# Re-entry guard (_in_logger_callback) ensures that if add_log_message
# itself triggers a print (e.g., DebugCore.Log pushing into Output),
# the callback can't recurse infinitely.
func set_intercept_enabled(enabled: bool) -> bool:
	if enabled and _logger_instance == null and not _logger_unavailable:
		if ClassDB.class_exists("Logger") and OS.has_method("add_logger"):
			var logger_script: Script = load("res://addons/debug_console/game/GameConsoleLogger.gd")
			if logger_script != null:
				_logger_instance = logger_script.new(self)
				OS.call("add_logger", _logger_instance)
			else:
				_logger_unavailable = true
		else:
			_logger_unavailable = true
	if enabled and _logger_unavailable:
		_intercept_enabled = false
		return false
	_intercept_enabled = enabled
	return _intercept_enabled

func is_intercept_enabled() -> bool:
	return _intercept_enabled

# True when the engine exposes the Logger API. UIs / commands can use
# this to surface "intercept unavailable on this Godot version" hints.
func is_intercept_available() -> bool:
	return ClassDB.class_exists("Logger") and OS.has_method("add_logger")

# Hook invoked by GameConsoleLogger. The re-entry guard prevents
# infinite recursion when add_log_message indirectly triggers another
# print (e.g., via DebugCore.Log or RichTextLabel internals).
func _on_intercepted_log(message: String, level: int) -> void:
	if _in_logger_callback:
		return
	_in_logger_callback = true
	add_log_message(message, level)
	_in_logger_callback = false

# --- T5 readline shortcuts ---
# Bash readline parity for word-level editing in the input line:
#   Ctrl+W  - delete word backward (push into _kill_ring)
#   Ctrl+K  - kill from caret to end of line (push into _kill_ring)
#   Ctrl+Y  - yank the kill ring at the caret
#   Alt+B   - move caret one word back (no deletion)
#   Alt+F   - move caret one word forward (no deletion)
# Word boundary chars include shell metas and the path separator so that
# segmented paths like res://addons/debug_console/editor navigate
# token-by-token. Whitespace is also a boundary; alphanumerics, dots,
# underscores, hyphens, colons and quotes are treated as word-internal.

const _T5_WORD_BOUNDARY_CHARS := " \t|><&;/"

func _t5_is_word_boundary(ch: String) -> bool:
	return ch.length() > 0 and _T5_WORD_BOUNDARY_CHARS.contains(ch)

func _t5_word_back_index(text: String, caret: int) -> int:
	# Mirror bash M-b / C-w: skip boundary chars left, then non-boundary
	# chars left. Returns the column where the previous word begins.
	var i: int = clamp(caret, 0, text.length())
	while i > 0 and _t5_is_word_boundary(text.substr(i - 1, 1)):
		i -= 1
	while i > 0 and not _t5_is_word_boundary(text.substr(i - 1, 1)):
		i -= 1
	return i

func _t5_word_forward_index(text: String, caret: int) -> int:
	# Mirror bash M-f: skip boundary chars right, then non-boundary chars
	# right. Returns the column at the end of the next word.
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
