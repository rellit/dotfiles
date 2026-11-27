---
name: "tool-researcher"
description: "Recherchiert ein neues, nützliches Web-Tool für rellit.de, das dort noch nicht existiert, und implementiert es als eigene Subdomain-App nach dem etablierten Projektmuster. Nutzen, wenn der Nutzer sagt \"neues Tool\", \"recherchiere ein Tool\", \"nächstes Tool bauen\" o.ä. im Kontext des rellit.de-Projekts."
---


# Tool-Researcher – neues Tool für rellit.de finden & bauen

Du bist Betreiber der statischen Tool-Sammlung **rellit.de**. Dieser Skill hat zwei Phasen: zuerst
recherchieren, was als nächstes gebaut werden sollte, dann es tatsächlich implementieren – nach exakt
demselben Muster wie die bereits vorhandenen Tools.

Setze diesen Skill nur im rellit.de-Projektordner ein (Monorepo mit `apps/`, `packages/theme`,
`packages/legal`). Prüfe zuerst die vorhandene Struktur, bevor du irgendetwas annimmst – die folgenden
Pfade können sich seit Erstellung dieses Skills weiterentwickelt haben.

## Phase 1: Recherche

1. Lies `apps/www/src/data/tools.ts` (Registry aller live geschalteten Tools) und liste alle Ordner unter
   `apps/` auf, um zu wissen, was bereits existiert. Baue niemals ein Tool, das inhaltlich einem
   vorhandenen entspricht.
2. Recherchiere (Websuche) nach nützlichen, rein client-seitig umsetzbaren Web-Tools – Kandidaten sind z.B.
   Konverter, Formatter/Validatoren (JSON/CSS/SQL), Generatoren (UUID, Passwort, Lorem Ipsum, QR-Code),
   Rechner (Cron-Parser, Base64/URL/Hash-Encoder, Regex-Tester, Diff-Viewer, Farbkonverter,
   Zeitzonen-Rechner, Markdown-Preview). Bevorzuge Tools, die:
   - komplett im Browser laufen (kein Backend nötig, keine Server-Kosten, keine Cookies/Tracking nötig),
   - einen klaren, suchbaren Anwendungsfall haben (gutes SEO-Potenzial, klare Keywords),
   - sich gut mit einer kleinen, stabilen npm-Bibliothek umsetzen lassen.
3. Wähle EIN Tool aus und begründe kurz die Wahl (Nutzen, Zielgruppe, SEO-Keywords, benötigte Bibliothek).
   Bei Unsicherheit zwischen mehreren guten Kandidaten: frage den Nutzer kurz, welches er bevorzugt,
   anstatt beliebig zu entscheiden.

## Phase 2: Implementierung

Baue eine neue App unter `apps/<slug>/`, die 1:1 dem Muster der bestehenden Tools folgt (schau dir
`apps/converter/` und `apps/hasher/` als Referenz an, bevor du startest):

1. **App-Grundgerüst**
   - `apps/<slug>/package.json`: Name `@rellit/<slug>`, Scripts `dev`/`build`/`preview` (astro), Dependencies
     `astro`, `@astrojs/sitemap`, `@rellit/theme`, `@rellit/legal` (alle als Workspace-Referenz `"*"` bzw.
     passende Version) plus die für das Tool benötigte(n) Fachbibliothek(en). Verwende dieselbe
     Astro-Hauptversion, die bereits in den anderen `apps/*/package.json` steht (aktuell `^5.0.0`) – niemals
     eine ältere Major-Version einführen, das bricht `@astrojs/sitemap` (siehe Leitplanken unten).
   - `apps/<slug>/astro.config.mjs`: `site: "https://<slug>.rellit.de"`, `output: "static"`,
     `integrations: [sitemap()]`.
   - `apps/<slug>/tsconfig.json`: extends `astro/tsconfigs/strict`.
   - `apps/<slug>/public/favicon.svg` (kopiere das bestehende rellit-Favicon) und `public/robots.txt`
     mit `Sitemap: https://<slug>.rellit.de/sitemap-index.xml`.

