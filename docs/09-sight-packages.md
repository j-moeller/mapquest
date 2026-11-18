# Sight packages

Everything the capture game knows about a place – its sights with their
entries and history, the eras and rulers that date them, achievements, places
of remembrance with their walks, and transit stations – comes from **sight
packages**: JSON files the app installs, separate from the app itself. The app
only brings the map data of its cities (outlines, terrain, buildings) and the
game; MapQuest's Berlin and Braunschweig packages come with it today, but a
lean app could bring none and let people add the packages they want – from
MapQuest or from anyone else.

* Format: `mapquest-sights`, version 1 (`MapQuestCore/Packages`).
* Files: UTF-8 JSON, named `<anything>.sights.json`.
* Schema: [`Packages/schema/mapquest-sights-1.schema.json`](../Packages/schema/mapquest-sights-1.schema.json) (JSON Schema 2020-12).
* MapQuest's packages: [`Packages/`](../Packages) (built from `Packages/sources`, below).
* An example of a third-party package: [`Packages/examples/example.berlin.fountain-walk.sights.json`](../Packages/examples/example.berlin.fountain-walk.sights.json).

## Why JSON, and why packages that compose

JSON is readable, diffable and written by any tool or language; the app
decodes it with `Codable`, and a schema lets publishers check their files
before anyone installs them. Packages **compose**: the Berlin package builds on
(*includes*) Berlin's churches, its places of remembrance and its transit, each
of which is a package that also stands alone. Anyone can publish a package
that overlaps another – a fountain walk through Mitte, a guide to Berlin's
Romanesque churches – and the app resolves overlaps so that **a place is one
sight, captured once**, whichever packages describe it.

## A file

A file holds one package:

```json
{
  "format": "mapquest-sights",
  "formatVersion": 1,
  "id": "mapquest.berlin.churches",
  "version": "2026.11.18",
  "title": {"en": "Berlin churches", "de": "Berliner Kirchen"},
  …
}
```

or several, as a **bundle** (MapQuest's `berlin.sights.json` holds the Berlin
package and its three parts):

```json
{"format": "mapquest-sights", "formatVersion": 1, "packages": [{…}, {…}]}
```

`format` must be `mapquest-sights`. A `formatVersion` newer than the app's is
refused ("needs a newer version of MapQuest"); fields the app does not know are
ignored, so new optional fields do not need a new format version. A file is
refused as a whole if it cannot be decoded (the message names the place:
`packages[0].sights[3]: missing longitude`) or if a package has errors of its
own (`SightPackage.problems`: no ID or version, the same sight, achievement,
chronicle or station ID twice, a position off the globe, a radius ≤ 0).

**Texts** in several languages (`LocalizedText`) are either a string – the
same in every language – or an object of language codes:
`{"en": "Berlin Cathedral", "de": "Berliner Dom"}`. The app shows its language,
else English, else any. Leave out a language that would only repeat English.

## A package

| Field | | |
|---|---|---|
| `id` | required | Unique, reverse-DNS style: `mapquest.berlin.churches`, `org.example.fountains`. The same ID is the same package. |
| `version` | required | Compared part by part, numbers as numbers: `2026.11.18`, `1.10` > `1.9`. A newer version replaces an older one; an older one never replaces a newer one. |
| `title` | required | Text. |
| `summary` | | Text: what it brings. |
| `publisher`, `homepage`, `license` | | Shown in the app; `license` should name the licences of texts, photos and positions. |
| `language` | | The language of the sights' original names (`de`). |
| `region` | | `{id, name, bounds?}` – where its sights are (`berlin`). The app groups packages, the list and the statistics by region and follows the one you are in. `bounds` `{south, west, north, east}` (else the box around its sights). |
| `includes` | | IDs of packages it builds on (below). |
| `categories` | | Categories it adds (below). |
| `chronicles` | | Eras and rulers (below). |
| `sights` | | Below. |
| `achievements` | | Below. |
| `remembrance` | | `{chapters, tours}`: places of remembrance (below). |
| `transit` | | `{stations, lines}` (below). |

Every field but the first three is optional: a package may hold only
achievements over the sights of the packages it includes, or only a walk.

### Sights

```json
{
  "id": "brandenburger-tor",
  "name": "Brandenburger Tor",
  "names": {"en": "Brandenburg Gate"},
  "category": "monument",
  "latitude": 52.51627, "longitude": 13.377705, "radius": 40,
  "district": "Mitte",
  "wikidata": "Q82425",
  "entry": {"en": {"title": "Brandenburg Gate", "url": "https://en.wikipedia.org/wiki/Brandenburg_Gate",
                   "text": "…", "image": {"url": "…", "page": "…", "artist": "…", "license": "CC BY-SA 4.0"}},
            "de": {…}},
  "facts": {"year": 1788, "sector": "east",
            "localized": {"en": {"built": "1788–1791", "styles": ["Neoclassicism"],
                                 "architects": ["Carl Gotthard Langhans"], "commissionedBy": ["Frederick William II"],
                                 "history": "…"},
                          "de": {…}}}
}
```

