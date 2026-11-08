---
name: dotfiles-sync
description: Sichert Tims globale Claude-Konfiguration in ~/dotfiles (GitHub rellit/dotfiles). Laden und befolgen, sobald ein Skill unter ~/.claude/skills angelegt, erweitert, umbenannt oder gelöscht wurde oder die globale ~/.claude/CLAUDE.md geändert wurde – auch wenn das nur nebenbei im Rahmen einer anderen Aufgabe passiert ist.
---

# Claude-Konfiguration in die dotfiles syncen

`~/.claude/skills` und `~/.claude/CLAUDE.md` sind Symlinks nach `~/dotfiles/claude/`. Jede Änderung
dort muss committet und gepusht werden, damit sie auf einem neuen Rechner wieder da ist.

## Wann

Nach jeder Änderung unter `~/dotfiles/claude/` (bzw. `~/.claude/skills/…`, `~/.claude/CLAUDE.md`),
sobald der Arbeitsschritt abgeschlossen ist – nicht nach jedem einzelnen Edit, sondern einmal pro
zusammenhängender Änderung, spätestens vor dem Wrap-up des Turns.

Nicht syncen: Memories (`~/.claude/projects/…`), Settings, Sessions – die liegen nicht in den dotfiles.

## Wie

```bash
~/dotfiles/claude/sync "<kurze Beschreibung, was sich geändert hat>"
```

Die Message auf Englisch oder Deutsch, im Stil „godot-android-game: add store screenshot section“;
das Skript stellt `claude: ` voran.

Das Skript entscheidet selbst:
- `main` sauber (ausgecheckt, keine Änderungen außerhalb `claude/`, nicht hinter `origin`, keine
  fremden ungepushten Commits) → Commit auf `main` und Push.
- Sonst → Commit nur von `claude/` auf den Branch `claude-sync` und Push, ohne Arbeitsverzeichnis
  oder Index anzufassen. Die Ausgabe nennt den Grund.

Nie selbst `git add`/`commit`/`push` im dotfiles-Repo machen, nie Tims andere Änderungen dort
committen, nicht `claude-sync` nach `main` mergen – das macht Tim.

## Danach

Dem Nutzer in der Abschlussnachricht in einem Satz sagen, was gesynct wurde und wohin (main oder
`claude-sync` mit Grund). Schlägt der Push fehl (offline, SSH), das klar melden; ein späterer
Aufruf von `sync` pusht ausstehende Commits nach.
