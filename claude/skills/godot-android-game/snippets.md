# Code-Bausteine (GDScript, aus Orbitrio)

Vollständige Referenz: `~/Entwicklung/numberJoin/scripts/game_controller.gd` und `sound_manager.gd`.
Namen an das Projekt anpassen (`ring` → eigener State, Overlays wie in der Szene).

## Speichern / Fortsetzen

```gdscript
const SAVE_PATH := "user://savegame.cfg"
const SETTINGS_PATH := "user://settings.cfg"

# Tests and screenshots clear this before adding the node: then nothing is read or written
var persist: bool = true
var save_path: String = ""
var game_running: bool = false

func _ready() -> void:
	if persist:
		save_path = SAVE_PATH
	# ...
	_load_running_game()
	show_menu()  # menu shows CONTINUE when game_running

# Keeps the running game on disk after every move, so it survives the app being closed or
# killed in the background; without a running game the file goes away
func _save_running_game() -> void:
	if save_path.is_empty():
		return
	if not game_running:
		if FileAccess.file_exists(save_path):
			DirAccess.remove_absolute(save_path)
		return
	var cfg := ConfigFile.new()
	cfg.set_value("game", "state", state.to_dict())
	cfg.save(save_path)

func _load_running_game() -> void:
	if save_path.is_empty() or not FileAccess.file_exists(save_path):
		return
	var cfg := ConfigFile.new()
	var data: Variant = cfg.get_value("game", "state") if cfg.load(save_path) == OK else null
	if not data is Dictionary or not state.from_dict(data):
		# A damaged file is dropped, the menu just offers a new game
		DirAccess.remove_absolute(save_path)
		return
	game_running = true
	if state.is_game_over:
		# Closed while the last move was still playing: the game is over
		_finish_running_game()
		return
	view.setup(state)
```

## Lebenszyklus und Android-Zurück

```gdscript
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		# Already saved after the last move; once more to be safe. The game stays running.
		if is_node_ready():
			_save_running_game()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		go_back()

# Android back: closes the topmost dialog, then leaves the game for the menu, then quits
# (needs application/config/quit_on_go_back=false)
func go_back() -> void:
	if licenses_overlay.visible:
		licenses_overlay.hide()
	elif changelog_overlay.visible:
		changelog_overlay.hide()
	elif help_overlay.visible:
		help_overlay.hide()
	elif settings_overlay.visible:
		close_settings()
	elif about_overlay.visible:
		about_overlay.hide()
	elif current_screen == ScreenState.GAME:
		show_menu()
	else:
		_save_running_game()
		get_tree().quit()
```

## Safe Area

```gdscript
const MOBILE_MIN_INSET_TOP := 24.0
const MOBILE_MIN_INSET_BOTTOM := 16.0

# in _ready(): get_viewport().size_changed.connect(_apply_safe_area); _apply_safe_area()
func _apply_safe_area() -> void:
	var insets := _device_safe_insets()
	for area: Control in [menu_layout, game_layout, help_layout, licenses_layout, changelog_layout]:
		area.offset_left = insets.x
		area.offset_top = insets.y
		area.offset_right = -insets.z
		area.offset_bottom = -insets.w

func _device_safe_insets() -> Vector4:
	if not OS.has_feature("mobile"):
		return Vector4.ZERO
	var insets := Vector4(0.0, MOBILE_MIN_INSET_TOP, 0.0, MOBILE_MIN_INSET_BOTTOM)
	var window_size := Vector2(DisplayServer.window_get_size())
	var safe := Rect2(DisplayServer.get_display_safe_area())
	if window_size.x <= 0.0 or window_size.y <= 0.0 or safe.size.x <= 0.0 or safe.size.y <= 0.0:
		return insets
	# Safe area is in physical window pixels; the UI works in stretched viewport pixels
	var to_view := get_viewport_rect().size / window_size
	insets.x = maxf(safe.position.x, 0.0) * to_view.x
	insets.y = maxf(maxf(safe.position.y, 0.0) * to_view.y, MOBILE_MIN_INSET_TOP)
	insets.z = maxf(window_size.x - safe.end.x, 0.0) * to_view.x
	insets.w = maxf(maxf(window_size.y - safe.end.y, 0.0) * to_view.y, MOBILE_MIN_INSET_BOTTOM)
	return insets
```

