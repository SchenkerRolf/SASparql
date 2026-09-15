/*------------------------------------------------------------------------*\
 Makro    : sparql_build_request
 Zweck    : Vereinheitlicht die Query-Quelle (query= ODER queryfile=) und
            legt den vollstaendigen Query-Text (ohne Zeilenlaengen-
            Trunkierung) in out_fileref ab.
 Autor    : <TODO>
 Version  : 0.2.0
 Aenderungen:
   YYYY-MM-DD  Name   Beschreibung
   2026-09-14  init   Initiales Geruest gemaess Spec 3.1
   2026-09-14  impl   Validierung (V1/V2) + Schreiben/Kopieren implementiert

 Parameter (siehe Spec 3.1):
   query=        (opt)  Query als Text. Sonderzeichen & / % beim Aufruf mit
                        %nrstr(...) maskieren, sonst vom Makroprozessor
                        interpretiert.
   queryfile=    (opt)  Pfad zu Datei mit Query.
   out_fileref=  (req)  Bereits zugewiesener Fileref, in den der
                        vereinheitlichte Query-Text geschrieben wird.
   Genau eine der Quellen query= / queryfile= muss gesetzt sein (V1).

 Encoding (Session ist WLATIN1, Spec 2):
   - queryfile= wird BYTE-EXAKT kopiert (recfm=n, keine Transcodierung) —
     eine UTF-8-Query-Datei bleibt UTF-8.
   - query= (Text) wird per PUT geschrieben; ist out_fileref mit
     encoding="utf-8" zugewiesen (so macht es der Orchestrator), wird der
     Text dabei nach UTF-8 transcodiert.

 Rueckgabe:
   &sparql_rc (0=ok, 1=Parameter-/Build-Fehler), &sparql_msg

 Abhaengigkeiten:
   keine (Base SAS 9.4)
\*------------------------------------------------------------------------*/
%macro sparql_build_request(query=, queryfile=, out_fileref=);

  %global sparql_rc sparql_msg;
  %let sparql_rc  = 0;
  %let sparql_msg = ;

  %local macnm has_query has_file src;
  %let macnm = sparql_build_request;

  /* Quellen ohne Makro-Aufloesung pruefen (Query kann & / % enthalten). */
  %let has_query = %eval(%length(%superq(query))     > 0);
  %let has_file  = %eval(%length(%superq(queryfile)) > 0);

  /* ================= Validierung (Spec 5), vor jeder Aktion ========== */

  /* V1: genau eine Quelle (query= XOR queryfile=). */
  %if (&has_query = 0 and &has_file = 0) %then %do;
    %let sparql_rc  = 1;
    %let sparql_msg = &macnm.: weder query= noch queryfile= gesetzt - genau eine Quelle noetig (V1).;
    %put ERROR: &sparql_msg;
    %return;
  %end;
  %if (&has_query = 1 and &has_file = 1) %then %do;
    %let sparql_rc  = 1;
    %let sparql_msg = &macnm.: query= UND queryfile= gesetzt - nur genau eine Quelle erlaubt (V1).;
    %put ERROR: &sparql_msg;
    %return;
  %end;

  /* out_fileref= ist Pflicht. */
  %if (%length(%superq(out_fileref)) = 0) %then %do;
    %let sparql_rc  = 1;
    %let sparql_msg = &macnm.: out_fileref= ist Pflicht.;
    %put ERROR: &sparql_msg;
    %return;
  %end;

  /* V2: queryfile= muss existieren. */
  %if (&has_file = 1) %then %do;
    %if (%sysfunc(fileexist(%superq(queryfile))) = 0) %then %do;
      %let sparql_rc  = 1;
      %let sparql_msg = &macnm.: queryfile= existiert nicht: %superq(queryfile) (V2).;
      %put ERROR: &sparql_msg;
      %return;
    %end;
  %end;

  /* ================= Query-Text in out_fileref ablegen ============== */

  %if (&has_query = 1) %then %do;
    %let src = query;
    /* query= : Text via symget() (ohne erneute Makro-Aufloesung) schreiben.
       Hinweis: DATA-Step-Char begrenzt auf 32767 Zeichen; fuer laengere
       Queries queryfile= verwenden (Spec 3.1). out_fileref wird dabei ueber-
       schrieben (Datei wird zum Schreiben geoeffnet). */
    data _null_;
      length _q $32767;
      _q   = symget('query');
      _len = lengthn(_q);
      file &out_fileref lrecl=32767;
      put _q $varying32767. _len;
    run;
  %end;
  %else %do;
    %let src = queryfile;
    /* queryfile= : Datei ALS GANZES byte-exakt kopieren (recfm=n), nicht
       zeilenweise mit fixer Laenge (Spec 3.1). recfm=n wird auf INFILE und
       FILE erzwungen, unabhaengig davon, wie die Filerefs zugewiesen sind.
       Implizite DATA-Step-Schleife liest chunkweise bis EOF. */
    data _null_;
      length _buf $32767;
      infile "%superq(queryfile)" recfm=n lrecl=32767 length=_len;
      file  &out_fileref          recfm=n lrecl=32767;
      input _buf $varying32767. _len;
      put   _buf $varying32767. _len;
    run;
  %end;

  /* Best-effort I/O-Guard: DATA-Step-Fehler in Build-Fehler uebersetzen. */
  %if (&syserr > 4) %then %do;
    %let sparql_rc  = 1;
    %let sparql_msg = &macnm.: Schreiben/Kopieren nach Fileref &out_fileref. fehlgeschlagen (syserr=&syserr).;
    %put ERROR: &sparql_msg;
    %return;
  %end;

  %put NOTE: &macnm.: Query-Text in Fileref &out_fileref. abgelegt (Quelle: &src.).;

%mend sparql_build_request;
