# SASparql

SAS-Makropaket, das SPARQL-Abfragen gegen einen HTTP(S)-Endpunkt ausführt und
das Ergebnis als SAS-Dataset (SELECT/ASK) bzw. als RDF-Datei
(CONSTRUCT/DESCRIBE) bereitstellt.

> **Status:** In Entwicklung. Alle vier Makros sind implementiert und gegen
> eine laufende SAS-9.4M4-Instanz mit den fixture-basierten Tests aus
> [`tests/`](tests/) verifiziert (2026-09-15, T0–T4 alle [PASS]). Noch offen:
> Verifikation gegen einen echten SPARQL-Endpunkt (GET/Proxy-Optionen).
> Verbindliche Spezifikation: [`spec-sparql-sas.md`](spec-sparql-sas.md).

---

## Nutzung / Quick Start

Für eine tatsächliche Abfrage wird **nur eine einzige Datei** benötigt:
`sparqlquery_bundle.sas`.

1. Neuestes Bundle von der **[Releases-Seite](../../releases)** herunterladen
   (Asset `sparqlquery_bundle.sas`).
2. In der SAS-Session einbinden und aufrufen:

```sas
%include "pfad/zu/sparqlquery_bundle.sas";

%sparqlquery(
    endpoint = https://dbpedia.org/sparql,
    query    = %nrstr(SELECT ?s WHERE { ?s a ?type } LIMIT 10),
    resultdsn= work.result
);
```

> **Wichtig:** Der Ordner [`macros/`](macros/) enthält **Quellcode für die
> Entwicklung** und darf **nicht** einzeln includiert werden. Wer nur eines
> der vier Makros lädt, bekommt einen Fehler (z. B. `%sparql_execute`
> unbekannt). Für die Nutzung ausschliesslich das Bundle verwenden.

---

## Zweck & Überblick

Vier Makros, genau ein `PROC HTTP`-Aufruf:

```
%sparqlquery                  (Orchestrator, öffentliche API)
   ├─ %sparql_build_request   (Query-Text vereinheitlichen)
   ├─ %sparql_execute         (einziger PROC HTTP-Aufruf)
   └─ %sparql_parse_response  (XML/JSON → Dataset, oder RDF-Datei durchreichen)
```

Orthogonal kombinierbar: Query-Quelle (`query=`/`queryfile=`), HTTP-Methode
(`POST`/`GET`), Ergebnisform (`SELECT`/`ASK`/`CONSTRUCT`/`DESCRIBE`),
Ergebnisformat (SELECT/ASK: `XML`/`JSON`; CONSTRUCT/DESCRIBE: `TURTLE`/`JSONLD`)
sowie optionaler Proxy.

---

## Zielumgebung

- **SAS 9.4M4+**, ausgeführt **auf einem SAS-Server** (Clients wie SAS
  Enterprise Guide haben kein lokales SAS).
- Konsequenzen: temporäre Dateien liegen unter `%sysfunc(pathname(work))`;
  Proxy/Netzwerk gilt **serverseitig**; mehrere Sessions können das Paket
  **parallel** aufrufen → eindeutige Tempnamen per Default.
- **Session-Encoding WLATIN1:** Antworten sind UTF-8 und werden explizit als
  UTF-8 gelesen. Zeichen ausserhalb WLATIN1 können beim Landen im SAS-Dataset
  verloren gehen (siehe *Grenzen*).

---

## Beispiele

`method=` (POST/GET), Query-Quelle (`query=`/`queryfile=`) und `resultformat=`
sind frei kombinierbar. `method=POST` und — bei SELECT/ASK — `resultformat=XML`
sind Default; unten sind sie zur Klarheit teils explizit gesetzt.

