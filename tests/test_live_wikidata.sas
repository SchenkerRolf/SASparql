/*------------------------------------------------------------------------*\
 Test    : test_live_wikidata
 Zweck   : Verifikation gegen einen ECHTEN, oeffentlichen SPARQL-Endpunkt
           (Wikidata Query Service), ergaenzend zu den fixture-basierten
           Tests in test_sparqlquery.sas (die bewusst endpunktunabhaengig
           bleiben, Spec 6.3). Deckt ab, was mit Fixtures nicht pruefbar
           ist: echtes HTTP (PROC HTTP), GET/urlencode() gegen einen
           realen Server, echte SPARQL-Results-XML/JSON von einer dritten
           Implementierung (nicht unsere eigenen Fixtures).

 Ausfuehren:
   1. %let repo_root = <Pfad zum ausgecheckten Repo>;
   2. Falls der SAS-Server einen Proxy fuer ausgehendes HTTPS braucht:
      %let proxyhost=...; %let proxyport=...; unten setzen (sonst leer
      lassen - dann greifen OS-Umgebungsvariablen/kein Proxy, Spec 2).
      Diese Datei nutzt bewusst kein mlogic/symbolgen (s.u.), Proxy-Werte
      landen also nicht im Log - trotzdem gilt: Log vor dem Teilen kurz
      durchsehen, falls hier lokal weitere sensible Werte ergaenzt werden.
   3. Dieses Programm submitten. Braucht Internetzugang vom SAS-Server aus.

 Hinweis: Wikidata verlangt/erwartet einen aussagekraeftigen User-Agent
   (WDQS-Nutzungsrichtlinie) - sparql_execute.sas setzt seit Version 0.3.0
   einen Default (useragent=), hier bei Bedarf mit Kontaktinfo ueberschreiben.

 Assertion-Konvention (wichtig): %_assert() bekommt NUR eine bereits
   fertig berechnete 0/1-Bedingung und ein rein statisches Label - NIE
   einen rohen Vergleich ("&x = 0 and ...") oder ein Label mit &-Werten
   direkt als Makroaufruf-Argument. Grund (server-verifiziert 2026-09-16):
   SAS interpretiert aufgeloesten Text der Form "0 = 0 and ..." innerhalb
   eines Makroaufruf-Arguments teils als Versuch eines Keyword-Parameters
   ("ERROR: Invalid macro parameter name 0.") - auch mit Leerzeichen um das
   "=". Deshalb: Bedingungen vorher per %let/%eval (bzw. bei Zeichenketten-
   vergleichen per offenem %if) in eine 0/1-Variable giessen, dynamische
   Werte separat per %put ausgeben (dort ist es unkritisch, %put ist kein
   Aufruf eines Makros mit Parametern).

 Query-Wahl: kleine, stabile Wikidata-Entitaet (wd:Q42 = Douglas Adams) mit
   engen LIMITs, um den oeffentlichen Dienst nicht zu belasten.

 Hinweis Sprachfilter (2026-09-16 per curl direkt gegen Wikidata verifiziert,
   unabhaengig von SAS/Proxy/User-Agent): Wikidata dedupliziert Labels, die
   sprachunabhaengig sind (z. B. Eigennamen wie "Douglas Adams"), unter dem
   Sprachcode "mul" statt sie zusaetzlich unter "en" zu duplizieren - ein
   Filter auf lang(?label) = "en" allein liefert fuer Q42 daher 0 Zeilen
   (kein Bug, echtes aktuelles Wikidata-Datenmodell). Deshalb "en" ODER
   "mul" filtern.
\*------------------------------------------------------------------------*/

/* --- Konfiguration -------------------------------------------------- */
%let repo_root = \\szh.loc\ssz\git\sszscr\SASparql;
%let macros    = &repo_root./macros;
%let endpoint  = https://query.wikidata.org/sparql;

/* Nur setzen, falls der SAS-Server einen Proxy fuer HTTPS braucht: */
%let proxyhost = ;
%let proxyport = ;
/* Nur setzen, falls der Proxy Authentifizierung verlangt (HTTP 407 sonst):
   proxypassword idealerweise mit PROC PWENCODE verschluesseln (Spec/README
   "Credentials-Handling"). Landet dank fehlendem mlogic/symbolgen (s.u.)
   nicht im Log. */
%let proxyuser     = ;
%let proxypassword = ;

