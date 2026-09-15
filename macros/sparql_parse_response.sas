/*------------------------------------------------------------------------*\
 Makro    : sparql_parse_response
 Zweck    : Interpretiert die Response abhaengig von queryform/resultformat.
            SELECT/ASK -> SAS-Dataset (langes/tidy Schema);
            CONSTRUCT/DESCRIBE -> RDF-Datei durchreichen.
 Autor    : <TODO>
 Version  : 0.2.0
 Aenderungen:
   YYYY-MM-DD  Name   Beschreibung
   2026-09-14  init   Initiales Geruest gemaess Spec 3.3
   2026-09-14  impl   Validierung (V5/V6/V9/V10) + SELECT/ASK/CONSTRUCT

 Parameter (siehe Spec 3.3):
   in_fileref=        (req)  Fileref mit Response-Body (utf-8 empfohlen).
   queryform=         SELECT steuert Verarbeitungspfad.
   resultformat=      (leer) XML|JSON bzw. TURTLE|JSONLD (Def. wie 3.2).
   resultdsn=         queryresult  Ziel-Dataset (nur SELECT/ASK).
   resultfile=        (leer) Zieldatei RDF-Graph (CONSTRUCT/DESCRIBE; V10).
   debug=             N      zusaetzliche Log-Ausgabe.
   debug_previewlines= 10    Log-Zeilen bei CONSTRUCT/DESCRIBE-Vorschau.

 SELECT-Zielschema (tidy, identisch fuer XML und JSON):
   ridx (num) | var (char) | value (char) | type (char: uri/literal/bnode)
   | datatype (char) | lang (char).  Ungebundene Variablen -> KEINE Zeile.
 ASK-Zielschema:
   1 Zeile, Char-Spalte boolean in {true,false}.

 Encoding: Response wird ueber einen privaten Fileref mit encoding="utf-8"
   gelesen (Session ist WLATIN1, Spec 2). Zeichen ausserhalb WLATIN1 gehen
   dabei verloren (dokumentierte Grenze).

 VERIFY (ohne SAS-Runtime nicht endgueltig pruefbar): die exakten Member-/
   Spaltennamen der XML-/JSON-Libname-Engines werden zur Laufzeit aus
   dictionary.columns entdeckt; die mit "VERIFY" markierten Annahmen sind am
   SAS-9.4M4-Server gegen die Fixtures (tests/) zu bestaetigen.

 Rueckgabe:
   &sparql_rc (0=ok, 1=Parameterfehler, 3=Parse-Fehler), &sparql_msg

 Abhaengigkeiten:
   sparql_hascol (unten); Base SAS 9.4M4 (XML-/JSON-Libname-Engine)
\*------------------------------------------------------------------------*/

/* Hilfsmakro: liefert 1, wenn Spalte &col im Dataset &ds existiert, sonst 0. */
%macro sparql_hascol(ds, col);
%local dsid r rc;
%let r = 0;
%let dsid = %sysfunc(open(&ds));
%if (&dsid) %then %do;
  %if (%sysfunc(varnum(&dsid, &col))) %then %let r = 1;
  %let rc = %sysfunc(close(&dsid));
%end;
&r
%mend sparql_hascol;