```sas
/* ---- SELECT: die vier Methode x Quelle-Kombinationen ------------------ */

/* POST + Text (resultformat=XML ist Default) */
%sparqlquery(endpoint=https://example.org/sparql,
             query=%nrstr(SELECT ?s ?p ?o WHERE { ?s ?p ?o } LIMIT 5),
             resultdsn=work.triples);

/* POST + Datei, JSON */
%sparqlquery(endpoint=https://example.org/sparql,
             queryfile=/pfad/query.rq,
             resultformat=JSON, resultdsn=work.triples);

/* GET + Text, XML */
%sparqlquery(endpoint=https://example.org/sparql,
             query=%nrstr(SELECT ?s WHERE { ?s a ?t } LIMIT 5),
             method=GET, resultformat=XML, resultdsn=work.triples);

/* GET + Datei, JSON */
%sparqlquery(endpoint=https://example.org/sparql,
             queryfile=/pfad/query.rq,
             method=GET, resultformat=JSON, resultdsn=work.triples);

/* ---- ASK -------------------------------------------------------------- */
%sparqlquery(endpoint=https://example.org/sparql,
             query=%nrstr(ASK { ?s a ?t }),
             queryform=ASK, resultdsn=work.answer);

/* ---- CONSTRUCT / DESCRIBE -> RDF-Datei -------------------------------- */
/* CONSTRUCT als Turtle */
%sparqlquery(endpoint=https://example.org/sparql,
             queryfile=/pfad/construct.rq,
             queryform=CONSTRUCT, resultformat=TURTLE,
             resultfile=/pfad/out.ttl);

/* CONSTRUCT als JSON-LD */
%sparqlquery(endpoint=https://example.org/sparql,
             queryfile=/pfad/construct.rq,
             queryform=CONSTRUCT, resultformat=JSONLD,
             resultfile=/pfad/out.jsonld);

/* DESCRIBE als Turtle */
%sparqlquery(endpoint=https://example.org/sparql,
             query=%nrstr(DESCRIBE <http://example.org/alice>),
             queryform=DESCRIBE, resultformat=TURTLE,
             resultfile=/pfad/alice.ttl);
```

**SELECT-Ergebnisschema (tidy, identisch für XML und JSON):**

| Spalte | Typ | Inhalt |
|---|---|---|
| `ridx` | num | 1-basierter Ergebnis-Index |
| `var` | char | SPARQL-Variablenname |
| `value` | char | Wert als Text |
| `type` | char | `uri` / `literal` / `bnode` |
| `datatype` | char | Datatype-IRI bei typisierten Literalen |
| `lang` | char | Sprach-Tag bei Sprach-Literalen |

Ungebundene Variablen erzeugen keine Zeile. **ASK** liefert ein 1-Zeilen-Dataset
mit Char-Spalte `boolean` ∈ {`true`,`false`}.

Das tidy-Format lässt sich bei Bedarf in eine breite Tabelle (eine Spalte je
SPARQL-Variable) überführen:

```sas
proc transpose data=work.triples out=work.wide(drop=_name_);
    by ridx;
    id var;
    var value;
run;
```

---

## Proxy-Konfiguration

Zwei Varianten, unabhängig von der Endpunkt-Authentifizierung:

- **Parameter:** `proxyhost=`, `proxyport=`, `proxyuser=`, `proxypassword=`
  (werden auf `PROC HTTP`-Optionen `PROXYHOST=`/`PROXYPORT=`/
  `PROXYUSERNAME=`/`PROXYPASSWORD=` gemappt, ab 9.4M4).
- **OS-Umgebungsvariablen:** `http_proxy`/`https_proxy` — müssen aus Sicht des
  **SAS-Servers** stimmen. Wird kein `proxyhost=` gesetzt, greift ggf. die
  OS-Konfiguration bzw. kein Proxy.

---

## Credentials-Handling

- `webpassword=`/`proxypassword=` idealerweise mit `PROC PWENCODE` verschlüsselt
  übergeben.
- `%sparql_execute` kapselt den `PROC HTTP`-Aufruf lokal mit
  `options nomprint nomlogic nosymbolgen;` und stellt den Ausgangszustand
  danach wieder her, damit keine Credentials im Log erscheinen.

```sas
/* Passwort einmalig verschluesseln -> {SAS002}...-String im Log */
proc pwencode in="geheim"; run;

/* den erzeugten String uebergeben (nicht das Klartext-Passwort) */
%sparqlquery(endpoint=https://secure.example.org/sparql,
             query=%nrstr(ASK {}), queryform=ASK,
             webuser=alice, webpassword={SAS002}A1B2C3...);
```

---

## Fehlerbehandlung

Globale Status-Makrovariablen:

- `&sparql_rc` — 0 = ok; 1 = Parameterfehler, 2 = HTTP-Fehler, 3 = Parse-Fehler
- `&sparql_msg` — Klartext-Fehlermeldung bei `sparql_rc ≠ 0`
- `&sparql_http_status` — von `%sparql_execute` gesetzt (auch bei Erfolg)

`problemhandling=` steuert das Verhalten bei Verletzungen:

- `ABORTCANCEL` (Default) — `data _null_; abort cancel; run;`
- `RETURN` — `%return` mit gesetztem `&sparql_rc`; der Aufrufer prüft danach
  selbst `&sparql_rc`.

