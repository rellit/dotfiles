extends Control
## The "More games" page: one card per other rellit game - its Play banner, name, kind and one
## sentence. A tap on the banner or the button opens the game's page on Google Play.
##
## Template: skill godot-android-game (templates/scripts/more_games_overlay.gd); keep the copies
## equal. Built in code and dressed in the look of the host's own dialog (dress_like()), so the
## same file serves every game. The host adds it as its topmost overlay, opens it from the settings,
## closes it on Android back (close() before the settings) and plays its click sound on `clicked`.

signal clicked
signal closed

const MoreGames := preload("res://scripts/more_games.gd")
const MAX_WIDTH := 640.0
const MARGIN := 20.0
const MOBILE_MIN_INSET_TOP := 24.0
const MOBILE_MIN_INSET_BOTTOM := 16.0
const BANNER_RATIO := 375.0 / 768.0
# How far (viewport pixels) a finger may move and still tap: a swipe through the list that
# happens to start and end on a banner must not send the player to the store
const TAP_SLOP := 24.0
# Some games stack their dialogs with z_index (Hexmosis: 200-210); the page goes over all of them
const Z_INDEX := 1000

var _frame: MarginContainer
var _panel: PanelContainer
var _title: Label
var _scroll: ScrollContainer
var _list: VBoxContainer
var _close_button: Button
# The host's looks, taken in dress_like() (see MoreGames.label_look()/button_look())
var _title_look := {}
var _body_look := {}
var _button_look := {}
var _touch_from := Vector2.ZERO
var _touch_travel := 0.0
## What a tap on a card does; tests swap it so no browser opens
var store_opener := Callable(MoreGames, "open_store")


func _init() -> void:
	name = "MoreGamesOverlay"
	visible = false
	z_index = Z_INDEX
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	_frame = MarginContainer.new()
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_frame)
	_panel = PanelContainer.new()
	_frame.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	_panel.add_child(box)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_title)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 18)
	_scroll.add_child(_list)
	_close_button = Button.new()
	_close_button.text = "CLOSE"
	_close_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_close_button.custom_minimum_size = Vector2(260, 64)
	_close_button.pressed.connect(func() -> void:
		clicked.emit()
		close())
	box.add_child(_close_button)
	# Plain defaults until the host dresses the page
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.11, 0.14)
	style.set_corner_radius_all(18)
	style.set_content_margin_all(24)
	_panel.add_theme_stylebox_override("panel", style)
	_title.add_theme_font_size_override("font_size", 34)


func _ready() -> void:
	set_process_input(visible)
	get_viewport().size_changed.connect(_update_frame)
	_update_frame()


## Takes the look of the host's dialog: `panel` gives the background, `title` the heading,
## `body` the small text, `button` the buttons. The close button says `close_text`, or else what
## `button` says (usually the dialog's own "CLOSE").
func dress_like(panel: Control, title: Label, body: Label, button: Button, close_text := "") -> void:
	if panel != null and panel.has_theme_stylebox("panel"):
		_panel.add_theme_stylebox_override("panel", panel.get_theme_stylebox("panel"))
	if title != null:
		_title_look = MoreGames.label_look(title)
		MoreGames.apply_label_look(_title_look, _title)
	if body != null:
		_body_look = MoreGames.label_look(body)
	if button != null:
		_button_look = MoreGames.button_look(button)
		MoreGames.apply_button_look(_button_look, _close_button)
		_close_button.text = close_text if close_text != "" else button.text
		_close_button.custom_minimum_size.y = maxf(button.custom_minimum_size.y, 56.0)


func open() -> void:
	_title.text = "MORE GAMES"  # translated by the label itself
	_rebuild()
	_update_frame()
	show()
	set_process_input(true)
	_scroll.scroll_vertical = 0
	# The same short pop-in as the games' own dialogs
	_panel.pivot_offset = _panel.size / 2.0
	_panel.scale = Vector2(0.94, 0.94)
	_panel.modulate.a = 0.0
	var pop := _panel.create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	pop.tween_property(_panel, "scale", Vector2.ONE, 0.2)
	pop.tween_property(_panel, "modulate:a", 1.0, 0.12)


func close() -> void:
	if not visible:
		return
	hide()
	set_process_input(false)
	for card in _list.get_children():
		card.queue_free()  # the banners need not stay in memory
	closed.emit()


func card_count() -> int:
	return _list.get_child_count()


## The store button of each card, in list order (for tests)
func store_buttons() -> Array[Button]:
	var buttons: Array[Button] = []
	for card in _list.get_children():
		buttons.append_array(card.find_children("StoreButton", "Button", true, false))
	return buttons


# Sees every touch before the GUI does, so the cards can tell a tap from a swipe
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.index == 0 and event.pressed:
		_touch_from = event.position
		_touch_travel = 0.0
	elif event is InputEventScreenDrag and event.index == 0:
		_touch_travel = maxf(_touch_travel, event.position.distance_to(_touch_from))


