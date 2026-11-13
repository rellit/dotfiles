---
name: godot-android-game
description: Tims Standard für Godot-4-Spiele auf Android (Hexmosis, Orbitrio). Laden, sobald ein neues Godot-Spiel angelegt wird oder an einem bestehenden gearbeitet wird – Features, Release/Versionssprung, Android-Build (APK/AAB), Keystore/Signierung, Changelog, Credits/About, Lizenzen, Splash, App-Icon, Audio/Musik, How to play, Spielstand fortsetzen (Resume), Übersetzung, Safe Area, Store-Screenshots und Play-Store-Eintrag.
---

# Godot-Android-Spiele: Entwicklungs-Guide

Abgeleitet aus **Hexmosis** (`~/Entwicklung/hexxagon`) und **Orbitrio** (`~/Entwicklung/numberJoin`).
Gilt zusätzlich zum eigentlichen Auftrag. Bei Unklarheit gilt: so machen, wie es Orbitrio macht
(das jüngere Projekt, alle Punkte umgesetzt). Code-Bausteine stehen in [snippets.md](snippets.md),
Dateivorlagen in `templates/`.

Projektname-Schema, überall gleich verwenden:

| Platzhalter | Bedeutung | Beispiel |
|---|---|---|
| `__NAME__` | Anzeigename | `Orbitrio` |
| `__SLUG__` | klein, Dateinamen/Alias/Subdomain | `orbitrio` |
| `__ENV__` | Präfix der Umgebungsvariablen | `ORBITRIO` |
| Package | `de.timhaller.__SLUG__` | `de.timhaller.orbitrio` |
| Website | `https://__SLUG__.rellit.de` | |

## 1. Neues Projekt anlegen

```bash
S=~/.claude/skills/godot-android-game/templates
cp -r $S/tools $S/run_desktop.sh $S/keystore.properties.example $S/export_presets.cfg .
cp $S/gitignore .gitignore
find tools run_desktop.sh keystore.properties.example export_presets.cfg -type f -exec sed -i \
  -e 's/__NAME__/Orbitrio/g' -e 's/__SLUG__/orbitrio/g' -e 's/__ENV__/ORBITRIO/g' {} +
```
`templates/project.godot.part` enthält die `[application]`…`[rendering]`-Abschnitte für `project.godot`.
Danach im Projekt eine `CLAUDE.md` anlegen (Vorlage: Abschnitt 16).

Struktur:
```
project.godot  export_presets.cfg  run_desktop.sh  README.md  CLAUDE.md
keystore.properties.example        # committed; keystore.properties ist git-ignored
scenes/game.tscn                   # eine Szene: Menü, Spiel, alle Overlays
scripts/<regeln>_state.gd          # Spielregeln ohne UI, to_dict()/from_dict()
scripts/<x>_view.gd                # Zeichnen, Eingabe, Animation
scripts/game_controller.gd         # Menü, Dialoge, Speichern, Back, Safe Area
scripts/sound_manager.gd           # Musik, Effekte, Lautstärken
scripts/help_*.gd                  # Bildchen für How to play
locale/de.po
assets/{icon,splash,fonts,audio/music,audio/sfx}/
tools/generate_icon.py  generate_sounds.py  generate_store_assets.py  capture_screenshots.gd
tools/android/build_android.sh  create_keystore.sh
tests/test_*.gd                    # headless, extends SceneTree
build/                             # Ausgabe, git-ignored
```

## 2. Projekt-Grundeinstellungen

- Godot 4.7, Renderer **GL Compatibility** (auch mobil), Hochformat 720×1280,
  `stretch/mode="canvas_items"`, `aspect="expand"`, `handheld/orientation=1`.
- `pointing/emulate_touch_from_mouse=true`; Spielfeld-Eingabe nur über `InputEventScreenTouch`
  auswerten (sonst kommt jeder Tap doppelt an).
- `application/config/quit_on_go_back=false` – das Spiel behandelt die Android-Zurück-Taste selbst.
- `config/version` in `project.godot` ist die **einzige Quelle** für die sichtbare Version
  (`version/name=""` in den Export-Presets).
