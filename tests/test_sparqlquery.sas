/*------------------------------------------------------------------------*\
 Test    : test_sparqlquery
 Zweck   : Fixture-basierte Tests ohne Live-Endpunkt (Spec 6.3).
 Ausfuehren:
   1. %let repo_root = <Pfad zum ausgecheckten Repo>;
   2. Dieses Programm submitten.
 Hinweis : Geruest — die eigentlichen Assertions sind als TODO markiert.
\*------------------------------------------------------------------------*/

/* --- Konfiguration -------------------------------------------------- */
%let repo_root = %sysfunc(pathname(work));   /* TODO: auf Repo-Root setzen */
%let macros    = &repo_root./macros;
%let fixtures  = &repo_root./tests/fixtures;

/* --- Makros laden (Quelle, nicht Bundle) ---------------------------- */
%include "&macros./sparql_build_request.sas";
%include "&macros./sparql_execute.sas";
%include "&macros./sparql_parse_response.sas";
%include "&macros./sparqlquery.sas";

/* --- kleine Assertion-Hilfe ----------------------------------------- */
%macro _assert_rc(label, expect);
  %if (&sparql_rc = &expect) %then
    %put NOTE: [PASS] &label (rc=&sparql_rc);
  %else
    %put ERROR: [FAIL] &label - erwartet rc=&expect, erhalten rc=&sparql_rc;
%mend _assert_rc;

/* ==================================================================== *
 * T0  sparql_build_request (Spec 3.1) - Validierung V1/V2 + Schreibpfade
 * ==================================================================== */
/* out-Fileref wie im Orchestrator vorgesehen: recfm=n + UTF-8 */
filename qout "%sysfunc(pathname(work))/t0_query.rq" recfm=n encoding="utf-8";

/* T0a: query= (Text) -> schreibt, rc=0 */
%sparql_build_request(query=%nrstr(SELECT ?s WHERE { ?s ?p ?o } LIMIT 1),
                      out_fileref=qout);
%_assert_rc(T0a query-Text schreibt, 0);

/* T0b: queryfile= (Ganzdatei-Kopie) -> rc=0 */
filename qin "%sysfunc(pathname(work))/t0_in.rq" recfm=n encoding="utf-8";
data _null_;
  file qin;
  put 'ASK { ?s ?p ?o }';
run;
%sparql_build_request(queryfile=%sysfunc(pathname(qin)), out_fileref=qout);
%_assert_rc(T0b queryfile kopiert, 0);

/* T0c: V1 - keine Quelle -> rc=1 */
%sparql_build_request(out_fileref=qout);
%_assert_rc(T0c V1 keine Quelle, 1);

/* T0d: V1 - beide Quellen -> rc=1 (greift vor V2; Datei muss nicht da sein) */
%sparql_build_request(query=%nrstr(ASK{}), queryfile=/x, out_fileref=qout);
%_assert_rc(T0d V1 beide Quellen, 1);

/* T0e: V2 - queryfile existiert nicht -> rc=1 */
%sparql_build_request(queryfile=/pfad/gibt/es/nicht.rq, out_fileref=qout);
%_assert_rc(T0e V2 fehlende Datei, 1);

filename qin  clear;
filename qout clear;

/* ==================================================================== *
 * T1  SELECT: XML- und JSON-Fixture -> IDENTISCHES tidy resultdsn
 *     (zentrales Abnahmekriterium, Spec 3.3 / 6.3)
 * ==================================================================== */
filename fxml  "&fixtures./response_select.xml"  encoding="utf-8";
filename fjson "&fixtures./response_select.json" encoding="utf-8";

%sparql_parse_response(in_fileref=fxml,  queryform=SELECT, resultformat=XML,
                       resultdsn=work.sel_xml);
%sparql_parse_response(in_fileref=fjson, queryform=SELECT, resultformat=JSON,
                       resultdsn=work.sel_json);

proc compare base=work.sel_xml compare=work.sel_json noprint;
run;
%let _cmp = &sysinfo;   /* PROC COMPARE: sysinfo=0 => vollstaendig identisch */
%if (&_cmp = 0) %then
  %put NOTE: [PASS] T1 SELECT XML==JSON identisch;
%else
  %put ERROR: [FAIL] T1 SELECT XML!=JSON (sysinfo=&_cmp);

filename fxml  clear;
filename fjson clear;

/* ==================================================================== *
 * T2  ASK: XML und JSON -> gleiches 1-Zeilen-boolean-Dataset
 * ==================================================================== */
filename faxml  "&fixtures./response_ask.xml"  encoding="utf-8";
filename fajson "&fixtures./response_ask.json" encoding="utf-8";

%sparql_parse_response(in_fileref=faxml,  queryform=ASK, resultformat=XML,
                       resultdsn=work.ask_xml);
%sparql_parse_response(in_fileref=fajson, queryform=ASK, resultformat=JSON,
                       resultdsn=work.ask_json);

proc compare base=work.ask_xml compare=work.ask_json noprint;
run;
%let _cmp = &sysinfo;
%if (&_cmp = 0) %then
  %put NOTE: [PASS] T2 ASK XML==JSON identisch;
%else
  %put ERROR: [FAIL] T2 ASK XML!=JSON (sysinfo=&_cmp);

data _null_;
  set work.ask_xml;
  call symputx('_askval', boolean, 'G');
run;
%if (&_askval = true) %then
  %put NOTE: [PASS] T2 ASK boolean=true;
%else
  %put ERROR: [FAIL] T2 ASK boolean=&_askval;

filename faxml  clear;
filename fajson clear;

/* ==================================================================== *
 * T3  Aufrufkette ohne Netz: debug_nohttp=Y
 *     -> Validierung/Statushandling/Tempfile-Erzeugung ohne PROC HTTP
 * ==================================================================== */
%sparqlquery(query=%nrstr(ASK { ?s ?p ?o }),
             endpoint=http://example.org/sparql,
             queryform=ASK, debug_nohttp=Y, problemhandling=RETURN);
%_assert_rc(T3 debug_nohttp Kette, 0);
%if (&sparql_http_status = 200) %then
  %put NOTE: [PASS] T3 http_status=200;
%else
  %put ERROR: [FAIL] T3 http_status=&sparql_http_status;

/* ==================================================================== *
 * T4  Parallelitaet: zwei Aufrufe -> unterschiedliche Tempnamen (Spec 2.2)
 * ==================================================================== */
%sparqlquery(query=%nrstr(ASK {}), endpoint=http://x, queryform=ASK,
             debug_nohttp=Y, problemhandling=RETURN);
%let _s1 = &sparql_last_stem;
%sparqlquery(query=%nrstr(ASK {}), endpoint=http://x, queryform=ASK,
             debug_nohttp=Y, problemhandling=RETURN);
%let _s2 = &sparql_last_stem;
%if (%superq(_s1) ne %superq(_s2)) %then
  %put NOTE: [PASS] T4 eindeutige Tempnamen;
%else
  %put ERROR: [FAIL] T4 Tempnamen kollidieren (&_s1);

%put NOTE: test_sparqlquery durchlaufen (siehe [PASS]/[FAIL] oben).;
