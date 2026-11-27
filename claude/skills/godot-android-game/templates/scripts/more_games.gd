extends RefCounted
## "Share with friends" and "More games" - the same in every rellit game.
##
## Template: skill godot-android-game (templates/scripts/more_games.gd); keep the copies equal.
## The data comes from more_games_catalog.gd, which tools/more_games.py writes from the rellit.de
## app registry at every build: this game's own entry for the share text, and every other
## published game with its Play feature graphic as banner. The page itself is
## more_games_overlay.gd.

const Catalog := preload("res://scripts/more_games_catalog.gd")
const STORE_URL := "https://play.google.com/store/apps/details?id=%s"
const URI_INTENT_SCHEME := 1  # android.content.Intent.URI_INTENT_SCHEME
const TOAST_SECONDS := 2.2


static func language() -> String:
	return "de" if TranslationServer.get_locale().begins_with("de") else "en"


## The other published games, newest first
static func games() -> Array:
	return Catalog.GAMES


static func own_game() -> Dictionary:
	return Catalog.SELF


## A field that comes in German and English (tag, description, banner) in the current language
static func text_of(game: Dictionary, key: String) -> String:
	var texts: Variant = game.get(key, {})
	if texts is Dictionary:
		return str(texts.get(language(), texts.get("en", "")))
	return str(texts)


static func banner(game: Dictionary) -> Texture2D:
	var path := text_of(game, "banner")
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


## The game's page on Google Play. With `medium`, the link carries a referrer, so the Play
## Console's acquisition report shows which game sent the player.
static func store_url(package: String, medium := "") -> String:
	var url := STORE_URL % package
	if medium != "":
		var referrer := "utm_source=%s&utm_medium=%s" % [str(own_game().get("slug", "")), medium]
		url += "&referrer=" + referrer.uri_encode()
	return url


## The Play Store app straight away (market://); where there is none - the desktop, phones without
## Google Play - the store's web page
static func open_store(game: Dictionary) -> void:
	var web := store_url(str(game.get("package", "")), "more_games")
	if OS.has_feature("android") and OS.shell_open(web.replace("https://play.google.com/store/apps/", "market://")) == OK:
		return
	OS.shell_open(web)


## What a friend gets: one line in the player's voice, the one-sentence pitch, the Play link
static func share_text() -> String:
	var game := own_game()
	var lines := PackedStringArray()
	lines.append(TranslationServer.translate("I'm playing %s right now – give it a try!") % str(game.get("name", "")))
	var pitch := text_of(game, "description")
	if pitch != "":
		lines.append(pitch)
	lines.append("")
	lines.append(store_url(str(game.get("package", ""))))
	return "\n".join(lines)


## Opens Android's share sheet with share_text(). Anywhere else - or if Android refuses - the text
## goes to the clipboard instead and this returns false, so the caller can say so (toast()).
static func share() -> bool:
	var text := share_text()
	var name := str(own_game().get("name", ""))
	var title := TranslationServer.translate("Share %s") % name
	if _android_share(text, name, title):
		return true
	DisplayServer.clipboard_set(text)
	return false


# ACTION_SEND through the share sheet, called like Godot's own OS.shell_open() does it (no UI
# thread needed for startActivity). The intent comes from Intent.parseUri(): JavaClassWrapper calls
# static methods reliably, and that way no Java constructor is needed.
static func _android_share(text: String, subject: String, title: String) -> bool:
	if not OS.has_feature("android") or not Engine.has_singleton("AndroidRuntime"):
		return false
	var runtime: Object = Engine.get_singleton("AndroidRuntime")
	var activity: Object = runtime.getActivity()
	var intents: Object = JavaClassWrapper.wrap("android.content.Intent")
	if activity == null or intents == null or _java_failed():
		return false
	# EXTRA_TITLE is the preview title of the share sheet (Android 10+ ignores the chooser's own)
	var uri := "intent:#Intent;action=android.intent.action.SEND;type=text/plain;S.android.intent.extra.TEXT=%s;S.android.intent.extra.SUBJECT=%s;S.android.intent.extra.TITLE=%s;end" % [
		text.uri_encode(), subject.uri_encode(), subject.uri_encode()]
	var send: Object = intents.parseUri(uri, URI_INTENT_SCHEME)
	if send == null or _java_failed():
		return false
	var chooser: Object = intents.createChooser(send, title)
	if chooser == null or _java_failed():
		return false
	activity.startActivity(chooser)
	return not _java_failed()


static func _java_failed() -> bool:
	var exception: Variant = JavaClassWrapper.get_exception()
	if exception != null:
		push_warning("MoreGames: %s" % str(exception))
		return true
	return false


