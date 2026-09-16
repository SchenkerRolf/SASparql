# Spec: SAS-Makropaket für SPARQL-Abfragen

## 1. Zielsetzung

Ein SAS-Makropaket, das SPARQL-Abfragen gegen einen HTTP(S)-Endpunkt ausführt und
das Ergebnis als SAS-Dataset (bzw. bei CONSTRUCT/DESCRIBE als RDF-Datei) zur
Verfügung stellt.

Unterstützt werden müssen, orthogonal kombinierbar:

- **Query-Quelle**: Text (`query=`) oder Datei (`queryfile=`)
- **HTTP-Methode**: `POST` oder `GET`
- **Ergebnisform**: `SELECT`/`ASK` (→ Dataset), `CONSTRUCT`/`DESCRIBE` (→ RDF-Datei)
- **Ergebnisformat SELECT/ASK**: `XML` oder `JSON`
- **Ergebnisformat CONSTRUCT/DESCRIBE**: `TURTLE` oder `JSONLD`
- **Proxy**: optional, mit eigenem Server/User/Passwort, unabhängig von der
  Endpunkt-Authentifizierung

## 2. Zielumgebung (verbindlich)

- **SAS-Version:** 9.4
- **Ausführungsort:** ausschliesslich auf einem SAS-Server; Clients (z. B.
  SAS Enterprise Guide) haben selbst kein lokales SAS installiert. Das heisst
  konkret:
  - Alle temporären Dateien/Filerefs müssen an einem Ort liegen, der für die
    Server-Session zugänglich ist (z. B. unterhalb von
    `%sysfunc(pathname(work))`), nicht auf einem "lokalen" Client-Pfad.
  - Netzwerk-/Proxy-Konfiguration gilt serverseitig — d. h. `PROXYHOST=` etc.
    bzw. die OS-Umgebungsvariablen (`http_proxy`/`https_proxy`) müssen aus
    Sicht des SAS-Servers stimmen, nicht aus Sicht des Enterprise-Guide-Clients.
  - **Session-Encoding beachten:** die Server-Session läuft in WLATIN1 (SBCS).
    SPARQL-Antworten sind UTF-8; deshalb werden Response-Dateien und die
    XML/JSON-Libname-Zugriffe explizit mit `encoding="utf-8"` gelesen. Zeichen,
    die WLATIN1 nicht abbilden kann (z. B. CJK), gehen beim Landen im
    SAS-Dataset verloren — für volle Unicode-Treue eine UTF-8-Session verwenden
    (siehe Grenzen, §6.2).
  - **Parallelität ist ein reales Szenario**, nicht nur ein Randfall: mehrere
    Nutzer/Sessions können das Makropaket gleichzeitig auf demselben Server
    aufrufen. Tempfile-/Fileref-Namen müssen daher **standardmässig**
    eindeutig sein (siehe 2.2, Namensschema), nicht nur optional.
- **Kein Testendpunkt aktuell vorhanden.** Tests laufen gegen Fixtures
  (siehe Abschnitt 6.3), nicht gegen einen Live-SPARQL-Server.

### 2.1 Technik-Entscheide (abgeleitet aus obigem)

| Frage (ehem. offen) | Entscheid |
|---|---|
| SELECT/ASK-Ergebnisformat | **Beides**: XML (`application/sparql-results+xml`) und JSON (`application/sparql-results+json`), steuerbar über neuen Parameter `resultformat=XML\|JSON` (Default `XML`) |
| Parsing-Technik XML | **XMLV2-Libname-Engine** (`libname x xmlv2 ...;`). **Korrektur (server-verifiziert 2026-09-15):** Automap scheitert an der SPARQL-Results-XML-Struktur (polymorphe `<binding>`-Kindelemente + Default-Namespace) mit `ERROR: XML data is not in a format supported natively...`. Es wird daher doch eine **explizite XML-Map** verwendet (generiert zur Laufzeit in `sparql_parse_response`), zusammen mit einem vorgelagerten Entfernen des Default-Namespace aus dem Rohtext. |
| Parsing-Technik JSON | **JSON-Libname-Engine** (`libname x json "...";`) — ab **SAS 9.4M4** verfügbar; Zielserver ist ≥ 9.4M4, daher einsetzbar. |
| SAS-Version/Umgebung | **SAS 9.4M4+**, serverbasiert (siehe oben) |
| Session-Encoding | **WLATIN1 / SBCS** (Windows-SAS). Antworten sind UTF-8 → Response-Fileref und XML/JSON-Libname explizit mit `encoding="utf-8"` lesen/transcodieren. |
| Parallelität | Ja, muss unterstützt werden — eindeutige Tempnamen per Default |
| Testendpunkt | Keiner — Tests mit Fixtures/`debug_nohttp=Y` |