- Hintergrundfarbe des Spiels = `default_clear_color` = `boot_splash/bg_color`.
- Schrift: Orbitron (SIL OFL) als `gui/theme/custom_font`, Lizenz in `assets/fonts/OFL-*.txt`,
  per `include_filter` mit exportiert.
- Keine Android-Berechtigungen, auch kein INTERNET. Links öffnet der System-Browser (`LinkButton`).

## 3. Architektur

- **State** (`*_state.gd`): reine Regeln, Signale für Score/Zug/Game-Over, `to_dict()` / `from_dict()`
  (bzw. `load_dict()`), die `false` liefern, wenn die Daten nicht passen. Seed-bar für Tests und Screenshots.
- **View**: zeichnet und animiert; meldet Spieleraktionen per Signal; Animationsschritte als Signal,
  damit Sounds zum Schritt passen.
- **Controller**: alles drumherum. Hat `var persist := true` (bzw. leere `save_path`/`settings_path`):
  Tests und Screenshot-Tool setzen das vor `add_child`, dann wird nichts in `user://` gelesen/geschrieben.
- Kommentare erklären das *Warum*, Englisch, knapp, Stil wie im Bestandscode.

## 4. Spielstand fortsetzen (Resume) – Pflicht

- Laufendes Spiel nach **jedem Zug** (und beim Spielstart) speichern: `user://savegame.cfg`
  (ConfigFile) oder `.json` mit `"version"`-Feld. Inhalt: kompletter State inkl. Zufallsgenerator-Zustand,
  Modus, Stufe, Spielerwahl – so, dass es exakt weitergeht.
- Zusätzlich in `_notification` bei `NOTIFICATION_WM_CLOSE_REQUEST` und `NOTIFICATION_APPLICATION_PAUSED`
  speichern (Android killt Apps im Hintergrund) – aber nur, wenn wirklich ein Spiel läuft, sonst kommt
  ein verlassenes Spiel als CONTINUE zurück.
- Beim Start: Datei lesen; beschädigt/falsche Version → still löschen. Menü zeigt dann **CONTINUE**.
- Spiel vorbei oder verlassen → Datei löschen. Wurde die App während des letzten (spielbeendenden)
  Zugs geschlossen, das Spiel beim Laden als beendet verbuchen.
- „Neues Spiel“ / „Zum Menü“ während eines laufenden Spiels: Bestätigungsdialog (Hexmosis) oder
  das Spiel bleibt erhalten und CONTINUE erscheint (Orbitrio). Nie stillschweigend verwerfen.
- Gegen-KI wartet, solange ein Dialog offen ist (`_dialog_open()`).
- Tests: Speichern → neue Controller-Instanz → CONTINUE → gleicher Zustand; kaputte Datei wird ignoriert.

## 5. Einstellungen

Alles in **einer** Datei `user://settings.cfg`: Abschnitt `audio` (SoundManager: Musik-/Effekt-Lautstärke,
Track), Abschnitt `app` (`help_seen`, zuletzt gewählte Stufe …). Beim Schreiben erst `cfg.load()`,
dann den eigenen Wert setzen, damit andere Abschnitte erhalten bleiben.

## 6. Menü und Dialoge

Menü: **CONTINUE** (nur mit Spielstand) · **NEW GAME** · **HOW TO PLAY** · ggf. **HIGHSCORES** ·
**SOUND/SETTINGS** · **ABOUT**. Im Spiel eine Leiste mit MENU, `?` (How to play) und `♪`/Zahnrad (Sound).
Dialoge sind Overlays in `game.tscn`, gehen mit kurzem Pop-in auf, jeder Button spielt `UI_CLICK`.

## 7. How to play – Pflicht

- Scrollbare Seite mit kurzen Abschnitten: Ziel, Bedienung, jede Regel, Punkte, Spielende, Tipps.
- Zu jeder Regel kleine Bilder, **mit denselben Zeichenroutinen wie das Spiel** gerendert
  (`help_board.gd`, `help_strip.gd`), keine Screenshots.
- `help_sections()` liefert `[{title, text, strips/boards}]`; `_build_help()` baut die Seite **bei jedem
  Öffnen** neu (aktuelle Sprache). Zahlen aus den Regelkonstanten einsetzen, nicht hart codieren.
- Öffnet sich beim allerersten Start/Spiel von selbst (`help_seen` in `settings.cfg`), sonst über Menü und `?`.