## A short note at the bottom of `host` that fades out by itself ("Link copied")
static func toast(host: Control, text: String) -> void:
	var old := host.get_node_or_null("MoreGamesToast")
	if old != null:
		old.free()
	var note := PanelContainer.new()
	note.name = "MoreGamesToast"
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	note.z_index = 100
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.1, 0.92)
	style.set_corner_radius_all(22)
	style.set_content_margin_all(18)
	style.content_margin_left = 28
	style.content_margin_right = 28
	note.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_font_size_override("font_size", 22)
	note.add_child(label)
	host.add_child(note)
	note.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE)
	note.grow_horizontal = Control.GROW_DIRECTION_BOTH
	note.grow_vertical = Control.GROW_DIRECTION_BEGIN
	note.position.y -= host.get_viewport_rect().size.y * 0.12
	var fade := note.create_tween()
	fade.tween_interval(TOAST_SECONDS)
	fade.tween_property(note, "modulate:a", 0.0, 0.4)
	fade.tween_callback(note.queue_free)


## A button for the host's settings dialog that looks like `template`, one of that dialog's own
## buttons (styles, colours, font, height); only the text is new. Scripts and signals of the
## template are not taken over.
static func make_button(template: Button, text: String) -> Button:
	var button := Button.new()
	button.text = text
	copy_button_look(template, button)
	button.size_flags_horizontal = template.size_flags_horizontal
	button.custom_minimum_size = template.custom_minimum_size
	button.focus_mode = template.focus_mode
	return button


const _BUTTON_STYLES := ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed",
	"normal_mirrored", "hover_mirrored", "pressed_mirrored", "disabled_mirrored", "hover_pressed_mirrored"]
const _BUTTON_COLORS := ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color",
	"font_hover_pressed_color", "font_disabled_color", "font_outline_color", "icon_normal_color"]


static func copy_button_look(from: Button, to: Button) -> void:
	apply_button_look(button_look(from), to)


## Everything that makes a button look the way it does, as data (taken while `from` is in its
## dialog, so its theme counts): styles, colours, font, size, outline
static func button_look(from: Button) -> Dictionary:
	var look := {"styles": {}, "colors": {}, "font": from.get_theme_font("font"),
		"font_size": from.get_theme_font_size("font_size"), "outline_size": from.get_theme_constant("outline_size"),
		"alignment": from.alignment, "flat": from.flat}
	for style: String in _BUTTON_STYLES:
		if from.has_theme_stylebox(style):
			look.styles[style] = from.get_theme_stylebox(style)
	for color: String in _BUTTON_COLORS:
		if from.has_theme_color(color):
			look.colors[color] = from.get_theme_color(color)
	return look


static func apply_button_look(look: Dictionary, to: Button, font_size := 0) -> void:
	for style: String in look.styles:
		to.add_theme_stylebox_override(style, look.styles[style])
	for color: String in look.colors:
		to.add_theme_color_override(color, look.colors[color])
	to.add_theme_font_override("font", look.font)
	to.add_theme_font_size_override("font_size", font_size if font_size > 0 else look.font_size)
	to.add_theme_constant_override("outline_size", look.outline_size)
	to.alignment = look.alignment
	to.flat = look.flat


static func copy_label_look(from: Label, to: Label, font_size := 0) -> void:
	apply_label_look(label_look(from), to, font_size)


## The same for a label: its LabelSettings if it has them, else font, size, colours, outline, shadow
static func label_look(from: Label) -> Dictionary:
	if from.label_settings != null:
		return {"settings": from.label_settings, "font_color": from.label_settings.font_color}
	var look := {"font": from.get_theme_font("font"), "font_size": from.get_theme_font_size("font_size"),
		"colors": {}, "constants": {}}
	for color: String in ["font_color", "font_outline_color", "font_shadow_color"]:
		look.colors[color] = from.get_theme_color(color)
	for constant: String in ["outline_size", "shadow_offset_x", "shadow_offset_y", "shadow_outline_size"]:
		look.constants[constant] = from.get_theme_constant(constant)
	look.font_color = look.colors.font_color
	return look


static func apply_label_look(look: Dictionary, to: Label, font_size := 0) -> void:
	if look.has("settings"):
		to.label_settings = look.settings.duplicate()
		if font_size > 0:
			to.label_settings.font_size = font_size
		return
	to.add_theme_font_override("font", look.font)
	to.add_theme_font_size_override("font_size", font_size if font_size > 0 else look.font_size)
	for color: String in look.colors:
		to.add_theme_color_override(color, look.colors[color])
	for constant: String in look.constants:
		to.add_theme_constant_override(constant, look.constants[constant])