### 2.2 Namensschema für Temporärdateien (wegen Parallelität)

Der bisherige Ansatz mit einem statischen `tempnamestem=temp-sparqlquery`
reicht **nicht mehr** als Default, sobald mehrere Sessions gleichzeitig
laufen können. Neuer Default für `tempnamestem=`, falls vom Aufrufer nicht
explizit gesetzt:

```
temp-sparqlquery-&sysuserid.-&sysjobid.-<Zeitstempel>-<Session-Zähler>
```

- `&sysuserid` (SAS-Automakrovariable, OS-/Login-Kennung der Session) dient
  primär der **Nachvollziehbarkeit**: bei Debugging auf einem
  Mehrbenutzer-Server sieht man am Dateinamen sofort, zu welchem Nutzer eine
  liegengebliebene Tempdatei gehört. Für die **Eindeutigkeit** allein reicht
  `&sysuserid` aber nicht aus — derselbe Nutzer kann durchaus mehrere
  parallele Sessions (z. B. zwei Enterprise-Guide-Fenster) offen haben.
  Deshalb wird es zusätzlich zu, nicht anstelle von, den folgenden zwei
  Elementen verwendet.
- `&sysjobid` (SAS-Automakrovariable) unterscheidet verschiedene
  SAS-Sessions/-Prozesse auf dem Server voneinander.
- Zusätzlich ein Zeitstempel (`%sysfunc(datetime(),…)`); dessen tatsächliche
  Auflösung ist OS-abhängig und garantiert für sich allein **keine**
  Eindeutigkeit bei schnell aufeinanderfolgenden Aufrufen. Deshalb zusätzlich
  ein **session-globaler Zähler** (`%global`, pro Aufruf inkrementiert), der
  Eindeutigkeit **innerhalb derselben Session** (z. B. in einer Schleife)
  unabhängig von der Uhr sicherstellt.
- **Fileref-Token ≠ Dateiname:** SAS-Filerefs sind gültige SAS-Namen (max. 8
  Zeichen, keine Bindestriche). Das lange, eindeutige Schema oben ist der
  **physische Dateiname**; der Fileref selbst ist ein separat generiertes,
  kurzes (≤ 8 Zeichen) Token.
- Alle **physischen Tempdateien** liegen unter `%sysfunc(pathname(work))`,
  nicht in einem fest einprogrammierten Pfad.
- Kollisionsschutz bleibt formal die Kombination aus `&sysjobid` +
  Zeitstempel + Session-Zähler; `&sysuserid` ist ein zusätzliches, rein
  lesbarkeitsförderndes Element im Namen.
- Der Parameter `tempnamestem=` bleibt weiterhin überschreibbar, für den
  Fall, dass ein Aufrufer bewusst einen festen, nachvollziehbaren Namen
  braucht (z. B. für gezieltes Debugging).

---

## 3. Architektur — vier Makros

```
%sparqlquery                  (Orchestrator, öffentliche API)
   ├─ %sparql_build_request   (Query-Text vereinheitlichen)
   ├─ %sparql_execute         (einziger PROC HTTP-Aufruf)
   └─ %sparql_parse_response  (XML/JSON → Dataset, oder RDF-Datei durchreichen)
```

Dateistruktur:

```
sparql-sas/
├── README.md
├── macros/
│   ├── sparql_build_request.sas
│   ├── sparql_execute.sas
│   ├── sparql_parse_response.sas
│   └── sparqlquery.sas
└── tests/
    ├── fixtures/
    │   ├── response_select.xml
    │   ├── response_select.json
    │   ├── response_ask.xml
    │   ├── response_ask.json
    │   ├── response_construct.ttl
    │   └── response_construct.jsonld
    └── test_sparqlquery.sas
```

---

### 3.1 `%sparql_build_request`

**Zweck:** Egal ob `query=` oder `queryfile=` übergeben wurde — am Ende liegt
der Query-Text vollständig (ohne Zeilenlängen-Trunkierung) in einem Fileref
vor.

**Parameter:**

| Parameter      | Pflicht | Default | Beschreibung |
|----------------|---------|---------|--------------|
| `query=`       | nein*   | (leer)  | Query als Text |
| `queryfile=`   | nein*   | (leer)  | Pfad zu Datei mit Query |
| `out_fileref=` | ja      | —       | Fileref für den vereinheitlichten Query-Text |