## How to play beim ersten Start

```gdscript
func _mark_help_seen() -> void:
	help_seen = true
	if not persist:
		return
	# Keep the sound settings stored in the same file
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("app", "help_seen", true)
	cfg.save(SETTINGS_PATH)

func open_help() -> void:
	# Built on demand, so it is always in the current language
	_build_help()
	help_scroll.scroll_vertical = 0
	help_overlay.show()
```

## Changelog

```gdscript
# Newest first: version, build number (the Android version code), release day and changes
func changelog_entries() -> Array[Dictionary]:
	return [
		{"version": "1.0.1", "build": 2, "date": "2026-11-07", "changes": [
			tr("A running game is saved after every move.")]},
		{"version": "1.0.0", "build": 1, "date": "2026-11-06", "changes": [
			tr("First release.")]},
	]

func changelog_bbcode() -> String:
	var parts: PackedStringArray = []
	for entry in changelog_entries():
		var lines: PackedStringArray = ["[font_size=22][b][color=#40dbc7]Version %s[/color][/b][/font_size] [color=#9aa6c8](%d) · %s[/color]" % [
			entry.version, entry.build, _day_text(entry.date)]]
		for change: String in entry.changes:
			lines.append("[indent]• %s[/indent]" % change)
		parts.append("\n".join(lines))
	return "\n\n".join(parts)

# A day given as YYYY-MM-DD, written the way the UI language does: 07.11.2026 in German
static func _day_text(iso_date: String) -> String:
	if not TranslationServer.get_locale().begins_with("de"):
		return iso_date
	var p := iso_date.split("-")
	return "%s.%s.%s" % [p[2], p[1], p[0]]
```

## Lizenzen

```gdscript
const FONT_LICENSE_PATH := "res://assets/fonts/OFL-Orbitron.txt"

# Everything the licences of the shipped components ask to be reproduced: Godot's own MIT
# licence, the copyright notices and licence texts of the third-party code inside the engine
# (both straight from the engine, so they always match the version the game was built with)
# and the font licence. Legal texts stay in English in every locale.
static func license_text() -> String:
	var parts: PackedStringArray = []
	parts.append("__NAME__ © 2026 Tim Haller")
	parts.append("This game is built with Godot Engine (https://godotengine.org), licensed as follows:")
	parts.append(Engine.get_license_text())
	parts.append("\nFONT\n\nOrbitron by The League of Moveable Type, licensed under the SIL Open Font License 1.1:")
	parts.append(FileAccess.get_file_as_string(FONT_LICENSE_PATH))
	parts.append("\nTHIRD-PARTY COMPONENTS OF GODOT ENGINE\n")
	for component: Dictionary in Engine.get_copyright_info():
		var lines: PackedStringArray = [component["name"]]
		for part: Dictionary in component["parts"]:
			for holder: String in part["copyright"]:
				lines.append("  © " + holder)
			lines.append("  License: " + part["license"])
		parts.append("\n".join(lines))
	parts.append("\nLICENSE TEXTS\n")
	var licenses := Engine.get_license_info()
	for name: String in licenses:
		parts.append("%s\n\n%s" % [name, licenses[name]])
	return "\n\n".join(parts)
```

## Test-Gerüst

```gdscript
extends SceneTree

var failed := false

func _init() -> void:
	TranslationServer.set_locale("en")
	Engine.time_scale = 5.0
	var game: GameController = load("res://scenes/game.tscn").instantiate()
	game.persist = false
	root.add_child(game)
	await process_frame
	check(game.current_screen == GameController.ScreenState.MENU, "Starts in the menu")
	# ...
	quit(1 if failed else 0)

func check(condition: bool, message: String) -> void:
	if condition:
		print("  [OK] " + message)
	else:
		failed = true
		printerr("  [FAIL] " + message)
```