%macro sparql_parse_response(in_fileref=, queryform=SELECT, resultformat=,
                            resultdsn=queryresult, resultfile=,
                            debug=N, debug_previewlines=10);

  %global sparql_rc sparql_msg;
  %let sparql_rc  = 0;
  %let sparql_msg = ;

  %local macnm inpath fr lib bmem btype vcols ordcol xlang xdtype
         i nv vcol pfx np tok ok
         L_VAR L_VALUE L_TYPE L_DTYPE L_LANG;
  %let macnm = sparql_parse_response;

  /* Feste Laengen des tidy-Schemas -> XML und JSON MUESSEN identisch sein. */
  %let L_VAR   = 256;
  %let L_VALUE = 4000;   /* laengere Literale/URIs werden hier abgeschnitten */
  %let L_TYPE  = 8;
  %let L_DTYPE = 1000;
  %let L_LANG  = 35;

  %let queryform    = %upcase(&queryform);
  %let resultformat = %upcase(&resultformat);
  %let debug        = %upcase(&debug);

  /* ================= Validierung (Spec 5), vor jeder Aktion ========== */

  /* in_fileref= Pflicht. */
  %if (%length(%superq(in_fileref)) = 0) %then %do;
    %let sparql_rc  = 1;
    %let sparql_msg = &macnm.: in_fileref= ist Pflicht.;
    %put ERROR: &sparql_msg;
    %return;
  %end;

  /* V5: queryform gueltig. */
  %if not (&queryform = SELECT or &queryform = ASK
        or &queryform = CONSTRUCT or &queryform = DESCRIBE) %then %do;
    %let sparql_rc  = 1;
    %let sparql_msg = &macnm.: queryform=&queryform ungueltig - SELECT/ASK/CONSTRUCT/DESCRIBE (V5).;
    %put ERROR: &sparql_msg;
    %return;
  %end;

  /* resultformat-Default je queryform (Spec 3.2). */
  %if (%length(&resultformat) = 0) %then %do;
    %if (&queryform = SELECT or &queryform = ASK) %then %let resultformat = XML;
    %else %let resultformat = TURTLE;
  %end;

  /* V6: resultformat passt zu queryform. */
  %if (&queryform = SELECT or &queryform = ASK) %then %do;
    %if not (&resultformat = XML or &resultformat = JSON) %then %do;
      %let sparql_rc  = 1;
      %let sparql_msg = &macnm.: resultformat=&resultformat unzulaessig fuer &queryform - nur XML/JSON (V6).;
      %put ERROR: &sparql_msg;
      %return;
    %end;
  %end;
  %else %do;
    %if not (&resultformat = TURTLE or &resultformat = JSONLD) %then %do;
      %let sparql_rc  = 1;
      %let sparql_msg = &macnm.: resultformat=&resultformat unzulaessig fuer &queryform - nur TURTLE/JSONLD (V6).;
      %put ERROR: &sparql_msg;
      %return;
    %end;
  %end;

  /* V9: resultdsn gueltiger (ein- oder zweiteiliger) SAS-Name. */
  %let ok = 1;
  %let np = %sysfunc(countw(&resultdsn, %str(.)));
  %if (&np > 2) %then %let ok = 0;
  %else %do i = 1 %to &np;
    %let tok = %scan(&resultdsn, &i, %str(.));
    %if not %sysfunc(nvalid(&tok, V7)) %then %let ok = 0;
  %end;
  %if (not &ok) %then %do;
    %let sparql_rc  = 1;
    %let sparql_msg = &macnm.: resultdsn=&resultdsn ist kein gueltiger SAS-Dataset-Name (V9).;
    %put ERROR: &sparql_msg;
    %return;
  %end;

  /* V10: resultfile Pflicht bei CONSTRUCT/DESCRIBE. */
  %if (&queryform = CONSTRUCT or &queryform = DESCRIBE) %then %do;
    %if (%length(%superq(resultfile)) = 0) %then %do;
      %let sparql_rc  = 1;
      %let sparql_msg = &macnm.: resultfile= ist Pflicht bei queryform=&queryform (V10).;
      %put ERROR: &sparql_msg;
      %return;
    %end;
  %end;

  /* Response-Fileref zugewiesen und Datei vorhanden? */
  %let fr = %sysfunc(fileref(&in_fileref));
  %if (&fr > 0) %then %do;
    %let sparql_rc  = 1;
    %let sparql_msg = &macnm.: in_fileref &in_fileref ist nicht zugewiesen.;
    %put ERROR: &sparql_msg;
    %return;
  %end;
  %if (&fr < 0) %then %do;
    %let sparql_rc  = 3;
    %let sparql_msg = &macnm.: Response-Datei zu &in_fileref fehlt/leer.;
    %put ERROR: &sparql_msg;
    %return;
  %end;

  %let inpath = %sysfunc(pathname(&in_fileref));

  /* ================= CONSTRUCT / DESCRIBE: reiner Dateitransfer ====== */
  %if (&queryform = CONSTRUCT or &queryform = DESCRIBE) %then %do;
    /* Byte-exakte Kopie (recfm=n), keine Konvertierung (Turtle ODER JSON-LD). */
    data _null_;
      length _buf $32767;
      infile "&inpath"               recfm=n lrecl=32767 length=_len;
      file  "%superq(resultfile)"    recfm=n lrecl=32767;
      input _buf $varying32767. _len;
      put   _buf $varying32767. _len;
    run;
    %if (&syserr > 4) %then %do;
      %let sparql_rc  = 3;
      %let sparql_msg = &macnm.: Kopie der RDF-Datei nach %superq(resultfile) fehlgeschlagen (syserr=&syserr).;
      %put ERROR: &sparql_msg;
      %return;
    %end;
    %if (&debug = Y) %then %do;
      %put NOTE: &macnm.: Vorschau (%superq(resultfile)), erste &debug_previewlines Zeilen:;
      data _null_;
        infile "%superq(resultfile)" lrecl=32767 obs=&debug_previewlines;
        input;
        put "  | " _infile_;
      run;
    %end;
    %put NOTE: &macnm.: RDF-Graph (&resultformat) nach %superq(resultfile) geschrieben.;
    %return;
  %end;

  /* ================= SELECT / ASK: Libname mit utf-8 lesen =========== */
  filename _spin "&inpath" encoding="utf-8";

  /* ---------------------------- ASK -------------------------------- */
  %if (&queryform = ASK) %then %do;
    %let lib = ; %let bmem = ; %let btype = ;
    %if (&resultformat = XML) %then %do;
      libname _xin xmlv2 xmlfileref=_spin;   /* VERIFY XMLV2-Struktur */
      %let lib = _XIN;
    %end;
    %else %do;
      libname _jin json fileref=_spin;       /* VERIFY JSON-Struktur */
      %let lib = _JIN;
    %end;

    /* boolean-Spalte robust ueber alle Member entdecken. */
    proc sql noprint;
      select memname, type into :bmem trimmed, :btype trimmed
        from dictionary.columns
        where libname = "&lib" and upcase(name) = 'BOOLEAN';
    quit;

    %if (%length(&bmem) = 0) %then %do;
      %let sparql_rc  = 3;
      %let sparql_msg = &macnm.: ASK-Response ohne boolean-Wert (VERIFY Engine-Struktur).;
      %put ERROR: &sparql_msg;
    %end;
    %else %do;
      data &resultdsn(keep=boolean);
        length boolean $5;
        set &lib..&bmem(rename=(boolean=_srcbool));
        %if (&btype = num) %then %do;
          boolean = ifc(_srcbool = 1, 'true', 'false');
        %end;
        %else %do;
          boolean = ifc(lowcase(strip(_srcbool)) in ('true','1'), 'true', 'false');
        %end;
      run;
    %end;
  %end;

  /* ------------------------- SELECT + JSON ------------------------- */
  %else %if (&resultformat = JSON) %then %do;
    libname _jin json fileref=_spin;          /* VERIFY JSON-Struktur */

    /* Bindings-Member = das Member mit '<var>_value'-Spalten. */
    %let bmem  = ;
    %let vcols = ;
    proc sql noprint;
      select distinct memname into :bmem trimmed
        from dictionary.columns
        where libname = '_JIN'
          and upcase(name) like '%\_VALUE' escape '\';
    quit;

    %if (%length(&bmem) = 0) %then %do;
      /* Leeres Result-Set -> leeres tidy-Dataset mit korrekter Struktur. */
      data &resultdsn;
        length ridx 8 var $&L_VAR value $&L_VALUE type $&L_TYPE
               datatype $&L_DTYPE lang $&L_LANG;
        stop;
      run;
    %end;
    %else %do;
      proc sql noprint;
        select name into :vcols separated by ' '
          from dictionary.columns
          where libname = '_JIN' and memname = "&bmem"
            and upcase(name) like '%\_VALUE' escape '\'
          order by varnum;
      quit;

      data &resultdsn;
        length ridx 8 var $&L_VAR value $&L_VALUE type $&L_TYPE
               datatype $&L_DTYPE lang $&L_LANG;
        set _jin.&bmem;
        ridx = _N_;   /* eine Quell-Obs pro Result-Zeile -> _N_ = Ergebnis-Index */
        %let nv = %sysfunc(countw(&vcols, %str( )));
        %do i = 1 %to &nv;
          %let vcol = %scan(&vcols, &i, %str( ));
          %let pfx  = %substr(&vcol, 1, %eval(%length(&vcol) - 6)); /* ohne _value */
          if not missing(&vcol) then do;
            var   = "&pfx";
            value = &vcol;
            %if %sparql_hascol(_jin.&bmem, &pfx._type) %then %do;
              type = &pfx._type;
              if type = 'typed-literal' then type = 'literal';
            %end;
            %else %do;
              type = '';
            %end;
            %if %sparql_hascol(_jin.&bmem, &pfx._datatype) %then %do;
              datatype = &pfx._datatype;
            %end;
            %else %do;
              datatype = '';
            %end;
            %if %sparql_hascol(_jin.&bmem, &pfx._xml_lang) %then %do;
              lang = &pfx._xml_lang;
            %end;
            %else %do;
              lang = '';
            %end;
            output;
          end;
        %end;
        keep ridx var value type datatype lang;
      run;
    %end;
  %end;

  /* ------------------------- SELECT + XML -------------------------- */
  %else %do;
    libname _xin xmlv2 xmlfileref=_spin;      /* VERIFY XMLV2-Struktur */

    /* Binding-Member = hat 'name'-Spalte UND eine von uri/literal/bnode. */
    %let bmem   = ;
    %let ordcol = ;
    %let xlang  = ;
    %let xdtype = ;
    proc sql noprint;
      select distinct memname into :bmem trimmed
        from dictionary.columns
        where libname = '_XIN' and upcase(name) = 'NAME'
          and memname in (select memname from dictionary.columns
                          where libname = '_XIN'
                            and upcase(name) in ('URI','LITERAL','BNODE'));
    quit;

    %if (%length(&bmem) = 0) %then %do;
      data &resultdsn;
        length ridx 8 var $&L_VAR value $&L_VALUE type $&L_TYPE
               datatype $&L_DTYPE lang $&L_LANG;
        stop;
      run;
      %put WARNING: &macnm.: kein Binding-Member im XML gefunden - leeres &resultdsn (VERIFY XMLV2-Struktur).;
    %end;
    %else %do;
      proc sql noprint;
        select name into :ordcol trimmed
          from dictionary.columns
          where libname = '_XIN' and memname = "&bmem"
            and upcase(name) like '%RESULT%ORDINAL%'
          order by varnum;
        select name into :xlang trimmed
          from dictionary.columns
          where libname = '_XIN' and memname = "&bmem"
            and upcase(name) like '%LANG%';
        select name into :xdtype trimmed
          from dictionary.columns
          where libname = '_XIN' and memname = "&bmem"
            and upcase(name) = 'DATATYPE';
      quit;

      data &resultdsn;
        length ridx 8 var $&L_VAR value $&L_VALUE type $&L_TYPE
               datatype $&L_DTYPE lang $&L_LANG _done 8;
        set _xin.&bmem;
        %if (%length(&ordcol)) %then %do; ridx = &ordcol; %end;
        %else %do; ridx = .; %end;
        var   = name;
        _done = 0;
        %if %sparql_hascol(_xin.&bmem, uri) %then %do;
          if not _done and not missing(uri)   then do; type='uri';     value=uri;     _done=1; end;
        %end;
        %if %sparql_hascol(_xin.&bmem, bnode) %then %do;
          if not _done and not missing(bnode) then do; type='bnode';   value=bnode;   _done=1; end;
        %end;
        %if %sparql_hascol(_xin.&bmem, literal) %then %do;
          if not _done and not missing(literal) then do; type='literal'; value=literal; _done=1; end;
        %end;
        %if (%length(&xdtype)) %then %do; datatype = &xdtype; %end; %else %do; datatype = ''; %end;
        %if (%length(&xlang))  %then %do; lang = &xlang;      %end; %else %do; lang = '';     %end;
        keep ridx var value type datatype lang;
      run;

      %if (%length(&ordcol) = 0) %then
        %put WARNING: &macnm.: keine RESULT-Ordinalspalte gefunden - ridx fehlt (VERIFY XMLV2-Struktur).;
    %end;
  %end;

  /* ================= Aufraeumen + Abschluss ========================= */
  %if (%sysfunc(libref(_jin))  = 0)  %then %do; libname _jin clear;  %end;
  %if (%sysfunc(libref(_xin))  = 0)  %then %do; libname _xin clear;  %end;
  %if (%sysfunc(fileref(_spin)) <= 0) %then %do; filename _spin clear; %end;

  %if (&sparql_rc = 0 and not %sysfunc(exist(&resultdsn))) %then %do;
    %let sparql_rc  = 3;
    %let sparql_msg = &macnm.: &resultdsn wurde nicht erzeugt (Parse-Fehler).;
    %put ERROR: &sparql_msg;
    %return;
  %end;

  %if (&sparql_rc = 0 and &debug = Y) %then %do;
    %local _nobs _dsid;
    %let _dsid = %sysfunc(open(&resultdsn));
    %let _nobs = %sysfunc(attrn(&_dsid, nobs));
    %let _dsid = %sysfunc(close(&_dsid));
    %put NOTE: &macnm.: &resultdsn erzeugt (&queryform/&resultformat), &_nobs Beobachtungen.;
  %end;

%mend sparql_parse_response;