| Field | | |
|---|---|---|
| `id` | required | Global: the same ID is the same place in every package (below). |
| `name` | required | The original name, in the package's `language` (or `nameLanguage`). |
| `names` | | Other languages where the name differs (`{"en": "Brandenburg Gate"}`); a name used as it is in English ("Alexanderplatz") needs none. |
| `category` | required | A core category or one the package declares (below). |
| `latitude`, `longitude` | required | WGS84. |
| `radius` | | Its extent in metres (default 40): the discovered area must cover the position, or reach within `radius − 50` for large open places. |
| `district` | | For district achievements. |
| `wikidata` | | The Wikidata item: places with the same item are one place (below). |
| `sameAs` | | IDs of the same place in other packages (below). |
| `chronicle` | | The chronicle that dates it (default: its package's first, else one named like its region). |
| `entry` | | Its encyclopedia entry by language: `title`, `url` (the article, credited), `text` (paragraphs separated by blank lines), `image` (`url`, `page`, `artist`, `license`, `licenseURL`). A language without one shows English. |
| `facts` | | `year` (dates it in its chronicle), `sector` (its part of a divided place: Berlin's `east`/`west`), `wikidata` (URL), and `localized` phrases by language: `built`, `opened`, `styles`, `architects`, `commissionedBy`, `history`. Achievement rules read the **English** styles, architects and clients – give them in every package that has achievements over them. |

Places of remembrance (categories `memorial`, `cemetery` and those declared
under them) are not part of the game: never captured, in no achievement, their
entries open to all.

### Categories: a shared core, extended under a parent

Icons, the map filter and achievement rules work by category, so packages must
agree on them. Every package can use the **core vocabulary** without declaring
it:

`landmark` `museum` `palace` `church` `viewpoint` `memorial` `park` `square`
`culture` `monument` `zoo` `bridge` `stadium` `fountain` `market` `government`
`cemetery` `club`

A package that needs a finer or new kind of place **declares** it under a
parent:

```json
"categories": [
  {"id": "chapel", "title": {"en": "Chapel", "de": "Kapelle"}, "parent": "church"},
  {"id": "wayside-chapel", "title": {"en": "Wayside chapel"}, "parent": "chapel", "symbol": "signpost.right"},
  {"id": "war-grave", "title": {"en": "War grave"}, "parent": "cemetery"}
]
```

A declared category is its parent wherever the parent is asked for: a rule for
`church` takes in chapels and wayside chapels (a rule for `chapel` only those),
hiding churches on the map hides them, it has the parent's icon unless it
names an SF Symbol (`symbol`), and it is a place of remembrance if its parent
is (or as `remembrance: true/false` says). The core vocabulary cannot be
redefined; of two packages declaring the same ID the first (in the order
below) counts. A category neither core nor declared is shown as a landmark and
noted (`unknownCategory`).

### Chronicles: eras and rulers

The *In history* card tells who ruled when a sight was built. The eras and
rulers are data, one **chronicle** per place:

```json
{"id": "berlin", "name": "Berlin",
 "eras": [{"id": "prussia", "name": {"en": "Kingdom of Prussia", "de": "Königreich Preußen"}, "years": "1701–1871",
           "summary": {…}, "start": "1701-01", "monarchy": true},
          {"id": "east", "name": {…}, "sector": "east", "start": "1949-10"}, …],
 "rulers": [{"name": "Friedrich Wilhelm II.", "names": {"en": "Frederick William II"}, "title": {…},
             "reign": "1786–1797", "era": "prussia", "start": "1786-08"}, …],
 "division": {"title": {"en": "While Berlin was divided"}, "until": 1990,
              "sectors": {"east": {"en": "East Berlin"}, "west": {"en": "West Berlin"}}}}
```

A year is read in July: the era begun last and its ruler begun last. While a
place was divided (`sector` eras), a sight's `facts.sector` chooses the side;
`division` names it on the card. `monarchy` shows a crown. Era IDs are what
achievement rules name (`"era": "prussia"`), so keep them unique across places
(Braunschweig's start with `bs-`).

### Achievements

```json
{"id": "churches", "group": "collections", "symbol": "bell.fill",
 "title": {"en": "Bells of Berlin", "de": "Glocken von Berlin"},
 "description": {"en": "Visit every church, …", "de": "…"},
 "rule": {"categories": ["church"]}}
```

`group`: `milestones`, `collections`, `stories`, `lines`, `eras`, `styles`,
`architects`, `districts` (another group shows as a story). `symbol`: an SF
Symbol. The **rule** picks places; the filters that are set must all match:

| Rule field | Picks |
|---|---|
| `categories` | sights of any of these categories (and those declared under them) |
| `era` | sights built in this era (an era ID of their chronicle) |
| `architect`, `commissionedBy` | sights by this person (compared without a note in parentheses: "Hermann Blankenstein (towers, 1878)" counts for Blankenstein) |
| `styles` | sights of any of these styles |
| `district` | sights in this district (or stations, with `places: stations`) |
| `sights` | exactly these sights, instead of filters |
| `include`, `exclude` | adjust either |
| `count`, `all: true` | a milestone: that many captures, or all |
| `places: "stations"`, `system` (`U`, `S`), `line` | stations; a line's in its order |

Rules, not lists, where possible: a sight added to a package joins its
category, era, district and architect without editing achievements. An
achievement whose rule finds fewer than two places is left out
(`skippedAchievement`). Sights count once photographed; stations once visited.

### Places of remembrance and walks

```json
"remembrance": {
  "chapters": [{"id": "holocaust", "title": {…}, "years": "1933–1945", "text": {…},
                "places": [{"sight": "holocaust-mahnmal", "remembers": {…}}]}],
  "tours": [{"id": "centre", "title": {…}, "text": {…}, "stops": ["neue-wache", "holocaust-mahnmal", …]}]
}
```

Chapters tell what the places remember, as history; tours are walks between
them in an order that tells it. The places are sights of a remembrance
category (of this package or one it includes).

### Transit

```json
"transit": {
  "stations": [{"id": "u:adenauerplatz", "name": "Adenauerplatz", "system": "U", "lines": ["U7"],
                "latitude": 52.500102, "longitude": 13.307287, "radius": 80, "district": "…"}],
  "lines": [{"id": "U1", "system": "U", "colour": "#7DAD4C", "name": "Uhlandstraße – Warschauer Straße",
             "stations": ["u:uhlandstrasse", …]}]
}
```

Format 1 knows two systems, `U` (U-Bahn) and `S` (S-Bahn). A station is
collected by going there.

## How packages compose and overlap

The installed packages are resolved into one world (`SightLibrary`):

1. **One version per package**: of the same package ID the newest version
   counts.
2. **An order**: newer packages first (by version), then by ID. Wherever two
   packages define the **same ID** – a sight, achievement, chronicle, category,
   station, line, chapter or walk – the first in this order is used, as a
   whole (descriptions are not merged field by field). IDs are global: the
   same ID is the same thing, and the newest description of it wins.
3. **The same place under other IDs**: a sight that names another in `sameAs`,
   or has the same Wikidata item as one before it, is **merged** into that one.
   It is not shown twice; rules, chapters and walks that name it count the
   place it was merged into; what was discovered or captured under the merged
   ID counts for that place too (`CaptureLog.adoptAliases`, the merged ID keeps
   its own for when the package is used alone again).
4. **Scope**: a package's achievements pick from its own sights and stations
   and those of the packages it **includes**, transitively. The Berlin churches
   package's "all churches" never counts Braunschweig's churches; the Berlin
   package's "Ich bin ein Berliner" counts everything Berlin includes. A sight
   or station a rule names outside its scope is noted (`unknownPlace`).
5. **Categories**: the core vocabulary plus all declared categories (above).
6. **Regions**: by ID; the first name and bounds of each.

So overlap is safe in every direction:

* A **part and its whole** (`mapquest.berlin.churches` inside `mapquest.berlin`):
  installed together, the churches are in Berlin's scope; installed alone, the
  churches package works on its own with its own achievement and chronicle. The
  city package without its parts still resolves – it notes the missing ones
  (`missingInclude`) and its achievements count what is there.
* **Two publishers describing the same place**: give your sight its Wikidata
  item (or `sameAs` the other package's ID) and it becomes the existing sight;
  your achievement counts it, and a capture counts for both packages.
* **Shared categories**: use the core vocabulary; declare finer kinds under a
  core parent, so other packages' rules and the map filter still see them.

### IDs

Make your IDs unique: prefix them with your package ID (`example.neptune`,
`example.fountain-walk`). MapQuest's own sights keep the short IDs they had
before packages (`brandenburger-tor`) so that capture logs stay valid;
Braunschweig's achievements and chapters start with `bs-`. Never change the ID
of a published sight: captures are stored by it.

### What the app notes

Resolution never fails; what does not fit is noted per package
(`SightLibrary.Issue`) and shown under *Notes* on the package's page:
`missingInclude`, `unknownCategory`, `unknownChronicle`, `unknownPlace`,
`unknownEra`, `skippedAchievement`, `notRemembrance` (a chapter names a sight
that is no place of remembrance) and `merged` (a sight was merged into
another). MapQuest's packages resolve without any (tested).

## In the app

* **Installed packages** live in `Application Support/MapQuest/SightPackages`,
  one file per package (`SightPackageStore`). At launch the app reads them and
  resolves them (`CaptureModel.library`); after adding or removing one it
  resolves again and checks the new sights against the area discovered so far
  – quietly: places you have been to are discovered without a celebration.
* **Packages that come with the app** (`Resources/Packages/*.sights.json`) are
  installed on first launch and when the app brings changed ones
  (`BundledPackages`); one the user removed is not installed again by itself –
  the page offers it under *Comes with the app*.
* ***Menu › Sight packages***: the installed packages by region – title, what
  they hold, version, publisher, a warning sign for notes. A package's page:
  summary, version, publisher, region, homepage, licence, contents (sights,
  places of remembrance, achievements, stations and lines, chapters and walks,
  history, its own categories), what it builds on and is part of, how many of
  its sights other packages share, notes, *Share package file* and *Remove
  package* (what you discovered and captured is kept; add the package again and
  it is back). *Add from a file…* (Files) and *Add from a link…* (an https://
  address) show the packages first – title, summary, contents, and whether
  they add, update or would replace a newer version (which is kept) – then
  what adding them did.
* **From elsewhere**: MapQuest opens JSON files (*Open in MapQuest* from Files,
  Mail or Safari downloads) and links `mapquest://install?url=https://…` – a
  website can offer its package with one tap; the app shows it before adding.
* **Export and import** (*Menu › Export and import*): the ZIP holds the
  installed packages (`sights/packages.sights.json`); importing installs them
  (a newer installed version is kept), so captures always come with their sights.

## MapQuest's packages

Built by `Tools/packages/build_packages.py` from the build tools' files in
`Packages/sources/<city>/` (sights, entries and history from
`Tools/capture/*`, stations from `Tools/transit/build_stations.py`, chronicles,
achievements and remembrance texts by hand):

```bash
python3 Tools/packages/build_packages.py            # version: today's date
```

It writes `Packages/<city>.sights.json` (a bundle of the city's packages),
`Packages/parts/<id>.sights.json` (each on its own, to publish separately) and
copies the bundles into the app (`App/MapQuest/Resources/Packages`, unless
`--no-app`). Region bounds come from the cities' outlines.

| Package | Includes | Sights | Achievements | Other |
|---|---|---|---|---|
| `mapquest.berlin` – Berlin | the three below | 153 | 72 | Berlin's chronicle |
| `mapquest.berlin.churches` – Berlin churches | | 13 | 1 ("Bells of Berlin") | chronicle |
| `mapquest.berlin.remembrance` – Berlin remembers | | 18 places of remembrance | | 5 chapters, 2 walks |
| `mapquest.berlin.transit` – Berlin U-Bahn and S-Bahn | | | 29 (lines, stations) | 343 stations, 25 lines |
| `mapquest.braunschweig` – Braunschweig | the two below | 40 | 32 | Braunschweig's chronicle |
| `mapquest.braunschweig.churches` – Braunschweig churches | | 11 | 1 | chronicle |
| `mapquest.braunschweig.remembrance` – Braunschweig remembers | | 4 places of remembrance | | 4 chapters, a walk |

Together: Berlin 184 sights and 102 achievements, Braunschweig 55 and 33 – as
before packages. Licences: texts Wikipedia (CC BY-SA 4.0), photos Wikimedia
Commons (per photo), facts Wikidata (CC0, hand-checked), positions
OpenStreetMap (ODbL 1.0); achievements, chronicles and remembrance texts
MapQuest. Tests (`SightPackageTests`, and the data tests reading the packages)
check that every package resolves without notes, alone and together, and that
the example package merges into Berlin.

## Making a package

1. Pick an ID (`org.example.berlin-fountains`) and prefix your sights',
   achievements' and chapters' IDs with it.
2. Use core categories; declare finer ones under a core parent.
3. For places another package may have, give the Wikidata item (or `sameAs`).
4. Date sights in a chronicle: include the place's package (`includes`) and
   name its chronicle (`"chronicle": "berlin"`), or bring your own.
5. Write texts in English at least; add the languages you can.
6. Name your licences (`license`) and credit texts and photos in `entry`.
7. Check the file against the schema and add it in the app: its page lists
   anything that did not resolve.
8. Publish it over https and link it as `mapquest://install?url=<its address>`.
   Raise `version` with every change.