\* genau einer von beiden muss gesetzt sein (V1, Abschnitt 5).

**Verhalten:**
- `query=` → Text via `symget()` in `out_fileref` schreiben.
- `queryfile=` → Datei **als Ganzes kopieren** (z. B. `%sysfunc(fcopy(...))`
  oder binäres Kopieren), nicht zeilenweise mit fixer `$200`-Länge einlesen.
- **Sonderzeichen in `query=`:** SPARQL-Text enthält oft `&`, `%`,
  Anführungszeichen — als Makro-Parameter werden `&`/`%` sonst vom
  Makroprozessor interpretiert. Der Aufrufer muss dann `query=%nrstr(...)`
  nutzen. Für komplexe/lange Queries wird `queryfile=` empfohlen (keine
  Makro-Tokenisierung, keine ~64 K-Grenze von `symget()`).

---

### 3.2 `%sparql_execute`

**Zweck:** Der einzige Ort im Paket, an dem `PROC HTTP` aufgerufen wird.

**Parameter:**

| Parameter            | Pflicht | Default | Beschreibung |
|------------------------|---------|---------|--------------|
| `endpoint=`           | ja      | —       | SPARQL-Endpunkt-URL |
| `in_fileref=`         | ja      | —       | Fileref mit Query-Text |
| `method=`             | nein    | `POST`  | `POST` oder `GET` |
| `queryform=`          | nein    | `SELECT`| `SELECT`/`ASK`/`CONSTRUCT`/`DESCRIBE` |
| `resultformat=`       | nein    | `XML` (bei SELECT/ASK) bzw. `TURTLE` (bei CONSTRUCT/DESCRIBE) | Gültige Werte hängen von `queryform` ab, siehe Tabelle unten und V6 |
| `webuser=`            | nein    | (leer)  | Endpunkt-Auth |
| `webpassword=`        | nein    | (leer)  | Endpunkt-Auth (idealerweise `PROC PWENCODE`-verschlüsselt) |
| `proxyhost=`          | nein    | (leer)  | Proxy-Server; leer = OS-Umgebungsvariable/kein Proxy |
| `proxyport=`          | nein    | (leer)  | Proxy-Port |
| `proxyuser=`          | nein    | (leer)  | Proxy-Auth |
| `proxypassword=`      | nein    | (leer)  | Proxy-Auth |
| `out_fileref=`        | ja      | —       | Fileref für Response-Body |
| `headerout_fileref=`  | nein    | intern generiert | Fileref für Response-Header |
| `timeout=`            | nein    | 60      | Sekunden |

**Accept-Header-Logik:**

| `queryform` | `resultformat` | Accept-Header |
|---|---|---|
| SELECT/ASK | XML | `application/sparql-results+xml` |
| SELECT/ASK | JSON | `application/sparql-results+json` |
| CONSTRUCT/DESCRIBE | TURTLE (Default) | `text/turtle` |
| CONSTRUCT/DESCRIBE | JSONLD | `application/ld+json` |

`resultformat=` ist also ein einziger Parameter, dessen gültiger Wertebereich
vom gleichzeitig gesetzten `queryform=` abhängt (siehe V6, Abschnitt 5):
`XML`/`JSON` bei SELECT/ASK, `TURTLE`/`JSONLD` bei CONSTRUCT/DESCRIBE. Eine
Kombination aus den "falschen" Gruppen (z. B. `queryform=SELECT` mit
`resultformat=TURTLE`) ist ein Validierungsfehler.

**Verhalten:**
- POST: Query als Body, `ct="application/sparql-query"` (einmalig gesetzt).
- GET: kompletter Query-Text in **einem** `urlencode()`-Aufruf.
- `PROXYHOST=`/`PROXYPORT=` nur setzen, wenn `proxyhost=` nicht leer ist.
  `proxyuser=`/`proxypassword=` werden auf die `PROC HTTP`-Optionen
  `PROXYUSERNAME=`/`PROXYPASSWORD=` gemappt (ab 9.4M4 verfügbar).
- Nach dem Call: `&SYS_PROCHTTP_STATUS_CODE` in globale Statusvariable
  `&sparql_http_status` übernehmen (Pflicht, siehe Abschnitt 5, V8). Ist die
  Automakrovariable leer/nicht gesetzt (z. B. DNS-/Timeout-Fehler vor jeder
  HTTP-Antwort), `&sparql_http_status` auf einen definierten Nicht-2xx-Wert
  (z. B. `000`) setzen, damit V8 greift und `%eval` nicht auf nicht-numerischem
  Wert stolpert.
