extends SceneTree

# "Share with friends" and "More games" (scripts/more_games.gd, more_games_overlay.gd): the list
# tools/more_games.py generated from rellit.de, the share text, and the way through the real scene:
# options -> MORE GAMES -> cards -> back to the options.
#
# Template: skill godot-android-game (templates/tests/test_more_games.gd). Per game only the three
# functions under "host" differ: how the scene starts without touching user://, how the options
# open, and which node is the options dialog.

const MoreGames := preload("res://scripts/more_games.gd")
const Catalog := preload("res://scripts/more_games_catalog.gd")
const STRINGS := ["SHARE WITH FRIENDS", "MORE GAMES", "INSTALL", "I'm playing %s right now – give it a try!",
	"Share %s", "Copied to the clipboard"]

var failed := false
var scene_done := false


func _init() -> void:
	print("--- Running More Games Tests ---")
	# Nodes added to the root before the first frame get no _ready
	await process_frame
	TranslationServer.set_locale("en")
	_test_catalog()
	_test_share_text()
	await _test_scene()
	# A script error only ends the function it happens in, so make sure the walk got to its end
	check(scene_done, "The walk through the scene ran to its end")
	quit(1 if failed else 0)


# ---- host

func _start_game() -> Node:
	var game: Node = load("res://scenes/game.tscn").instantiate()
	game.persist = false
	game.help_seen = true
	root.add_child(game)
	for i in 3:
		await process_frame
	return game


func _open_settings(game: Node) -> void:
	game.open_settings()
	await process_frame


func _settings_dialog(game: Node) -> Control:
	return game.settings_overlay


# ---- tests

func _own_package() -> String:
	var presets := ConfigFile.new()
	presets.load("res://export_presets.cfg")
	return str(presets.get_value("preset.0.options", "package/unique_name", ""))


func _test_catalog() -> void:
	var own: Dictionary = Catalog.SELF
	check(own.get("package") == _own_package(), "SELF is this game (%s)" % _own_package())
	check(own.get("name", "") != "" and own.get("description", {}).get("en", "") != "", "with a name and a pitch")
	var games := MoreGames.games()
	check(not games.is_empty(), "The list has other games (%d)" % games.size())
	var packages := {}
	for game: Dictionary in games:
		var name := str(game.get("name"))
		check(game.get("package") != own.get("package"), "%s is not this game" % name)
		check(str(game.get("package")).begins_with("de.timhaller."), "%s has a package name" % name)
		packages[game.get("package")] = true
		for lang in ["de", "en"]:
			var banner: Variant = load(game.banner[lang]) if ResourceLoader.exists(game.banner[lang]) else null
			check(banner is Texture2D and banner.get_width() == 768, "%s has a %s banner" % [name, lang])
			check(str(game.tag.get(lang, "")) != "" and str(game.description.get(lang, "")) != "", "%s has %s texts" % [name, lang])
	check(packages.size() == games.size(), "No game twice")


func _test_share_text() -> void:
	var own: Dictionary = Catalog.SELF
	var link := "https://play.google.com/store/apps/details?id=" + _own_package()
	var text := MoreGames.share_text()
	check(text.begins_with("I'm playing %s right now – give it a try!" % own.name), "The share text speaks for the player")
	check(text.contains(own.description.en), "It says what the game is")
	check(text.ends_with("\n" + link), "and ends with the plain Play link")
	TranslationServer.set_locale("de_DE")
	text = MoreGames.share_text()
	check(text.begins_with("Ich spiele gerade %s – probier es auch mal aus!" % own.name), "German share text")
	check(text.contains(own.description.de) and text.ends_with(link), "with the German pitch and the same link")
	for msgid: String in STRINGS:
		check(TranslationServer.translate(msgid) != msgid, "German: %s" % msgid)
	TranslationServer.set_locale("fr_FR")
	check(MoreGames.share_text().contains(own.description.en), "Other languages get English")
	TranslationServer.set_locale("en")
	check(MoreGames.store_url("de.timhaller.x", "more_games") == "https://play.google.com/store/apps/details?id=de.timhaller.x&referrer=utm_source%%3D%s%%26utm_medium%%3Dmore_games" % own.slug,
		"Links from More games say where the player came from")
	check(not MoreGames.share(), "No share sheet on the desktop: the text goes to the clipboard")


