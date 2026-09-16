/*------------------------------------------------------------------------*\
 Makro    : sparqlquery
 Zweck    : Orchestrator / oeffentliche API. Baut die Query auf, fuehrt genau
            einen HTTP-Aufruf aus und parst die Response zu Dataset/RDF-Datei.
 Autor    : <TODO>
 Version  : 0.3.0
 Aenderungen:
   YYYY-MM-DD  Name   Beschreibung
   2026-09-14  init   Initiales Geruest gemaess Spec 3.4
   2026-09-14  impl   Ablauf 1-6, Tempnamen (Spec 2.2), problemhandling
   2026-09-15  ua     useragent= durchgereicht (s. sparql_execute.sas)

 Parameter (Vereinigung 3.1-3.3, plus):
   problemhandling=  ABORTCANCEL  ABORTCANCEL | RETURN.
   debug=            N
   debug_nohttp=     N            Y = PROC HTTP-Call ueberspringen (Test).
   showresponse=     Y            Y = Ergebnis am Ende anzeigen.
   tempnamestem=     (leer)       Default automatisch eindeutig (Spec 2.2):
                     temp-sparqlquery-<user>-<jobid>-<ts>-<counter>
   (weitere: query=, queryfile=, endpoint=, method=, queryform=,
    resultformat=, webuser=, webpassword=, proxy*=, timeout=, useragent=,
    resultdsn=, resultfile=, debug_previewlines=)

 Diagnose: &sparql_last_stem (global) = zuletzt verwendeter Tempnamen-Stamm
           (nur zu Test-/Debugzwecken, z. B. Parallelitaetstest T4).

 Ablauf (Spec 3.4):
   1. V1 validieren; Tempnamen/Filerefs erzeugen.
   2. %sparql_build_request
   3. %sparql_execute
   4. &sparql_http_status pruefen (V8) - bei Nicht-2xx: problemhandling, KEIN Parsing.
   5. %sparql_parse_response
   6. Aufraeumen (fdelete + filename clear), ausser bei debug=Y.

 Rueckgabe:
   &sparql_rc, &sparql_msg, &sparql_http_status

 Abhaengigkeiten:
   sparql_build_request, sparql_execute, sparql_parse_response
\*------------------------------------------------------------------------*/
%macro sparqlquery(query=, queryfile=, endpoint=,
                   method=POST, queryform=SELECT, resultformat=,
                   webuser=, webpassword=,
                   proxyhost=, proxyport=, proxyuser=, proxypassword=,
                   timeout=60, useragent=SASparql-SAS-Macro/0.4.0,
                   resultdsn=queryresult, resultfile=,
                   problemhandling=ABORTCANCEL,
                   debug=N, debug_nohttp=N, showresponse=Y,
                   debug_previewlines=10,
                   tempnamestem=);

  %global sparql_rc sparql_msg sparql_http_status sparql_last_stem;
  %let sparql_rc          = 0;
  %let sparql_msg         = ;
  %let sparql_http_status = ;

  %local macnm stem qpath rpath qref rref rc hasq hasf wpath;
  %let macnm           = sparqlquery;
  %let problemhandling = %upcase(&problemhandling);
  %let debug           = %upcase(&debug);
  %let debug_nohttp    = %upcase(&debug_nohttp);
  %let showresponse    = %upcase(&showresponse);
  %let queryform       = %upcase(&queryform);

  /* Session-Zaehler fuer Eindeutigkeit innerhalb der Session (Spec 2.2). */
  %if not %symexist(sparql_callcnt) %then %do; %global sparql_callcnt; %let sparql_callcnt = 0; %end;
  %if (%length(&sparql_callcnt) = 0) %then %let sparql_callcnt = 0;
  %let sparql_callcnt = %eval(&sparql_callcnt + 1);

  /* ================= 1. V1 + Tempnamen ============================== */

  /* V1: genau eine Quelle (zusaetzlich zu build_request). */
  %let hasq = %eval(%length(%superq(query))     > 0);
  %let hasf = %eval(%length(%superq(queryfile)) > 0);
  %if (&hasq = &hasf) %then %do;    /* beide 0 oder beide 1 */
    %let sparql_rc  = 1;
    %let sparql_msg = &macnm.: genau eine von query=/queryfile= noetig (V1).;
    %put ERROR: &sparql_msg;
    %goto finish;
  %end;

  /* Tempnamen-Stamm (Spec 2.2): physisch eindeutig, Fileref-Token kurz. */
  %if (%length(%superq(tempnamestem)) = 0) %then
    %let stem = temp-sparqlquery-%sysfunc(compress(&sysuserid,,kad))-%sysfunc(compress(&sysjobid,,kad))-%sysfunc(compress(%sysfunc(putn(%sysfunc(datetime()),20.6)),,kd))-&sparql_callcnt;
  %else %let stem = %superq(tempnamestem);
  %let sparql_last_stem = &stem;

  %let wpath = %sysfunc(pathname(work));
  %let qpath = &wpath/&stem..rq;    /* Query-Text     */
  %let rpath = &wpath/&stem..out;   /* Response-Body  */

  /* Kurze, session-lokale Fileref-Token (variieren pro Aufruf ueber cnt). */
  %let qref = _q&sparql_callcnt;
  %let rref = _r&sparql_callcnt;
  filename &qref "&qpath" recfm=n encoding="utf-8";  /* query= -> utf-8 transcodiert */
  filename &rref "&rpath" recfm=n;                    /* Response roh (binaer)        */

  /* ================= 2. Query aufbereiten =========================== */
  %sparql_build_request(query=%superq(query), queryfile=%superq(queryfile),
                        out_fileref=&qref);
  %if (&sparql_rc ne 0) %then %goto finish;

  /* ================= 3. HTTP ausfuehren ============================= */
  %sparql_execute(endpoint=%superq(endpoint), in_fileref=&qref, method=&method,
                  queryform=&queryform, resultformat=&resultformat,
                  webuser=%superq(webuser), webpassword=%superq(webpassword),
                  proxyhost=%superq(proxyhost), proxyport=%superq(proxyport),
                  proxyuser=%superq(proxyuser), proxypassword=%superq(proxypassword),
                  out_fileref=&rref, timeout=&timeout, useragent=%superq(useragent),
                  debug_nohttp=&debug_nohttp, debug=&debug);

  /* ================= 4. Status / Fehler (V8) ======================== */
  %if (&sparql_rc ne 0) %then %goto finish;   /* execute setzt rc=2 bei Nicht-2xx */
  %if (&debug_nohttp = Y) %then %do;
    %put NOTE: &macnm.: debug_nohttp=Y - Parsing uebersprungen (Status &sparql_http_status).;
    %goto finish;
  %end;

  /* ================= 5. Response parsen ============================= */
  %sparql_parse_response(in_fileref=&rref, queryform=&queryform,
                         resultformat=&resultformat, resultdsn=&resultdsn,
                         resultfile=%superq(resultfile),
                         debug=&debug, debug_previewlines=&debug_previewlines);
  %if (&sparql_rc ne 0) %then %goto finish;

  /* ================= 6a. Ergebnis anzeigen ========================= */
  %if (&showresponse = Y) %then %do;
    %if (&queryform = SELECT or &queryform = ASK) %then %do;
      proc print data=&resultdsn; run;
    %end;
    %else %do;
      %put NOTE: &macnm.: RDF-Graph in %superq(resultfile), erste &debug_previewlines Zeilen:;
      data _null_;
        infile "%superq(resultfile)" lrecl=32767 obs=&debug_previewlines;
        input;
        put "  | " _infile_;
      run;
    %end;
  %end;

  %put NOTE: &macnm.: OK (rc=0, HTTP=&sparql_http_status, &queryform/&resultformat).;

  %finish:
  /* ================= 6b. Aufraeumen (Spec 3.4 Schritt 6) =========== */
  %if (&debug = Y) %then %do;
    %if (%length(&qref)) %then %put NOTE: &macnm.: debug=Y - Query-Tempdatei bleibt: &qpath (fileref &qref).;
    %if (%length(&rref)) %then %put NOTE: &macnm.: debug=Y - Response-Tempdatei bleibt: &rpath (fileref &rref).;
  %end;
  %else %do;
    %if (%length(&qref)) %then %do;
      %if (%sysfunc(fileref(&qref)) <= 0) %then %do;
        %let rc = %sysfunc(fdelete(&qref));
        filename &qref clear;
      %end;
    %end;
    %if (%length(&rref)) %then %do;
      %if (%sysfunc(fileref(&rref)) <= 0) %then %do;
        %let rc = %sysfunc(fdelete(&rref));
        filename &rref clear;
      %end;
    %end;
  %end;

  /* ================= problemhandling =============================== */
  %if (&sparql_rc ne 0 and &problemhandling = ABORTCANCEL) %then %do;
    %put ERROR: &macnm.: Abbruch (rc=&sparql_rc): &sparql_msg;
    data _null_; abort cancel; run;
  %end;

%mend sparqlquery;