- `debug_nohttp=Y` muss für **jede** Methode/Quelle-Kombination gleich
  greifen — es gibt nur diesen einen Aufrufpfad, also strukturell garantiert.

---

### 3.3 `%sparql_parse_response`

**Zweck:** Response interpretieren, abhängig von `queryform` und
`resultformat`.

**Parameter:**

| Parameter         | Pflicht | Default | Beschreibung |
|--------------------|---------|---------|--------------|
| `in_fileref=`      | ja      | —       | Fileref mit Response-Body |
| `queryform=`       | nein    | `SELECT`| steuert Verarbeitungspfad |
| `resultformat=`    | nein    | `XML` bzw. `TURTLE` | siehe Tabelle in 3.2 und V6 |
| `resultdsn=`       | nein    | `queryresult` | Ziel-Dataset (nur SELECT/ASK) |
| `resultfile=`      | nein    | (leer)  | Zieldatei für RDF-Graph (CONSTRUCT/DESCRIBE, Turtle **oder** JSON-LD — Dateiendung sollte zu `resultformat` passen, z. B. `.ttl` vs. `.jsonld`) |
| `debug=`           | nein    | `N`     | zusätzliche Log-Ausgabe |
| `debug_previewlines=` | nein | 10     | Anzahl Log-Zeilen bei CONSTRUCT/DESCRIBE-Vorschau |

**Verhalten:**
- **SELECT** (XML *oder* JSON) → einheitliches **langes/tidy** `resultdsn` mit
  fester Struktur, unabhängig vom `resultformat`:

  | Spalte | Typ | Inhalt |
  |---|---|---|
  | `ridx` | num | 1-basierter Ergebnis-Index (Zeilennummer im Result-Set) |
  | `var` | char | SPARQL-Variablenname |
  | `value` | char | Wert als Text |
  | `type` | char | `uri` / `literal` / `bnode` |
  | `datatype` | char | Datatype-IRI bei typisierten Literalen, sonst leer |
  | `lang` | char | Sprach-Tag bei Sprach-Literalen, sonst leer |

  XML-Libname- und JSON-Libname-Engine werden beide auf genau dieses Schema
  abgebildet (kein dynamisches `PROC TRANSPOSE` nötig).
- **Ungebundene Variablen** (in einem Result nicht belegt) → **keine** Zeile
  (entspricht dem XML/JSON-Verhalten). Dadurch ergeben `resultformat=XML` und
  `resultformat=JSON` desselben SELECT **denselben** `resultdsn`-Inhalt —
  explizites Abnahmekriterium (siehe Abschnitt 6).
- **ASK** → eigenes 1-Zeilen-`resultdsn` mit einer Char-Spalte `boolean` ∈
  {`true`,`false`}. Auch hier: XML und JSON ergeben dasselbe Ergebnis.
- **Encoding:** Response-Fileref und XML/JSON-Libname werden mit
  `encoding="utf-8"` gelesen (Session ist WLATIN1, siehe Abschnitt 2).
- **CONSTRUCT/DESCRIBE** → Datei nach `resultfile` kopieren, unabhängig davon
  ob Turtle oder JSON-LD — reiner Dateitransfer ohne Konvertierung in ein
  SAS-Dataset, nur der Accept-Header (3.2) und damit das Ausgabeformat ändern
  sich. Optionale Log-Vorschau (`debug=Y`, `debug_previewlines=`) gilt für
  beide Formate gleich.

---

### 3.4 `%sparqlquery` (Orchestrator)

**Parameter:** Vereinigung der relevanten Parameter aus 3.1–3.3, plus:

| Parameter          | Pflicht | Default            | Beschreibung |
|----------------------|---------|--------------------|--------------|
| `problemhandling=`   | nein    | `ABORTCANCEL`      | `ABORTCANCEL` oder `RETURN` |
| `debug=`             | nein    | `N`                | |
| `debug_nohttp=`      | nein    | `N`                | `Y` = `%sparql_execute` überspringt den `PROC HTTP`-Aufruf (Test ohne Netz). Kontrakt: Query wird normal gebaut, Tempdateien werden erzeugt, `&sparql_http_status` wird auf `200` gesetzt, **kein** Body → Orchestrator überspringt das Parsing, `&sparql_rc=0` + Log-Hinweis. |
| `showresponse=`      | nein    | `Y`                | `Y` = Ergebnis am Ende zeigen (SELECT/ASK: `PROC PRINT`/Obs-Zahl von `resultdsn`; CONSTRUCT/DESCRIBE: Log-Vorschau gem. `debug_previewlines`); `N` = keine Anzeige. |
| `tempnamestem=`      | nein    | siehe 2.2 (automatisch eindeutig) | |