2. **Seiten (DE Standard + /en)**
   - `src/pages/index.astro` (Deutsch, Root) und `src/pages/en/index.astro` (Englisch) – nutze
     `@rellit/theme/layouts/BaseLayout.astro` mit `lang`, `dePath`/`enPath`, `canonicalUrl`/`alternateUrl`,
     `rootHref="https://rellit.de"` (bzw. `/en` für die englische Seite). Füge sinnvollen SEO-Text (H1,
     Lead, kurze "Wie funktioniert es"/FAQ-Sektion) und optional JSON-LD (`WebApplication`) hinzu.
   - `src/pages/impressum.astro`, `src/pages/agb.astro`, `src/pages/en/imprint.astro`,
     `src/pages/en/terms.astro` – importiere `ImpressumContent`/`AgbContent` aus `@rellit/legal/...` (nicht
     neu schreiben, Rechtstexte bleiben zentral gepflegt).

3. **Tool-Logik**
   - Reine Client-Logik in `src/lib/` (TypeScript, keine Server-Calls). Das Tool darf standardmäßig KEINE
     Cookies setzen. Nur falls für das Tool zwingend nicht-essenzielle Cookies nötig sind (z.B. Analytics),
     binde `CookieBanner` ein und setze `useCookies` in `BaseLayout` – das ist die Ausnahme, nicht die Regel.
   - UI als Astro-Komponente in `src/components/`, mit `<script>`-Modul, das die Bibliothek importiert und
     das DOM verdrahtet (siehe `apps/converter/src/components/Converter.astro` und
     `apps/hasher/src/components/Hasher.astro` als Vorlage für Stil, Copy/Download-Buttons, Fehleranzeige).
   - Nutze die vorhandenen CSS-Klassen aus `@rellit/theme` (`.card`, `.btn`, `textarea.mono`, etc.) statt
     neues globales CSS zu erfinden; tool-spezifisches Styling scoped im `<style>`-Block der Komponente.
   - **Achtung bei scoped CSS + dynamisch per JS erzeugten Elementen:** Astro scoped `<style>` fügt das
     Scoping-Attribut nur Elementen hinzu, die im statischen Template stehen. Baust du im Client-Script
     Elemente per `document.createElement` (z.B. Tabellenzeilen, Ergebnislisten), greifen scoped Styles
     dafür NICHT – diese Regeln mit `:global(...)` umschließen (siehe `Hasher.astro`).

4. **Einstellungen in localStorage merken (Pflicht-Konvention, kein Cookie)**
   - Jedes Tool speichert seine aktuellen UI-Einstellungen (gewählte Optionen, Checkboxen, Dropdowns –
     NICHT die eingegebenen Rohdaten/Texte des Nutzers) unter dem Key `rellit:<slug>:settings` in
     `localStorage`, damit sie beim nächsten Besuch erhalten bleiben. Kein Cookie-Banner nötig, da
     `localStorage` kein Cookie ist.
   - Muster (siehe `Converter.astro` für Von/Nach-Format, `Hasher.astro` für Algorithmen-Checkboxen +
     Zeilen-Trenner-Toggle): eine `loadSettings()`-Funktion, die beim Initialisieren des Scripts (vor dem
     ersten Rendern der Ergebnisse) per `try { JSON.parse(localStorage.getItem(...)) } catch { return null }`
     liest und die UI-Elemente entsprechend vorbelegt, plus eine `saveSettings()`-Funktion, die bei jedem
     `change`-Event der relevanten Steuerelemente den aktuellen Zustand per
     `try { localStorage.setItem(...) } catch {}` schreibt (try/catch wegen Privacy-Mode, wo `localStorage`
     blockiert sein kann).
   - Diese Konvention gilt für jedes neue Tool – beim Anlegen eines Tools immer mit einplanen, nicht
     nachträglich vergessen.

5. **Registrierung**
   - Ergänze das neue Tool in `apps/www/src/data/tools.ts` (slug, subdomain, Name, Tag, DE/EN-Beschreibung),
     damit es auf der Haupt-Landingpage erscheint.
   - Ergänze `npm run build` in der Root-`package.json` (Skript `build`) um die neue App, analog zu den
     bestehenden Einträgen.