**Validierungsregeln:**

| # | Regel |
|---|-------|
| V1 | genau eine von `query=` / `queryfile=` |
| V2 | `queryfile=` muss existieren |
| V3 | `method=` nur `POST` / `GET` |
| V4 | `endpoint=` beginnt mit `http://` / `https://` |
| V5 | `queryform=` nur `SELECT` / `ASK` / `CONSTRUCT` / `DESCRIBE` |
| V6 | `resultformat=` passt zu `queryform=` (XML/JSON ↔ TURTLE/JSONLD) |
| V7 | `proxyuser=` / `proxypassword=` nur mit gesetztem `proxyhost=` |
| V8 | HTTP-Status muss 2xx sein, sonst **kein** Parsing |
| V9 | `resultdsn=` ein gültiger SAS-Dataset-Name |
| V10 | `resultfile=` Pflicht bei `CONSTRUCT` / `DESCRIBE` |

Bei einer Verletzung: eine `ERROR:`-Zeile mit Makroname und konkretem Problem,
`&sparql_rc ≠ 0`, danach `problemhandling`. Details siehe
[`spec-sparql-sas.md`](spec-sparql-sas.md), Abschnitt 5.

**Beispiel mit `problemhandling=RETURN`** (selbst prüfen statt Abbruch):

```sas
%sparqlquery(endpoint=https://example.org/sparql,
             query=%nrstr(SELECT * WHERE { ?s ?p ?o }),
             resultdsn=work.r, problemhandling=RETURN);

%if (&sparql_rc ne 0) %then %do;
    %put Abfrage fehlgeschlagen: rc=&sparql_rc, HTTP=&sparql_http_status - &sparql_msg;
    /* ... eigene Behandlung, z. B. Fallback oder sauberes Beenden ... */
%end;
```

---

## Parallelität / Temporärdateien

Der Server wird parallel von mehreren Sessions genutzt. Tempnamen sind daher
**standardmässig eindeutig**:
`temp-sparqlquery-&sysuserid.-&sysjobid.-<Zeitstempel>-<Session-Zähler>`
(physischer Dateiname unter `%sysfunc(pathname(work))`; der Fileref selbst ist
ein kurzes, separat generiertes Token ≤ 8 Zeichen). Über `tempnamestem=` lässt
sich ein fester Name für gezieltes Debugging erzwingen.

---

## Grenzen / bekannte Einschränkungen

- **GET**: die gesamte Query steht in der URL → serverseitiges URL-Längenlimit;
  für grosse Queries `POST` verwenden.
- **WLATIN1-Session**: Zeichen ausserhalb WLATIN1 gehen beim Transcodieren
  verloren — für volle Unicode-Treue eine UTF-8-Session nutzen.
- **`query=`**: unterliegt Makro-Quoting (`&`/`%` → `%nrstr(...)`) und der
  ~64 K-Grenze von `symget()` → bei komplexen/langen Queries `queryfile=`
  bevorzugen.

---

## Entwicklung

Nur für Mitarbeit am Paket selbst (nicht für die Nutzung nötig):

- **Quelle:** [`macros/`](macros/) — die vier Makros werden hier
  entwickelt/reviewt.
- **Tests:** [`tests/`](tests/) — fixture-basiert, ohne Live-Endpunkt
  (`tests/fixtures/`, `tests/test_sparqlquery.sas`).
- **Bundle bauen (lokal):**
  ```bash
  scripts/build_bundle.sh v0.0.0-dev "$(git rev-parse --short HEAD)"
  ```
  Das erzeugte `sparqlquery_bundle.sas` ist ein Build-Artefakt
  (`.gitignore`), wird nie eingecheckt und bei einem Tag `v*.*.*` automatisch
  vom Workflow [`build-bundle.yml`](.github/workflows/build-bundle.yml) als
  Release-Asset angehängt.

---

## Changelog

- **Unreleased** — Repo-Struktur, Spec, Fixtures, Build-Infrastruktur;
  Implementierung aller vier Makros (build_request, execute, parse_response,
  sparqlquery) inkl. Test-Harness T0–T4. Server-verifiziert gegen SAS 9.4M4
  (2026-09-15): XML-Parsing auf explizite XML-Map umgestellt (Automap
  scheitert an der SPARQL-Results-Struktur), JSON-Parsing an die tatsächliche
  Automap-Struktur angepasst (ein Member je SPARQL-Variable).