**Ablauf:**
1. Parameter validieren (Abschnitt 5) — vor jeder Aktion.
2. `%sparql_build_request` aufrufen.
3. `%sparql_execute` aufrufen.
4. `&sparql_http_status` prüfen — bei Nicht-2xx: `problemhandling`-Logik,
   **kein** Aufruf von `%sparql_parse_response`.
5. `%sparql_parse_response` aufrufen.
6. Temporäre Filerefs aufräumen (`filename ... clear;`), ausser bei
   `debug=Y` (dann Log-Hinweis, wo die Dateien liegen bleiben).

---

## 4. Status-/Rückgabewert-Konzept

Globale Makrovariablen, von jedem Makro gesetzt:

- `&sparql_rc` — 0 = ok, ≠0 = Fehler (1=Parameterfehler, 2=HTTP-Fehler,
  3=Parse-Fehler)
- `&sparql_msg` — Klartext-Fehlermeldung, falls `sparql_rc` ≠ 0
- `&sparql_http_status` — von `%sparql_execute` gesetzt, auch bei Erfolg

Ermöglicht `problemhandling=RETURN` als echte, nutzbare Alternative zu
`ABORTCANCEL` (der Aufrufer prüft `&sparql_rc` nach dem Makroaufruf).

---

## 5. Parametervalidierung (verbindlich, vor jeder Aktion)

| # | Regel | Geprüft in |
|---|-------|-----------|
| V1 | Genau eines von `query=`/`queryfile=` muss gesetzt sein | `sparql_build_request`, zusätzlich im Orchestrator |
| V2 | `queryfile=` muss existieren (`%sysfunc(fileexist(...))`) | `sparql_build_request` |
| V3 | `method=` nur `POST`/`GET` (case-insensitive) | `sparql_execute` |
| V4 | `endpoint=` nicht leer, beginnt mit `http://`/`https://` | `sparql_execute` |
| V5 | `queryform=` nur `SELECT`/`ASK`/`CONSTRUCT`/`DESCRIBE` | `sparql_execute`, `sparql_parse_response` |
| V6 | `resultformat=` muss zum `queryform=` passen: bei `queryform` ∈ {SELECT,ASK} nur `XML`/`JSON` zulässig; bei `queryform` ∈ {CONSTRUCT,DESCRIBE} nur `TURTLE`/`JSONLD` zulässig | `sparql_execute`, `sparql_parse_response` |
| V7 | Wenn `proxyuser=`/`proxypassword=` gesetzt, muss auch `proxyhost=` gesetzt sein | `sparql_execute` |
| V8 | `&sparql_http_status` muss 2xx sein, sonst Abbruch **vor** dem Parsing; **leerer/nicht-numerischer** Wert (Verbindungsfehler) gilt als Fehler | Orchestrator, nach `sparql_execute` |
| V9 | `resultdsn=` ein gültiger SAS-Dataset-Name (`%sysfunc(nvalid(...))`) | `sparql_parse_response` |
| V10 | `resultfile=` muss gesetzt sein, wenn `queryform` ∈ {CONSTRUCT,DESCRIBE} | Orchestrator, `sparql_parse_response` |

**Fehlerverhalten (einheitlich):**
- Jede Verletzung → **eine** klare `%put ERROR:`-Zeile mit Makronamen,
  Parameter, konkretem Problem.
- Danach `problemhandling=`:
  - `ABORTCANCEL` (Default) → `data _null_; abort cancel; run;`
  - `RETURN` → `%return` mit gesetztem `&sparql_rc` (≠0)
- Kein `PROC HTTP`, kein Parsing, solange eine Validierung fehlgeschlagen ist.

---

## 6. Dokumentation & Tests

### 6.1 Pro Datei (Makro-Header)

```sas
/*------------------------------------------------------------------------*\
 Makro    : sparql_execute
 Zweck    : Führt genau einen PROC HTTP-Aufruf gegen einen SPARQL-Endpunkt
            aus (POST oder GET), inkl. optionalem Proxy.
 Autor    : ...
 Version  : ...
 Änderungen:
   YYYY-MM-DD  Name   Beschreibung

 Parameter: (vollständige Liste mit Typ/Default/Pflicht, siehe Abschnitt
             3.2 dieser Spec)

 Rückgabe:
   &sparql_rc, &sparql_msg, &sparql_http_status

 Abhängigkeiten:
   keine (Base SAS 9.4: PROC HTTP)
\*------------------------------------------------------------------------*/
```

