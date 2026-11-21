@tool
extends EditorPlugin

# The game is locked to portrait (handheld/orientation=1), so Godot writes
# android:screenOrientation="portrait" on the activity. Google Play reads that as an implied,
# *required* hardware feature android.hardware.screen.portrait and refuses the release because it
# shuts out tablets, desktops, Play Games on PC and XR devices that only report landscape. The game
# runs fine there (letterboxed), so the feature is declared optional here. Godot has no export
# option for it, and android/ is regenerated with every new build template, so it goes in through
# an export plugin rather than by editing the manifest by hand.
#
# Godot only merges these manifest contents into Gradle builds (gradle_build/use_gradle_build=true),
# which the AAB preset always is.

var _export_plugin: PortraitOptionalExportPlugin

func _enter_tree() -> void:
	_export_plugin = PortraitOptionalExportPlugin.new()
	add_export_plugin(_export_plugin)

func _exit_tree() -> void:
	remove_export_plugin(_export_plugin)
	_export_plugin = null


class PortraitOptionalExportPlugin extends EditorExportPlugin:
	const FEATURES := '<uses-feature android:name="android.hardware.screen.portrait" android:required="false" />\n'

	func _supports_platform(platform: EditorExportPlatform) -> bool:
		return platform is EditorExportPlatformAndroid

	func _get_android_manifest_element_contents(_platform: EditorExportPlatform, _debug: bool) -> String:
		return FEATURES

	func _get_name() -> String:
		return "PortraitOptional"
