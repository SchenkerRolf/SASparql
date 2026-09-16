/*------------------------------------------------------------------------*\
 Makro    : sparql_parse_response
 Zweck    : Interpretiert die Response abhaengig von queryform/resultformat.
            SELECT/ASK -> SAS-Dataset (langes/tidy Schema);
            CONSTRUCT/DESCRIBE -> RDF-Datei durchreichen.
 Autor    : Rolf Schenker
 Version  : 0.5.0
 Aenderungen:
   YYYY-MM-DD  Name   Beschreibung
   2026-09-14  init   Initiales Geruest gemaess Spec 3.3
   2026-09-14  impl   Validierung (V5/V6/V9/V10) + SELECT/ASK/CONSTRUCT
   2026-09-15  verify Server-Verifikation gg. SAS 9.4M4: XML-Automap durch
                       explizite XML-Map ersetzt (Automap scheitert an der
                       SPARQL-Results-Struktur); ridx bei XML per
                       Gruppenwechsel-Erkennung statt Map-INDEX; JSON-Zweig
                       an tatsaechliche Automap-Struktur angepasst (Member
                       BINDINGS_<VAR> je Variable); resultdsn bei SELECT
                       nach ridx/var sortiert (Engine-unabhaengige Reihenfolge)

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

 VERIFY-Stand (2026-09-15, server-verifiziert gegen SAS 9.4M4 + Fixtures):
   - JSON-Automap: Struktur bestaetigt (ein Member BINDINGS_<VAR> je SPARQL-
     Variable, Spalte ordinal_bindings = ridx; Variablennamen selbst aus
     Member HEAD_VARS). Siehe SELECT+JSON-Zweig unten.
   - XML: Automap scheitert an der SPARQL-Results-XML-Struktur; es wird eine
     explizite XML-Map verwendet (nach Entfernen des Default-Namespace).
     ridx kommt NICHT aus der Map (INDEX-Element dort ungueltig), sondern
     aus einer Gruppenwechsel-Erkennung im DATA-Step. Live gegen Wikidata
     verifiziert (2026-09-16, tests/test_live_wikidata.sas) - dort aber nur
     mit Ein-Variablen-Ergebnissen (?label). Noch offen: dieselbe Gruppen-
     wechsel-Logik gegen einen echten Server mit MEHREREN Variablen pro
     Ergebnis (Dokumentordnung/mehrere Bindings je <result>) - gegen
     Fixtures bereits abgedeckt (response_select.xml), live noch nicht.

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

/* Debug-Hilfsmakro: dumpt Member/Spalten/Werte eines Libname komplett via
   %put/put _all_ ins LOG (PROC PRINT/PROC SQL-Listing landet z. B. in
   Enterprise Guide im Ergebnisfenster, nicht im Log - deshalb kein PRINT). */
%macro _sq_dbgdump(libref);
  %local _dm _dn _di _dmem _dcols;
  proc sql noprint;
    select memname into :_dm separated by ' '
      from dictionary.tables where libname="%upcase(&libref)";
  quit;
  %put NOTE: DEBUG &libref Member: &_dm;
  %let _dn = 0;
  %if (%length(&_dm) > 0) %then %let _dn = %sysfunc(countw(&_dm));
  %do _di = 1 %to &_dn;
    %let _dmem = %scan(&_dm, &_di);
    %let _dcols = ;
    proc sql noprint;
      select name into :_dcols separated by ' '
        from dictionary.columns
        where libname="%upcase(&libref)" and memname="&_dmem"
        order by varnum;
    quit;
    %put NOTE: DEBUG &libref..&_dmem Spalten: &_dcols;
    data _null_;
      set &libref..&_dmem;
      put _all_;
    run;
  %end;
%mend _sq_dbgdump;