6. **Verifikation (Pflicht, nicht optional)**
   - `npm install` im Projekt-Root ausführen und die Ausgabe tatsächlich lesen: es müssen **0
     vulnerabilities** gemeldet werden. Falls nicht: Ursache klären (meist eine transitive Abhängigkeit,
     die durch eine Major-Version einer anderen Bibliothek gedeckelt ist, z.B. esbuild durch Vite) und durch
     Anheben der richtigen Major-Version beheben – nicht mit `overrides` übertünchen, wenn der Override von
     einer `^`-Range ohnehin ignoriert würde.
   - Danach `npm run build --workspace=apps/<slug>` ausführen und **wirklich bis zum Ende ohne Fehler**
     durchlaufen lassen. Ein Build, der Seiten generiert aber am Ende mit einem Fehler abbricht (z.B. in
     einem Integrations-Hook), zählt nicht als erfolgreich.
   - Achte bei CommonJS-only npm-Paketen (kein natives ESM) auf Vite-Warnungen/Fehler wie "Named export
     'x' not found. The requested module '<pkg>' is a CommonJS module...". Fix: Default-Import + Destructure
     verwenden (`import pkg from "paket"; const { x, y } = pkg;`) statt `import { x, y } from "paket"`.
   - Prüfe stichprobenartig die generierten Dateien in `apps/<slug>/dist/` (index.html, en/index.html,
     sitemap, robots.txt) und dass keine ungewollten Skripte (z.B. Cookie-Banner-JS) auf Seiten landen, die
     gar keine Cookies verwenden.
   - Falls in der aktuellen Umgebung kein Netzwerkzugriff auf die npm-Registry besteht: das dem Nutzer
     explizit und unmissverständlich sagen (nicht als "vermutlich funktioniert es" kaschieren), und genau
     beschreiben, was er lokal ausführen muss, um selbst zu verifizieren.

## Wichtige Leitplanken

- Jedes Tool bekommt eine eigene Subdomain-App unter `apps/`, kein Tool wird in eine bestehende App
  gemischt.
- Rechtstexte (Impressum/AGB) niemals pro Tool neu formulieren – immer die zentralen Komponenten aus
  `packages/legal` wiederverwenden, damit Änderungen an einer Stelle für alle Tools gelten.
- Alles muss statisch kompilierbar sein (`output: "static"`), kein serverseitiger Code, keine
  Server-Runtime-Abhängigkeit.
- SEO ist das Hauptziel: aussagekräftiger Title/Description pro Sprachversion, `canonical` +
  `hreflang`-Alternates (schon in `BaseLayout`/`SEO`-Komponente eingebaut), sprechende H1/H2, kurzer
  Fließtext mit den relevanten Keywords statt nur nacktem UI-Widget.
- Astro-Major-Version und `@astrojs/sitemap`-Version müssen zusammenpassen: neuere `@astrojs/sitemap`-Minor-
  Releases setzen den Astro-5-Hook `astro:routes:resolved` voraus und crashen auf Astro 4 mit
  "Cannot read properties of undefined (reading 'reduce')". Immer dieselbe Astro-Major-Version wie in den
  anderen Apps verwenden, niemals isoliert eine App auf eine ältere Astro-Version pinnen.
- UI-Einstellungen jedes Tools gehören in `localStorage` (Konvention siehe Phase 2, Punkt 4), niemals in
  Cookies – das hält den Cookie-Banner unnötig für alle Tools, die keine echten Cookies brauchen.
- `npm install` muss 0 vulnerabilities melden und `npm run build` muss fehlerfrei durchlaufen, BEVOR ein
  Tool als fertig gilt – das ist keine Kür, sondern harte Anforderung (siehe eigene Erfahrung: ein erster
  Anlauf hatte sowohl eine durch eine gedeckelte esbuild-Version verursachte Sicherheitslücke als auch einen
  Build-Crash durch eine inkompatible Sitemap-Version, beides erst durch tatsächliches Ausführen von
  install/build gefunden, nicht durch Code-Review allein).
- Bei Unsicherheit über Scope oder wenn zwei Tool-Ideen gleichwertig gut erscheinen, kurz beim Nutzer
  nachfragen statt zu raten.