/* Kontaktinfo ergaenzen, falls verfuegbar (WDQS-Empfehlung, nicht Pflicht). */
%let ua = SASparql-SAS-Macro/0.4.0 (verification test run);

/* Bewusst OHNE mlogic/symbolgen (anders als tests/test_sparqlquery.sas):
   beides wuerde Parameterwerte bzw. aufgeloeste Makrovariablen ins Log
   schreiben - u.a. proxyhost=/proxyport=, BEVOR der interne
   nomprint/nosymbolgen-Schutz in sparql_execute.sas (Spec 7) greift, der
   nur den eigentlichen PROC HTTP-Aufruf selbst abschirmt. mprint bleibt
   fuer die Fehlersuche drin - das ist von diesem Schutz nicht betroffen. */
options source source2 notes msglevel=i
    mprint mprintnest;

/* --- Makros laden (Quelle, nicht Bundle) ---------------------------- */
%include "&macros./sparql_build_request.sas";
%include "&macros./sparql_execute.sas";
%include "&macros./sparql_parse_response.sas";
%include "&macros./sparqlquery.sas";

/* --- kleine Assertion-Hilfen ----------------------------------------- */
%macro _assert(cond, label);
  %if (&cond) %then
    %put NOTE: [PASS] &label;
  %else
    %put ERROR: [FAIL] &label;
%mend _assert;

%macro _nobs(ds);
  %local _dsid _n;
  %let _dsid = %sysfunc(open(&ds));
  %let _n = %sysfunc(attrn(&_dsid, nobs));
  %let _dsid = %sysfunc(close(&_dsid));
  &_n
%mend _nobs;

/* Setzt &outvar (global) auf 1, wenn &path existiert und mindestens eine
   Zeile Inhalt hat, sonst 0. Muss als EIGENSTAENDIGE Anweisung im offenen
   Code aufgerufen werden (nicht in %let/%eval() verschachtelt) - der
   enthaltene DATA-Step laesst sich nicht als "Rueckgabewert" einer
   Ausdrucksposition einbetten (server-verifiziert: "ERROR 180-322:
   Statement is not valid ...", 2026-09-16). */
%macro _nonempty(path, outvar);
  %global &outvar;
  %let &outvar = 0;
  %if (%sysfunc(fileexist(&path))) %then %do;
    data _null_;
      infile "&path";
      input;
      call symputx("&outvar", 1, 'G');
      stop;
    run;
  %end;
%mend _nonempty;

/* Rohinhalt einer Datei ins Log dumpen (Diagnose bei unerwartetem Ergebnis). */
%macro _dumpfile(path, tag);
  %if (%sysfunc(fileexist(&path))) %then %do;
    data _null_;
      infile "&path" encoding="utf-8" lrecl=32767;
      input;
      put "&tag: " _infile_;
    run;
  %end;
  %else %put NOTE: &tag: Datei &path existiert nicht (evtl. schon aufgeraeumt).;
%mend _dumpfile;

/* ==================================================================== *
 * L1  SELECT, POST, XML (Default) - Label von wd:Q42 (Douglas Adams)
 * ==================================================================== */
%sparqlquery(
    endpoint=&endpoint,
    query=%nrstr(SELECT ?label WHERE {
      wd:Q42 rdfs:label ?label . FILTER(lang(?label) = "en" || lang(?label) = "mul")
    }),
    queryform=SELECT, resultformat=XML, method=POST,
    proxyhost=&proxyhost, proxyport=&proxyport,
    proxyuser=&proxyuser, proxypassword=&proxypassword, useragent=&ua,
    timeout=90, resultdsn=work.wd_l1, showresponse=N,
    debug=Y, problemhandling=RETURN);

%let _ok1a = %eval(&sparql_rc = 0 and &sparql_http_status >= 200 and &sparql_http_status <= 299);
%_assert(&_ok1a, L1 POST/XML rc und HTTP ok);
%put NOTE: L1 Detail - rc=&sparql_rc http=&sparql_http_status;

%let _n1 = %_nobs(work.wd_l1);
%let _ok1b = %eval(&_n1 > 0);
%_assert(&_ok1b, L1 POST/XML liefert mind. 1 Zeile);
%put NOTE: L1 Detail - nobs=&_n1;

/* DIAGNOSE: bei 0 Zeilen die rohe Server-Antwort zeigen (Query-Text war
   bereits server-verifiziert korrekt und vollstaendig - 2026-09-16). */