%macro sparql_parse_response(in_fileref=, queryform=SELECT, resultformat=,
                            resultdsn=queryresult, resultfile=,
                            debug=N, debug_previewlines=10);

  %global sparql_rc sparql_msg;
  %let sparql_rc  = 0;
  %let sparql_msg = ;

  %local macnm inpath fr lib bmem btype
         i vcol np tok ok
         hvcols nhv vname mem ntabs
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

  /* Explizite XML-Map fuer SPARQL-Results-XML, in zwei Schritten:
     1) Default-Namespace (xmlns="http://www.w3.org/2005/sparql-results#")
        aus dem Rohtext entfernen (server-verifiziert noetig, sonst
        "XMLMap is not properly formed. No TABLE element encountered.").
     2) Namespace-freie Map ueber die vereinfachte Kopie legen.
     ridx wird NICHT ueber die Map ermittelt (ein <INDEX/> auf den <result>-
     Elternpfad scheiterte server-verifiziert mit "Expecting COLUMN
     collection element, found INDEX." - kein gueltiger Map-Bestandteil an
     dieser Stelle), sondern unten per Gruppenwechsel-Erkennung im DATA-Step:
     SPARQL bindet eine Variable nie zweimal im selben <result> - taucht ein
     Bindungsname innerhalb der laufenden Gruppe erneut auf, beginnt ein
     neues <result>. */
  %if (&resultformat = XML) %then %do;
    filename _spinx temp encoding="utf-8";
    /* Gepuffertes zeilenweises Lesen statt recfm=n: recfm=n ist laut SAS-Log
       "UNBUFFERED" (Byte-fuer-Byte-I/O) und blieb server-verifiziert gegen
       den UNC-Fixture-Pfad haengen (2026-09-15). Fuer eine reine Text-
       ersetzung reicht gepuffertes INFILE/FILE wie beim JSON/XML-Libname
       selbst (das liest denselben UNC-Pfad ja bereits erfolgreich). */
    data _null_;
      length _line $32767;
      infile "&inpath" encoding="utf-8" lrecl=32767 pad;
      file  _spinx     encoding="utf-8" lrecl=32767;
      input;
      _line = tranwrd(_infile_, ' xmlns="http://www.w3.org/2005/sparql-results#"', ' ');
      put _line;
    run;

    filename _sqxmap temp;
    data _null_;
      file _sqxmap;
      put '<SXLEMAP version="2.1" name="SPARQLRESULT">';
      put '<TABLE name="ASKRESULT">';
      put '<TABLE-PATH syntax="XPath">/sparql</TABLE-PATH>';
      put '<COLUMN name="boolean"><PATH syntax="XPath">/sparql/boolean</PATH><TYPE>character</TYPE><DATATYPE>STRING</DATATYPE><LENGTH>5</LENGTH></COLUMN>';
      put '</TABLE>';
      put '<TABLE name="BINDING">';
      put '<TABLE-PATH syntax="XPath">/sparql/results/result/binding</TABLE-PATH>';
      put '<COLUMN name="name"><PATH syntax="XPath">/sparql/results/result/binding/@name</PATH><TYPE>character</TYPE><DATATYPE>STRING</DATATYPE><LENGTH>256</LENGTH></COLUMN>';
      put '<COLUMN name="uri"><PATH syntax="XPath">/sparql/results/result/binding/uri</PATH><TYPE>character</TYPE><DATATYPE>STRING</DATATYPE><LENGTH>4000</LENGTH></COLUMN>';
      put '<COLUMN name="bnode"><PATH syntax="XPath">/sparql/results/result/binding/bnode</PATH><TYPE>character</TYPE><DATATYPE>STRING</DATATYPE><LENGTH>4000</LENGTH></COLUMN>';
      put '<COLUMN name="literal"><PATH syntax="XPath">/sparql/results/result/binding/literal</PATH><TYPE>character</TYPE><DATATYPE>STRING</DATATYPE><LENGTH>4000</LENGTH></COLUMN>';
      put '<COLUMN name="lit_lang"><PATH syntax="XPath">/sparql/results/result/binding/literal/@xml:lang</PATH><TYPE>character</TYPE><DATATYPE>STRING</DATATYPE><LENGTH>35</LENGTH></COLUMN>';
      put '<COLUMN name="lit_datatype"><PATH syntax="XPath">/sparql/results/result/binding/literal/@datatype</PATH><TYPE>character</TYPE><DATATYPE>STRING</DATATYPE><LENGTH>1000</LENGTH></COLUMN>';
      put '</TABLE>';
      put '</SXLEMAP>';
    run;
  %end;

  /* ---------------------------- ASK -------------------------------- */
  %if (&queryform = ASK) %then %do;
    %let lib = ; %let bmem = ; %let btype = ;
    %if (&resultformat = XML) %then %do;
      libname _xin xmlv2 xmlfileref=_spinx xmlmap=_sqxmap;
      %if (&debug = Y) %then %do; %_sq_dbgdump(_xin) %end;
      %let lib  = _XIN;
      %let bmem = ASKRESULT;
      proc sql noprint;
        select type into :btype trimmed
          from dictionary.columns
          where libname = "&lib" and memname = "&bmem" and upcase(name) = 'BOOLEAN';
      quit;
    %end;
    %else %do;
      libname _jin json fileref=_spin;
      %if (&debug = Y) %then %do; %_sq_dbgdump(_jin) %end;
      %let lib = _JIN;

      /* boolean-Spalte robust ueber alle Member entdecken. */
      proc sql noprint;
        select memname, type into :bmem trimmed, :btype trimmed
          from dictionary.columns
          where libname = "&lib" and upcase(name) = 'BOOLEAN';
      quit;
    %end;

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
    libname _jin json fileref=_spin;
    %if (&debug = Y) %then %do; %_sq_dbgdump(_jin) %end;

    /* Struktur server-verifiziert (Log 2026-09-15): pro SPARQL-Variable X,
       die in mind. einem Binding vorkommt, legt die JSON-Automap ein
       eigenes Member BINDINGS_<UPPERCASE(X)> an, mit Spalten
       ordinal_bindings (= ridx - Position im aeusseren results.bindings-
       Array, korrekt auch wenn diese Variable nicht in jedem Result
       gebunden ist), type, value, optional datatype/xml_lang - je nachdem,
       ob im Datenbestand ueberhaupt vorhanden. Der exakte, gross-/klein-
       schreibungsrichtige Variablenname X selbst steht NICHT im Membernamen
       (SAS-Namen sind uppercase), sondern als Wert in Member HEAD_VARS
       (Spalten vars1..varsN, aus head.vars). */
    %let hvcols = ;
    %let nhv    = 0;
    %if (%sysfunc(exist(_jin.head_vars))) %then %do;
      proc sql noprint;
        select name into :hvcols separated by ' '
          from dictionary.columns
          where libname = '_JIN' and memname = 'HEAD_VARS'
            and upcase(name) like 'VARS%'
          order by varnum;
      quit;
      %let nhv = %sysfunc(countw(&hvcols));
    %end;

    %if (&nhv = 0) %then %do;
      /* Keine Variablen in head.vars -> leeres tidy-Dataset. */
      data &resultdsn;
        length ridx 8 var $&L_VAR value $&L_VALUE type $&L_TYPE
               datatype $&L_DTYPE lang $&L_LANG;
        stop;
      run;
    %end;
    %else %do;
      /* Variablennamen (exakte Schreibweise) aus der einen HEAD_VARS-Zeile
         in Makrovariablen _vn1.._vnN holen. */
      data _null_;
        set _jin.head_vars;
        %do i = 1 %to &nhv;
          %let vcol = %scan(&hvcols, &i, %str( ));
          call symputx("_vn&i", &vcol, 'L');
        %end;
      run;

      %let ntabs = ;
      %do i = 1 %to &nhv;
        %let vname = %superq(_vn&i);
        %let mem   = BINDINGS_%upcase(&vname);
        %if (%sysfunc(exist(_jin.&mem))) %then %do;
          %let ntabs = &ntabs _sqjv&i;
          data _sqjv&i;
            length ridx 8 var $&L_VAR value $&L_VALUE type $&L_TYPE
                   datatype $&L_DTYPE lang $&L_LANG;
            set _jin.&mem;
            ridx = ordinal_bindings;
            var  = "&vname";
            if type = 'typed-literal' then type = 'literal';
            %if %sparql_hascol(_jin.&mem, xml_lang) %then %do;
              lang = xml_lang;
            %end;
            keep ridx var value type datatype lang;
          run;
        %end;
      %end;

      %if (%length(&ntabs) = 0) %then %do;
        data &resultdsn;
          length ridx 8 var $&L_VAR value $&L_VALUE type $&L_TYPE
                 datatype $&L_DTYPE lang $&L_LANG;
          stop;
        run;
      %end;
      %else %do;
        data &resultdsn;
          set &ntabs;
        run;
        proc datasets lib=work nolist;
          delete &ntabs;
        quit;
      %end;
    %end;
  %end;

  /* ------------------------- SELECT + XML -------------------------- */
  %else %do;
    libname _xin xmlv2 xmlfileref=_spinx xmlmap=_sqxmap;
    %if (&debug = Y) %then %do; %_sq_dbgdump(_xin) %end;

    /* Member/Spalten sind durch die explizite Map (oben) fest vorgegeben:
       Member BINDING mit name/uri/bnode/literal/lit_lang/lit_datatype.
       ridx kommt NICHT aus der Map, sondern per Gruppenwechsel-Erkennung
       (s. Map-Kommentar oben): SPARQL bindet eine Variable nie zweimal im
       selben <result> - ein wiederholter Bindungsname markiert eine neue
       Gruppe. Setzt Dokumentordnung wie geliefert voraus (VERIFY). */
    %if (%sysfunc(exist(_xin.binding)) = 0) %then %do;
      data &resultdsn;
        length ridx 8 var $&L_VAR value $&L_VALUE type $&L_TYPE
               datatype $&L_DTYPE lang $&L_LANG;
        stop;
      run;
      %put WARNING: &macnm.: Member _XIN.BINDING wurde nicht erzeugt - leeres &resultdsn (VERIFY XML-Map).;
    %end;
    %else %do;
      data &resultdsn;
        length ridx 8 var $&L_VAR value $&L_VALUE type $&L_TYPE
               datatype $&L_DTYPE lang $&L_LANG _done 8 _seen $4000;
        retain ridx 0 _seen '';
        set _xin.binding;
        var = name;
        if index(_seen, '|' !! strip(var) !! '|') > 0 then do;
          ridx  = ridx + 1;
          _seen = '';
        end;
        else if ridx = 0 then ridx = 1;
        _seen = strip(_seen) !! '|' !! strip(var) !! '|';
        _done = 0;
        if not _done and not missing(uri)     then do; type='uri';     value=uri;     _done=1; end;
        if not _done and not missing(bnode)   then do; type='bnode';   value=bnode;   _done=1; end;
        if not _done and not missing(literal) then do; type='literal'; value=literal; _done=1; end;
        datatype = lit_datatype;
        lang     = lit_lang;
        keep ridx var value type datatype lang;
      run;
    %end;
  %end;

  /* SELECT: einheitliche Zeilenreihenfolge unabhaengig von der Engine.
     JSON liefert Zeilen variablenweise gruppiert (erst alle "person", dann
     alle "name", ...), XML ergebnisweise (Dokumentordnung). Das zentrale
     Abnahmekriterium (Spec 3.3/6.3, T1) vergleicht per PROC COMPARE ohne
     Sortierung - deshalb hier fest nach ridx/var sortieren, damit beide
     Engines dasselbe resultdsn liefern. */
  %if (&sparql_rc = 0 and &queryform = SELECT and %sysfunc(exist(&resultdsn))) %then %do;
    proc sort data=&resultdsn; by ridx var; run;
  %end;

  /* ================= Aufraeumen + Abschluss ========================= */
  %if (%sysfunc(libref(_jin))  = 0)  %then %do; libname _jin clear;  %end;
  %if (%sysfunc(libref(_xin))  = 0)  %then %do; libname _xin clear;  %end;
  %if (%sysfunc(fileref(_spin)) <= 0) %then %do; filename _spin clear; %end;
  %if (%sysfunc(fileref(_sqxmap)) <= 0) %then %do; filename _sqxmap clear; %end;
  %if (%sysfunc(fileref(_spinx)) <= 0) %then %do; filename _spinx clear; %end;

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