Zusätzlich: jeder Validierungsblock und jeder `PROC HTTP`-Aufruf im Code mit
kurzem Inline-Kommentar zum *Warum* (z. B. warum genau ein `ct=`, warum GET
den Query-Text in einem Stück encodiert).

### 6.2 `README.md` — Pflichtinhalt

1. **Nutzung / Quick Start** (ganz am Anfang, siehe Detailanforderungen in
   8.4): Link auf das Release-Asset, Hinweis "nur diese eine Datei nötig",
   Minimalbeispiel mit `%include` + `%sparqlquery(...)`
2. Zweck & Überblick (inkl. Architekturdiagramm aus Abschnitt 3)
3. Zielumgebung: SAS 9.4, serverbasiert, kein lokales SAS auf Client —
   Konsequenzen für Pfade/Proxy (aus Abschnitt 2)
4. Beispiele für alle Kombinationen (POST/Text, POST/Datei, GET/Text,
   GET/Datei) × (XML, JSON) sowie CONSTRUCT/DESCRIBE (Turtle, JSON-LD)
5. Proxy-Konfiguration: Parameter-Variante vs. OS-Umgebungsvariablen
6. Credentials-Handling: `PROC PWENCODE`, `nomprint`-Kapselung
7. Fehlerbehandlung: Tabelle aus Abschnitt 5 + `problemhandling`-Varianten +
   Statusvariablen aus Abschnitt 4
8. Parallelitäts-/Tempfile-Hinweis (Abschnitt 2.2)
9. Grenzen/bekannte Einschränkungen: (a) GET trägt die gesamte Query in die
   URL → serverseitiges URL-Längenlimit, für grosse Queries POST nutzen;
   (b) WLATIN1-Session: Zeichen ausserhalb WLATIN1 gehen beim Transcodieren
   verloren — für volle Unicode-Treue UTF-8-Session; (c) `query=` unterliegt
   Makro-Quoting/~64 K-Grenze → `queryfile=` bevorzugen.
10. **Entwicklung** (siehe 8.4): Quelle in `macros/`, Build-Skript lokal
    ausführen, Tests aus `tests/` — klar getrennt vom Nutzungsabschnitt
11. Changelog

### 6.3 Teststrategie (kein Live-Endpunkt vorhanden)

- `tests/fixtures/`: vorbereitete Beispiel-Responses (SELECT als XML *und*
  JSON, ASK als XML *und* JSON, CONSTRUCT als Turtle **und JSON-LD**) — synthetisch erstellt,
  keine Abhängigkeit von einem echten Server.
- `%sparql_parse_response` wird **direkt** gegen die Fixtures getestet
  (kein HTTP nötig) — Abnahmekriterium: XML- und JSON-Fixture desselben
  SELECT-Ergebnisses führen zu identischem `resultdsn`-Inhalt.
- `%sparql_execute` und `%sparqlquery` werden mit `debug_nohttp=Y` getestet,
  um die Aufrufkette (Parametervalidierung, Statushandling,
  Tempfile-Erzeugung) ohne echten Netzwerkzugriff zu prüfen.
  `debug_nohttp=Y` baut dabei die GET-URL (`urlencode()`) bzw. den
  POST-Fileref ganz normal auf und überspringt nur den eigentlichen
  `PROC HTTP`-Aufruf (Spec 3.4/3.2) — ein `method=GET`-Testfall (T3b) deckt
  damit auch Compile-/Laufzeitfehler in der GET-URL-Vorbereitung ohne
  Netzwerkzugriff ab.
- Ein Test für Parallelität: zwei simulierte gleichzeitige Aufrufe (z. B.
  zwei Makroaufrufe kurz nacheinander in derselben Session) müssen
  unterschiedliche, nicht kollidierende Tempfile-Namen erzeugen (Abschnitt
  2.2) — als expliziter Testfall zusätzlich mit tatsächlich parallelen
  Server-Sessions verifizieren.