func _test_scene() -> void:
	var game := await _start_game()
	await _open_settings(game)
	var settings := _settings_dialog(game)
	check(settings.visible, "The options are open")
	check(game.share_button.is_visible_in_tree() and game.share_button.text == "SHARE WITH FRIENDS", "SHARE WITH FRIENDS in the options")
	check(game.more_games_button.is_visible_in_tree() and game.more_games_button.text == "MORE GAMES", "MORE GAMES in the options")
	check(settings.is_ancestor_of(game.share_button) and settings.is_ancestor_of(game.more_games_button), "both inside the options dialog")

	game.share_button.pressed.emit()
	await process_frame
	check(root.find_child("MoreGamesToast", true, false) != null, "Sharing on the desktop says the text was copied")

	var page: Control = game.more_games_overlay
	var opened: Array[Dictionary] = []
	page.store_opener = func(entry: Dictionary) -> void: opened.append(entry)
	game.more_games_button.pressed.emit()
	await process_frame
	await process_frame
	check(page.visible and settings.visible, "MORE GAMES opens the page over the options")
	check(_drawn_over(page, settings), "The page is drawn on top of the options")
	check(page.card_count() == MoreGames.games().size(), "One card per game (%d)" % page.card_count())
	var buttons: Array[Button] = page.store_buttons()
	check(buttons.size() == page.card_count() and buttons[0].text == "INSTALL", "Each card has an INSTALL button")
	var banner: TextureButton = page.find_child("Banner", true, false)
	check(banner != null and banner.texture_normal != null and banner.size.y > 100.0, "The banners show")
	check(absf(banner.size.y - banner.size.x * 375.0 / 768.0) < 2.0, "whole, in their own proportions")
	var passes := true
	var node: Node = banner
	while node != null and not node is ScrollContainer:
		if node is Control and node.mouse_filter == Control.MOUSE_FILTER_STOP:
			passes = false
		node = node.get_parent()
	check(passes and node is ScrollContainer, "A swipe that starts on a card reaches the list")

	buttons[0].pressed.emit()
	check(opened.size() == 1 and opened[0].package == MoreGames.games()[0].package, "A tap opens that game's store page")
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	touch.position = Vector2(300, 600)
	page._input(touch)
	var drag := InputEventScreenDrag.new()
	drag.position = Vector2(300, 400)
	page._input(drag)
	buttons[0].pressed.emit()
	check(opened.size() == 1, "A swipe through the list opens nothing")
	page._input(touch)

	game.go_back()
	await process_frame
	check(not page.visible and settings.visible, "Back closes the page and leaves the options open")
	await process_frame
	check(page.card_count() == 0, "and lets the banners go")
	game.go_back()
	await process_frame
	check(not settings.visible, "Back again closes the options")
	scene_done = true
	game.queue_free()
	await process_frame


# Drawn later = higher z_index (summed up the tree), or the same and later in the tree
func _drawn_over(top: CanvasItem, below: CanvasItem) -> bool:
	var z_top := _z(top)
	var z_below := _z(below)
	return z_top > z_below or (z_top == z_below and top.is_greater_than(below))


func _z(item: CanvasItem) -> int:
	var z := 0
	var node: Node = item
	while node is CanvasItem:
		z += node.z_index
		if not node.z_as_relative:
			break
		node = node.get_parent()
	return z


func check(condition: bool, label: String) -> void:
	if condition:
		print("  [OK] " + label)
	else:
		failed = true
		push_error("Assertion FAILED: " + label)