## 8. About, Credits, Changelog, Lizenzen, Impressum, Datenschutz – Pflicht

About-Dialog: Name, `Version %s` aus `ProjectSettings.get_setting("application/config/version")`,
`© <Jahr> Tim Haller`, Link auf die Website, Link **Privacy policy**, Credits (Schrift, Godot),
Buttons **Changelog**, **Licenses** und **Legal notice**.

**Impressum und Datenschutz** (EU: höchstens 2 Klicks vom Startbildschirm, also Menü → About → …)
- **Legal notice** öffnet ein eigenes Overlay (`ImprintOverlay`), damit es offline lesbar ist:
  Titel „LEGAL NOTICE“ (de „IMPRESSUM“), Text aus `imprint_text_for_locale()` (siehe snippets.md:
  Angaben gemäß § 5 DDG, Tim Haller, Beethovenstraße 9, 64347 Griesheim, Deutschland, Kontakt),
  darunter `LinkButton` `support@rellit.de` (`mailto:`) und `rellit.de/impressum`
  (`https://rellit.de/impressum`, das volle Impressum). Bewusst schlank: kein OS-Link (Plattform seit
  20.07.2025 abgeschaltet), kein MStV-Absatz, kein VSBG-Hinweis (Pflicht erst ab 10 Beschäftigten).
- **Privacy policy**: `LinkButton` im About-Dialog, `uri = privacy_url()` beim Öffnen gesetzt:
  `__SLUG__.rellit.de/datenschutz-app` bei deutscher UI, sonst `/en/app-privacy`. Die Seiten liegen im rellit.de-Repo.
- Zurück/Esc schließt das Impressum vor dem About-Dialog; in `_dialog_open()` aufnehmen.
- Test: Link-URIs je Sprache, Impressum öffnet aus About mit Adresse, Zurück lässt About offen, deutscher Text.

**Changelog**
- `GameController.changelog_entries()` (static), neueste zuerst:
  `{"version": "1.0.2", "build": 3, "date": "2026-11-07", "changes": [tr("…"), …]}`.
  `build` = Android-`versionCode` dieses Releases.
- Darstellung als BBCode im `RichTextLabel`, bei jedem Öffnen neu gebaut; Datum ISO,
  im Deutschen `TT.MM.JJJJ`.
- Einträge sind für Spieler geschrieben (was ist neu/anders), nicht für Entwickler; jede Zeile in `de.po`.
- Test: erster Eintrag == `config/version`, alle Zeilen auf Deutsch übersetzt.

**Licenses**: `license_text()` (siehe snippets.md) – Godot-MIT-Lizenz, Drittkomponenten und Lizenztexte
direkt aus `Engine.get_license_text()/get_copyright_info()/get_license_info()`, dazu die Font-Lizenz.
Erst beim ersten Öffnen zusammenbauen (mehrere 100 KB). Rechtstexte bleiben englisch.

## 9. Audio – Pflicht

- `SoundManager` (Node, `PROCESS_MODE_ALWAYS`): 4 wählbare Musik-Loops (`MUSIC_TRACKS` mit Name +
  preload), Effekte als `enum Sfx` + `STREAMS` + `SFX_VOLUME_DB`, Pool von ~8 `AudioStreamPlayer`,
  leichte Tonhöhen-Variation, `play(sfx, pitch)`.
- Musik und Effekte **getrennt** regelbar (Slider 0–100, 0 = „Aus“), Track-Auswahl ◀ ▶;
  gespeichert in `settings.cfg` (Abschnitt `audio`) mit verzögertem Schreiben (Timer) und `flush_settings()`
  beim Schließen/Pausieren/Beenden. Nach Loslassen des Effekt-Sliders ein Probe-Sound.
- Musik leise im Hintergrund (`MUSIC_FULL_DB` ≈ -12 dB), Fade-in beim Start, Crossfade beim Trackwechsel.
- Alle Sounds **prozedural** erzeugt: `python3 tools/generate_sounds.py` (NumPy + ffmpeg/libvorbis) →
  `assets/audio/music/*.ogg` (nahtlose Loops, Ring-Puffer, gleiche Lautheit) und `sfx/*.wav`.
  Danach `godot --headless --import --path .`; Musik-`.import` braucht `loop=true`.