%if (&_n1 = 0) %then %do;
  %_dumpfile(%sysfunc(pathname(work))/&sparql_last_stem..out, DIAGNOSE RAW L1);
%end;

/* ==================================================================== *
 * L2  SELECT, POST, JSON - dieselbe Query, anderes Ergebnisformat
 * ==================================================================== */
%sparqlquery(
    endpoint=&endpoint,
    query=%nrstr(SELECT ?label WHERE {
      wd:Q42 rdfs:label ?label . FILTER(lang(?label) = "en" || lang(?label) = "mul")
    }),
    queryform=SELECT, resultformat=JSON, method=POST,
    proxyhost=&proxyhost, proxyport=&proxyport,
    proxyuser=&proxyuser, proxypassword=&proxypassword, useragent=&ua,
    timeout=90, resultdsn=work.wd_l2, showresponse=N,
    problemhandling=RETURN);

%let _ok2a = %eval(&sparql_rc = 0 and &sparql_http_status >= 200 and &sparql_http_status <= 299);
%_assert(&_ok2a, L2 POST/JSON rc und HTTP ok);
%put NOTE: L2 Detail - rc=&sparql_rc http=&sparql_http_status;

%let _n2 = %_nobs(work.wd_l2);
%let _ok2b = %eval(&_n2 > 0);
%_assert(&_ok2b, L2 POST/JSON liefert mind. 1 Zeile);
%put NOTE: L2 Detail - nobs=&_n2;

proc compare base=work.wd_l1 compare=work.wd_l2 noprint; run;
%let _ok2c = %eval(&sysinfo = 0);
%_assert(&_ok2c, L1 und L2 POST XML und JSON liefern identisches resultdsn);
%put NOTE: L1/L2 Detail - sysinfo=&sysinfo;

/* ==================================================================== *
 * L3  SELECT, GET, XML - prueft urlencode()-Pfad (Spec 3.2, VERIFY)
 * ==================================================================== */
%sparqlquery(
    endpoint=&endpoint,
    query=%nrstr(SELECT ?label WHERE {
      wd:Q42 rdfs:label ?label . FILTER(lang(?label) = "en" || lang(?label) = "mul")
    }),
    queryform=SELECT, resultformat=XML, method=GET,
    proxyhost=&proxyhost, proxyport=&proxyport,
    proxyuser=&proxyuser, proxypassword=&proxypassword, useragent=&ua,
    timeout=90, resultdsn=work.wd_l3, showresponse=N,
    debug=Y, problemhandling=RETURN);

%let _ok3a = %eval(&sparql_rc = 0 and &sparql_http_status >= 200 and &sparql_http_status <= 299);
%_assert(&_ok3a, L3 GET/XML rc und HTTP ok);
%put NOTE: L3 Detail - rc=&sparql_rc http=&sparql_http_status;

%let _n3 = %_nobs(work.wd_l3);
%if (&_n3 = 0) %then %do;
  %_dumpfile(%sysfunc(pathname(work))/&sparql_last_stem..out, DIAGNOSE RAW L3);
%end;

proc compare base=work.wd_l1 compare=work.wd_l3 noprint; run;
%let _ok3b = %eval(&sysinfo = 0);
%_assert(&_ok3b, L1 und L3 POST und GET liefern identisches resultdsn);
%put NOTE: L1/L3 Detail - sysinfo=&sysinfo;

/* ==================================================================== *
 * L4  SELECT, GET, JSON
 * ==================================================================== */
%sparqlquery(
    endpoint=&endpoint,
    query=%nrstr(SELECT ?label WHERE {
      wd:Q42 rdfs:label ?label . FILTER(lang(?label) = "en" || lang(?label) = "mul")
    }),
    queryform=SELECT, resultformat=JSON, method=GET,
    proxyhost=&proxyhost, proxyport=&proxyport,
    proxyuser=&proxyuser, proxypassword=&proxypassword, useragent=&ua,
    timeout=90, resultdsn=work.wd_l4, showresponse=N,
    problemhandling=RETURN);

%let _ok4a = %eval(&sparql_rc = 0 and &sparql_http_status >= 200 and &sparql_http_status <= 299);
%_assert(&_ok4a, L4 GET/JSON rc und HTTP ok);
%put NOTE: L4 Detail - rc=&sparql_rc http=&sparql_http_status;

