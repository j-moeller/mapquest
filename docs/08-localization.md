# Languages: English and German

The app speaks English and German. *Menu › Language* chooses *System* (the
default: the language set for the app in the system's Settings, else the
device's), *English* or *Deutsch*. The choice applies at once: the map, the
menu and every list are built again in the new language. The system's own
dialogs (camera, location permission) follow from the next launch.

## The app's text

All text is written in English in the code and goes through `tr` / `trn`
(MapQuestCore, `Localization/Localization.swift`):

```swift
Text(tr("Map view"))
Text(tr("{0} of {1} sights captured", captured, total))
Text(trn("{0} region", "{0} regions", count))
```

* The key is the English text. Placeholders are numbered, `{0}`, `{1}`, so a
  translation can reorder them; arguments are any `CustomStringConvertible`
  (no format specifiers, nothing to crash on). `trn` picks the singular for 1;
  `{0}` is the count.
* German lives in `App/MapQuest/Resources/de.lproj/*.strings` (`Localizable.strings`
  for views, map, menu and debug panel; `Capture.strings` for sights,
  achievements and remembrance). `LanguageSettings` registers them at launch;
  `Localization.language` is the current language (thread-safe), and
  `Localization.locale` the locale for numbers and dates: the language with the
  device's region (`Formatters` in `Views/Formatters.swift` formats areas,
  distances, durations and dates with it – "1,25 km²" in German).
* The permission texts are in `en.lproj` / `de.lproj` `InfoPlist.strings`.
* `LanguageSettings` (`Localization/LanguageSettings.swift`) keeps the choice
  (`appLanguage`), writes it to `AppleLanguages` for the system's dialogs (or
  removes it for *System*), and publishes the language; `RootView`, the main
  screen and the menu are identified by it, so SwiftUI builds them again. A
  language set for the app in the system's Settings wins over an older choice
  in the menu.

Checks (MapQuestKit tests, run on Linux): `LocalizationTests` scans every Swift
file of the app for string literals. Text passed to `tr`/`trn` must have a
German translation with the same placeholders; translations no text uses, keys
with Swift interpolation and `tr` calls without a literal fail; and any literal
that looks like text (words with spaces, a capitalised word) but does not go
through `tr` fails – proper names that stay as they are carry
`// not localized` on their line.

## Names

Names keep their German original. `BilingualName` holds the German name and,
where English uses another, the English one:

* **Sights**: in English the English name comes first and the German original
  second ("Brandenburg Gate", under it "Brandenburger Tor"); where English uses
  the German name (Alexanderplatz, Gendarmenmarkt, Berghain) there is only the
  one. `Sight.name` is the name in the app's language, `Sight.otherName` the
  German original in English. In German only the German name is shown.
  Source: the `name_en` column of `Tools/capture/berlin_sights.csv` (→ `nameEn`
  in `berlin-sights.json`), chosen by hand from the English Wikipedia titles.
* **Stations** keep the German name first, as on the signs; a few have an
  English explanation in English ("Hauptbahnhof" – "Central Station";
  `Tools/transit/berlin_station_names_en.csv` → `nameEn`).
* **Rulers** (the chronicles in the sight packages): English first in English
  with the German original ("Frederick William II", "Friedrich Wilhelm II."),
  German in German. Eras, titles and reigns are given in both languages
  (`LocalizedText`).
* Districts and cities are German proper names in both languages.

## Data in both languages

| English | German | Made by |
|---|---|---|
| `berlin-sight-info.json` | `berlin-sight-info-de.json` | `fetch_sight_info.py --german`: the German Wikipedia introductions |
| `berlin-sight-history.json` | `berlin-sight-history-de.json` | `fetch_sight_history.py --german`: the facts' phrases from `Tools/capture/berlin_sight_history_de.csv` (styles, clients, notes, dates in words; every phrase needs a row), the history from the German article |
| `berlin-achievements.json` | the same file, `"de": {title, description}` per achievement | by hand |
| `berlin-remembrance.json` | `berlin-remembrance-de.json` (same chapters, places and walks) | by hand |

`Tools/packages/build_packages.py` puts both languages into the sight
packages – texts as `{"en": …, "de": …}`, entries and facts per language
(docs/09-sight-packages.md); `SightLibrary` resolves each language, German
falling back to English sight by sight. Achievements are decided on the English facts (rules name English
styles and clients), so the language never changes what counts.
`GermanDataTests` checks that the German files match the English ones (same
sights, years, sectors, places and stops; no English words left in the dates
and styles).

## Wording

German uses the informal *du*, typographic quotes („…“) and short phrasing
for small screens. Fixed terms: sight – Sehenswürdigkeit; discover – entdecken;
capture (by photo) – einfangen, a capture – Fang; collect (stations) – sammeln;
achievement – Erfolg; place of remembrance – Gedenkort, the Remembrance tab –
Gedenken; entry – Eintrag; fog of war – Nebel; line of sight – Sichtlinie;
map view – Kartenansicht; time span – Zeitraum; recording – Aufzeichnung;
data source – Datenquelle; station – Bahnhof; line – Linie; district – Bezirk;
walk – Rundgang.