- Jede Spieleraktion und jedes Ereignis hat einen Sound, zeitlich auf den Animationsschritt gelegt;
  dazu Jingles für Sieg/Niederlage/Highscore/Spielende und `UI_CLICK` für alle Buttons.
- Test `test_audio.gd`: Assets geladen und Loops, Lautstärken, Speichern/Laden, Trackwechsel, Dialog.

## 10. App-Icon und Splash – Pflicht

`python3 tools/generate_icon.py` (Pillow + NumPy) zeichnet alles aus Signed-Distance-Funktionen
mit Anti-Aliasing in jeder Größe:
- `assets/icon/`: adaptive `icon_foreground_432.png` (Inhalt in der 66-dp-Safe-Zone, vom Skript geprüft),
  `icon_background_432.png`, `icon_monochrome_432.png` (Android 13 Themed Icon), `icon_192.png`,
  `icon_512.png` (Play Store), `icon.png` (256 px Fenster).
- `assets/splash/splash.png`: 1080×1920 transparent, Icon-Motiv + Titel, statt Godot-Logo;
  `boot_splash/image`, `boot_splash/bg_color` = Spielhintergrund, `stretch_mode=1` (Keep).
- Das Icon zeigt das Spiel in einem Bild. Store-Grafiken nutzen denselben Hintergrund.

## 11. Sprache

- UI-Texte englisch = msgid; `locale/de.po` mit allen deutschen Texten, `locale/fallback="en"`.
  Jeder neue `tr()`-Text und jeder Szenentext braucht einen Eintrag.
- Dynamische Seiten (Help, Changelog, Highscores) bei jedem Öffnen neu bauen. Datumsformat nach Sprache.
- Tests, die Texte vergleichen, setzen vorher `TranslationServer.set_locale("en")`; ein Test prüft `de_DE`
  → Deutsch und `fr_FR` → Englisch.

## 12. Mobile-Feinheiten

- **Safe Area**: alle Vollbild-Layouts um `DisplayServer.get_display_safe_area()` einrücken, umgerechnet in
  Viewport-Pixel, mindestens 24 px oben / 16 px unten auf Mobilgeräten; bei `size_changed` neu anwenden.
- **Android-Zurück** (`NOTIFICATION_WM_GO_BACK_REQUEST`): oberstes Overlay schließen → vom Spiel ins Menü
  (mit Bestätigungsmodell: dieselbe Frage wie der MENU-Button) → im Menü beenden. Desktop: `ui_cancel` (Esc)
  schließt Dialoge. Beides über eine gemeinsame `_close_top_dialog() -> bool`. Test über `go_back()`.
- Ein Zug, der während einer Animation getippt wird, wird nach deren Ende ausgeführt statt verworfen.
- `screen/immersive_mode=true`, Architekturen arm64-v8a + x86_64.

## 13. Tests, Screenshots, Store

- Tests: `tests/test_*.gd`, `extends SceneTree`, headless (`godot --headless -s tests/x.gd`), Exit-Code ≠ 0
  bei Fehler. Regeln, Speichern/Laden, Menüfluss durch die echte Szene (`Engine.time_scale` hoch),
  About/Changelog/Licenses, Back-Taste, Audio. `build_android.sh` führt alle aus.
- `tools/capture_screenshots.gd`: echte Szene in SubViewport, fester Seed, Sound stumm, `persist=false`.
  Standard 1080×2340 (Website, `apps/__SLUG__/public/screens/` im rellit.de-Repo, als WebP);
  `-- <dir> <de|en> store` → 1080×1920 (Play nimmt nichts länger als 2:1). Braucht Display.
- `python3 tools/generate_store_assets.py [--skip-capture]` → `build/store/`: `icon_512.png`, je Sprache
  `feature_graphic.png` (1024×500, ohne Alpha) und beschriftete `phone_NN_*.png`; Texte in `SHOTS`.
- **`build/.gdignore` ist Pflicht** (legen `build_android.sh` und `generate_store_assets.py` an): sonst
  importiert Godot die Screenshots/Store-PNGs als Ressourcen und packt sie ins APK/AAB. Prüfen:
  `unzip -l build/*.apk | grep -E "build/|\.ctex"` darf nichts liefern.