proc compare base=work.wd_l1 compare=work.wd_l4 noprint; run;
%let _ok4b = %eval(&sysinfo = 0);
%_assert(&_ok4b, L1 und L4 alle vier Methode/Format-Kombinationen identisch);
%put NOTE: L1/L4 Detail - sysinfo=&sysinfo;

/* ==================================================================== *
 * L5  ASK, POST - Douglas Adams ist ein Mensch (wdt:P31 wd:Q5)
 * ==================================================================== */
%sparqlquery(
    endpoint=&endpoint,
    query=%nrstr(ASK { wd:Q42 wdt:P31 wd:Q5 }),
    queryform=ASK, resultformat=XML, method=POST,
    proxyhost=&proxyhost, proxyport=&proxyport,
    proxyuser=&proxyuser, proxypassword=&proxypassword, useragent=&ua,
    timeout=90, resultdsn=work.wd_ask, showresponse=N,
    problemhandling=RETURN);

%let _ok5a = %eval(&sparql_rc = 0 and &sparql_http_status >= 200 and &sparql_http_status <= 299);
%_assert(&_ok5a, L5 ASK rc und HTTP ok);
%put NOTE: L5 Detail - rc=&sparql_rc http=&sparql_http_status;

%let _askval = (leer);
data _null_;
  set work.wd_ask;
  call symputx('_askval', boolean, 'G');
run;
%if (&_askval = true) %then %do;
  %let _ok5b = 1;
%end;
%else %do;
  %let _ok5b = 0;
%end;
%_assert(&_ok5b, L5 ASK boolean ist true - Douglas Adams ist Q5);
%put NOTE: L5 Detail - askval=&_askval;

/* ==================================================================== *
 * L6  CONSTRUCT, POST, TURTLE - kleines, LIMIT-begrenztes Graph-Fragment
 * ==================================================================== */
%let _ttlpath = %sysfunc(pathname(work))/wd_construct.ttl;
%sparqlquery(
    endpoint=&endpoint,
    query=%nrstr(CONSTRUCT { wd:Q42 rdfs:label ?label }
                 WHERE { wd:Q42 rdfs:label ?label } LIMIT 5),
    queryform=CONSTRUCT, resultformat=TURTLE, method=POST,
    proxyhost=&proxyhost, proxyport=&proxyport,
    proxyuser=&proxyuser, proxypassword=&proxypassword, useragent=&ua,
    timeout=90, resultfile=&_ttlpath, showresponse=N,
    problemhandling=RETURN);

%let _ok6a = %eval(&sparql_rc = 0 and &sparql_http_status >= 200 and &sparql_http_status <= 299);
%_assert(&_ok6a, L6 CONSTRUCT/TURTLE rc und HTTP ok);
%put NOTE: L6 Detail - rc=&sparql_rc http=&sparql_http_status;

%_nonempty(&_ttlpath, _ok6b);
%_assert(&_ok6b, L6 CONSTRUCT/TURTLE-Datei existiert und ist nicht leer);

/* ==================================================================== *
 * L7  CONSTRUCT, POST, JSON-LD - gleiche Query, anderes RDF-Format
 * ==================================================================== */
%let _jldpath = %sysfunc(pathname(work))/wd_construct.jsonld;
%sparqlquery(
    endpoint=&endpoint,
    query=%nrstr(CONSTRUCT { wd:Q42 rdfs:label ?label }
                 WHERE { wd:Q42 rdfs:label ?label } LIMIT 5),
    queryform=CONSTRUCT, resultformat=JSONLD, method=POST,
    proxyhost=&proxyhost, proxyport=&proxyport,
    proxyuser=&proxyuser, proxypassword=&proxypassword, useragent=&ua,
    timeout=90, resultfile=&_jldpath, showresponse=N,
    problemhandling=RETURN);

%let _ok7a = %eval(&sparql_rc = 0 and &sparql_http_status >= 200 and &sparql_http_status <= 299);
%_assert(&_ok7a, L7 CONSTRUCT/JSONLD rc und HTTP ok);
%put NOTE: L7 Detail - rc=&sparql_rc http=&sparql_http_status;

%_nonempty(&_jldpath, _ok7b);
%_assert(&_ok7b, L7 CONSTRUCT/JSONLD-Datei existiert und ist nicht leer);

%put NOTE: test_live_wikidata durchlaufen (siehe [PASS]/[FAIL] oben).;