- **Live-Endpunkt-Tests** (`tests/test_live_wikidata.sas`, seit 2026-09-16):
  gegen den echten, öffentlichen Wikidata-SPARQL-Endpunkt, ergänzend zu den
  endpunktunabhängigen Fixture-Tests oben. Deckt ab, was mit Fixtures
  strukturell nicht prüfbar ist: den tatsächlichen `PROC HTTP`-Datentransfer
  (POST-Body, GET-URL) gegen einen echten Server, inkl. HTTP-Statuscode-Pfad
  (V8). Ersetzt den ursprünglich als Fuseki-Test geplanten Punkt.

---

## 7. Nicht-funktionale Anforderungen

- Keine Abhängigkeit von SAS/ACCESS-Produkten über Base SAS 9.4 hinaus
  (XML- und JSON-Libname-Engine sind Bestandteil von Base SAS).
- Keine Credentials im Log bei Standardaufruf: `PROC HTTP`-Aufrufe in
  `%sparql_execute` lokal mit `options nomprint nomlogic nosymbolgen`
  umschliessen und danach den ursprünglichen Zustand wiederherstellen (via
  `%sysfunc(getoption(...))`), statt sich nur auf globale Optionen des
  Aufrufers zu verlassen. (Sonst kann `&webpassword`/`&proxypassword` bei
  aktivem `mprint`/`symbolgen`/`mlogic` im Log erscheinen.)
- Alle Filerefs/Tempdateien eindeutig pro Aufruf (Abschnitt 2.2) — wichtig,
  da Server parallel von mehreren Sessions genutzt wird.

## 8. Distribution (öffentliches GitHub-Repo)

### 8.1 Grundprinzip

- **Quelle** (`macros/*.sas`, vier Dateien) ist der einzige Ort, an dem
  entwickelt/reviewt wird.
- **Bundle** (`sparqlquery_bundle.sas`) ist ein **Build-Artefakt**: nie von
  Hand bearbeitet, nie in die normale Commit-Historie eingecheckt
  (`.gitignore`), sondern automatisiert erzeugt und **als Release-Asset**
  an ein Git-Tag angehängt.
- Externe Nutzer beziehen ausschliesslich das Release-Asset — kein
  Git-Checkout, kein Build-Tooling, keine Kenntnis der internen
  Makro-Aufteilung nötig.

### 8.2 GitHub-Actions-Workflow (verbindliche Eckpunkte)

Datei: `.github/workflows/build-bundle.yml`

- **Trigger:** Push eines Tags nach dem Muster `v*.*.*` (z. B. `v1.2.0`) —
  kein Build bei jedem gewöhnlichen Commit/PR, sondern nur bei Releases.
- **Schritte:**
  1. `actions/checkout`
  2. Build-Skript ausführen (einfaches Shell- oder Python-Skript im Repo,
     z. B. `scripts/build_bundle.sh`), das die vier Dateien aus `macros/`
     in fester Reihenfolge konkateniert:
     `sparql_build_request.sas` → `sparql_execute.sas` →
     `sparql_parse_response.sas` → `sparqlquery.sas`
     (Reihenfolge zwingend, da `%sparqlquery` die anderen drei per
     Autocall/Include-Mechanismus im Bundle voraussetzt).
  3. Bundle-Header automatisch einfügen: Versionsnummer aus dem Tag
     (`${{ github.ref_name }}`), Erstellungsdatum, Kurz-Commit-Hash
     (`${{ github.sha }}`).
  4. Release erstellen bzw. das bestehende Tag-Release ergänzen (z. B. via
     `softprops/action-gh-release` oder `gh release upload`) und
     `sparqlquery_bundle.sas` als Asset anhängen.
- **Kein separater Lauf für Pull Requests** nötig — Bundle-Erzeugung ist ein
  Release-Vorgang, nicht Teil der normalen CI (Tests aus Abschnitt 6.3
  laufen unabhängig davon bei jedem PR).

### 8.3 `.gitignore`

```
sparqlquery_bundle.sas
dist/
```

### 8.4 README-Anforderung: Eindeutigkeit für externe Nutzer

Da das Repo offen ist und sowohl `macros/*.sas` als auch das Bundle
sichtbar/erreichbar sind, muss die README **unmissverständlich** klarstellen,
welches File für eine tatsächliche Abfrage zu verwenden ist. Konkret muss
die README enthalten:

- Ein eigener, klar abgegrenzter Abschnitt **"Nutzung" / "Quick Start"**
  ganz am Anfang, der ausschliesslich beschreibt:
  - Wo das Bundle zu finden ist (Link auf die
    [Releases-Seite](../../releases) bzw. direkt auf das neueste Release-Asset)
  - Dass **nur diese eine Datei** benötigt wird
  - Ein Minimalbeispiel: Datei herunterladen, `%include
    "pfad/zu/sparqlquery_bundle.sas";`, danach `%sparqlquery(...)` aufrufen