- `build/store/listing.md`: Play-Eintrag de/en (Titel ≤30, Kurzbeschreibung ≤80, Beschreibung),
  Datenschutz `https://__SLUG__.rellit.de/datenschutz-app` (EN `/en/app-privacy`), Kontakt mail@timhaller.de,
  „komplett offline, keine Berechtigungen“.

## 14. Android-Build und Signierung – Pflicht

Vorlagen: `templates/tools/android/{build_android.sh,create_keystore.sh}`, `templates/keystore.properties.example`,
`templates/export_presets.cfg`, `templates/gitignore`.

- **Zwei Export-Presets**: `Android` (APK, `gradle_build/use_gradle_build=false`) und `Android AAB`
  (`use_gradle_build=true`, `export_format=1`). Beide mit gleichem `version/code`, `version/name=""`,
  `package/unique_name="de.timhaller.__SLUG__"`, `package/signed=true`, adaptiven Icons,
  `exclude_filter="build/*, tests/*, tools/*, extension_api.json, keystore.properties, keystore.properties.example"`.
- **Keystore einmalig**: `tools/android/create_keystore.sh` → `~/.android-keystores/__SLUG__-release.keystore`
  (PKCS12, RSA 4096, 10000 Tage, ein Passwort) und `keystore.properties` (mode 600, git-ignored) mit
  `storeFile`, `storePassword`, `keyAlias`. Überschreibt nie einen vorhandenen Keystore.
  Nutzer daran erinnern: Keystore + Passwort sichern.
- **Build**: `tools/android/build_android.sh [release|debug] [--aab] [--bump] [--version-code N]
  [--version-name X] [--skip-tests] [--install]`. Ablauf: Tests → `--import` → Export nach
  `build/__SLUG__-<version>-<code>-<mode>.<apk|aab>` → Signatur prüfen und mit Release-Key vergleichen
  (sonst Datei löschen und Fehler). Für AAB installiert das Skript bei Bedarf das Android-Build-Template
  nach `android/` (git-ignored, Version in `android/.build_version`).
- Signierwerte: `keystore.properties` > Umgebungsvariablen `__ENV___KEYSTORE`, `__ENV___KEYSTORE_PASSWORD`,
  `__ENV___KEY_ALIAS` > Passwortabfrage. Übergabe an Godot über `GODOT_ANDROID_KEYSTORE_RELEASE_*`.
- Voraussetzungen: Godot 4.7 Export-Templates, Android SDK (`~/Android/Sdk` oder `ANDROID_HOME`), JDK 17.
- Play Console: Play App Signing, dieser Key ist der Upload-Key. Neue Apps nur als AAB.
- Passwörter nie ausgeben, nie committen, nie in Logs schreiben.

## 15. Release-Checkliste (bei jedem Versionssprung)

1. `config/version` in `project.godot` erhöhen (SemVer).
2. Neuen Eintrag oben in `changelog_entries()`: Version, `build` = bisheriger `version/code` + 1, heutiges Datum.
3. Alle neuen Texte in `locale/de.po`.
4. README aktualisieren (Features, Steuerung, Dateien).
5. Tests grün; `tools/android/build_android.sh release --aab --bump` (erhöht `version/code` in beiden Presets).
6. Bei sichtbaren Änderungen: Screenshots / Store-Assets neu erzeugen.
7. Commit `Version X.Y.Z: <Kurzfassung>` (nur wenn der Nutzer committen lässt).

## 16. Projekt-CLAUDE.md (Vorlage)

```markdown
# __NAME__

Godot-4-Android-Spiel. Folgt dem Guide im Skill `godot-android-game` (~/.claude/skills/godot-android-game).

- Package `de.timhaller.__SLUG__`, Env-Präfix `__ENV__`, Website https://__SLUG__.rellit.de
- Version: `config/version` in project.godot; Changelog: `GameController.changelog_entries()`
- Spielstand: `user://savegame.cfg`, Einstellungen: `user://settings.cfg`
- Tests: `for t in tests/test_*.gd; do godot --headless -s $t; done`
- Release: Checkliste im Skill, dann `tools/android/build_android.sh release --aab --bump`
- Abweichungen vom Guide: …
```