func _rebuild() -> void:
	for card in _list.get_children():
		_list.remove_child(card)
		card.queue_free()
	for game: Dictionary in MoreGames.games():
		_list.add_child(_card(game))


func _card(game: Dictionary) -> Control:
	var text_color: Color = _body_look.get("font_color", Color(0.9, 0.9, 0.95))
	var card := PanelContainer.new()
	card.name = str(game.get("slug", "game"))
	# A panel stops touches by default; the list has to get the swipes that start on a card
	card.mouse_filter = Control.MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(text_color, 0.08)
	style.border_color = Color(text_color, 0.16)
	style.set_border_width_all(2)
	style.set_corner_radius_all(16)
	style.set_content_margin_all(14)
	card.add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	card.add_child(box)

	var banner := TextureButton.new()
	banner.name = "Banner"
	banner.texture_normal = MoreGames.banner(game)
	banner.ignore_texture_size = true
	banner.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	banner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	banner.custom_minimum_size.y = 240
	# The height follows the width, so the banner always shows whole
	banner.resized.connect(func() -> void:
		var height := roundf(banner.size.x * BANNER_RATIO)
		if absf(banner.custom_minimum_size.y - height) > 1.0:
			banner.custom_minimum_size.y = height)
	_tap(banner, game)
	box.add_child(banner)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var names := VBoxContainer.new()
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.add_theme_constant_override("separation", 0)
	row.add_child(names)
	var title := Label.new()
	title.text = str(game.get("name", ""))
	title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED  # names and texts come translated
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if not _title_look.is_empty():
		MoreGames.apply_label_look(_title_look, title, 26)
	else:
		title.add_theme_font_size_override("font_size", 26)
	names.add_child(title)
	var tag := Label.new()
	tag.text = MoreGames.text_of(game, "tag")
	tag.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	_dress_body(tag, 18)
	tag.modulate.a = 0.75
	names.add_child(tag)
	var get_it := Button.new()
	get_it.name = "StoreButton"
	get_it.text = "INSTALL"
	get_it.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if not _button_look.is_empty():
		MoreGames.apply_button_look(_button_look, get_it, mini(_button_look.font_size, 20))
	get_it.custom_minimum_size = Vector2(0, 52)
	_tap(get_it, game)
	row.add_child(get_it)

	var about := Label.new()
	about.text = MoreGames.text_of(game, "description")
	about.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	about.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dress_body(about, 18)
	about.modulate.a = 0.85
	box.add_child(about)
	return card


func _dress_body(label: Label, font_size: int) -> void:
	if not _body_look.is_empty():
		MoreGames.apply_label_look(_body_look, label, font_size)
	else:
		label.add_theme_font_size_override("font_size", font_size)


# The cards let a drag through to the list (MOUSE_FILTER_PASS), and a press only counts as a tap if
# the finger stayed put
func _tap(button: BaseButton, game: Dictionary) -> void:
	button.mouse_filter = Control.MOUSE_FILTER_PASS
	button.pressed.connect(func() -> void:
		if _touch_travel > TAP_SLOP:
			return
		clicked.emit()
		store_opener.call(game))


# Fits the page into the screen: at most MAX_WIDTH wide, clear of notches and rounded corners
func _update_frame() -> void:
	if not is_inside_tree():
		return
	var view := get_viewport_rect().size
	var insets := _safe_insets()
	var side := maxf(MARGIN, (view.x - MAX_WIDTH) / 2.0)
	_frame.add_theme_constant_override("margin_left", int(maxf(side, insets.x + MARGIN)))
	_frame.add_theme_constant_override("margin_right", int(maxf(side, insets.z + MARGIN)))
	_frame.add_theme_constant_override("margin_top", int(insets.y + MARGIN))
	_frame.add_theme_constant_override("margin_bottom", int(insets.w + MARGIN))


func _safe_insets() -> Vector4:
	if not OS.has_feature("mobile"):
		return Vector4.ZERO
	var insets := Vector4(0.0, MOBILE_MIN_INSET_TOP, 0.0, MOBILE_MIN_INSET_BOTTOM)
	var window_size := Vector2(DisplayServer.window_get_size())
	var safe := Rect2(DisplayServer.get_display_safe_area())
	if window_size.x <= 0.0 or window_size.y <= 0.0 or safe.size.x <= 0.0 or safe.size.y <= 0.0:
		return insets
	# The safe area is in physical window pixels; the UI works in stretched viewport pixels
	var to_view := get_viewport_rect().size / window_size
	insets.x = maxf(safe.position.x, 0.0) * to_view.x
	insets.y = maxf(maxf(safe.position.y, 0.0) * to_view.y, MOBILE_MIN_INSET_TOP)
	insets.z = maxf(window_size.x - safe.end.x, 0.0) * to_view.x
	insets.w = maxf(maxf(window_size.y - safe.end.y, 0.0) * to_view.y, MOBILE_MIN_INSET_BOTTOM)
	return insets