- Ein expliziter Hinweis-Satz, dass der `macros/`-Ordner **Quellcode für die
  Entwicklung** ist und **nicht** einzeln includiert werden soll/muss —
  um zu verhindern, dass jemand versehentlich nur eines der vier Makros lädt
  und dann `%sparqlquery` fehlschlägt, weil z. B. `%sparql_execute`
  unbekannt ist.
- Ein separater, später folgender Abschnitt **"Entwicklung"** für Leute, die
  am Paket selbst mitarbeiten wollen (Quelle in `macros/`, Build-Skript
  lokal ausführen, Tests aus `tests/`).

## 9. Offene Fragen

Umfeld-Entscheide fixiert: `resultdsn` = **langes/tidy-Schema** (Abschnitt
3.3); Zielserver **9.4M4+**; Session-Encoding **WLATIN1** → Antworten werden
UTF-8-gelesen; Proxy-Auth via `PROXYUSERNAME=`/`PROXYPASSWORD=` (ab 9.4M4).
Micro-Defaults: ungebundene Variablen → keine Zeile; ASK → 1-Zeilen-`boolean`-
Dataset. Alle geklärten Punkte sind in die Parameter- und
Validierungsdefinitionen (Abschnitte 3 und 5) eingeflossen.

**Server-Verifikation (2026-09-15, SAS 9.4M4 gegen die Fixtures aus 6.3)
abgeschlossen — T0–T4 alle [PASS].** Dabei geklärt:
- XML-Automap scheitert (s. Korrektur in 2.1); explizite XML-Map + Entfernen
  des Default-Namespace ist der tragfähige Weg.
- `ridx` bei XML kommt nicht aus der Map, sondern aus einer Gruppenwechsel-
  Erkennung im DATA-Step (SPARQL bindet eine Variable nie zweimal im selben
  `<result>`).
- JSON-Automap legt pro SPARQL-Variable ein eigenes Member
  `BINDINGS_<UPPERCASE(Variable)>` an; die korrekte Schreibweise der Variable
  steht in Member `HEAD_VARS`.
- `resultdsn` wird bei SELECT nach `ridx`/`var` sortiert, damit XML- und
  JSON-Pfad trotz unterschiedlicher natürlicher Zeilenreihenfolge dasselbe
  Ergebnis für `PROC COMPARE` liefern.

**Live-Server-Verifikation (2026-09-16, gegen den echten Wikidata-SPARQL-
Endpunkt `https://query.wikidata.org/sparql`, `tests/test_live_wikidata.sas`)
abgeschlossen — alle sieben Fälle [PASS]:** SELECT über alle vier
Methode×Format-Kombinationen (POST/GET × XML/JSON, alle vier liefern
nachweislich identisches `resultdsn`), ASK, CONSTRUCT (Turtle und JSON-LD).
Dabei geklärt:
- `PROC HTTP`s `in=`-Option mit einem `recfm=n`-Fileref hat den POST-Query-
  Text kurz vor Ende abgeschnitten (Query kam beim Server unvollständig an),
  obwohl die Quelldatei nachweislich vollständig war. Fix: Query-Text vor
  `PROC HTTP` in einen normalen (nicht `recfm=n`) Fileref kopieren.
- `_u $65534` in der GET/`urlencode()`-Logik überschritt das SAS-Maximum für
  Zeichenvariablen (32767) — Compile-Fehler, nie zuvor getestet, da
  `debug_nohttp=Y` diesen Codepfad übersprang. Auf `$32767` korrigiert.
- Manche öffentlichen Endpunkte (Wikidata/WDQS) drosseln/blocken Clients
  ohne aussagekräftigen `User-Agent` — neuer Parameter `useragent=`.
- `PROXYUSERNAME=`/`PROXYPASSWORD=` funktionieren wie in 2.1 angenommen.
- Damit ist die GET/`urlencode()`-VERIFY-Markierung in `sparql_execute.sas`
  aufgelöst.

---

*Diese Spec ist granular genug für "spec-driven development": jedes Makro
(Abschnitt 3.1–3.4) ist als eigenes Ticket umsetzbar, mit klaren
Ein-/Ausgaben, Validierungsregeln (Abschnitt 5), Statuskonzept (Abschnitt 4)
und Dokumentationspflicht (Abschnitt 6) — unabhängig von den anderen.*
