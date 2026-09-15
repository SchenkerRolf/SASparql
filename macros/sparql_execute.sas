/*------------------------------------------------------------------------*\
 Makro    : sparql_execute
 Zweck    : Fuehrt genau einen PROC HTTP-Aufruf gegen einen SPARQL-Endpunkt
            aus (POST oder GET), inkl. optionalem Proxy. Einziger Ort im
            Paket mit einem PROC HTTP-Aufruf.
 Autor    : <TODO>
 Version  : 0.2.0
 Aenderungen:
   YYYY-MM-DD  Name   Beschreibung
   2026-09-14  init   Initiales Geruest gemaess Spec 3.2
   2026-09-14  impl   Validierung (V3-V7), Accept, PROC HTTP, Status, nomprint

 Parameter (siehe Spec 3.2):
   endpoint=          (req)  SPARQL-Endpunkt-URL (http:// oder https://).
   in_fileref=        (req)  Fileref mit Query-Text.
   method=            POST   POST oder GET.
   queryform=         SELECT SELECT/ASK/CONSTRUCT/DESCRIBE.
   resultformat=      (leer) SELECT/ASK: XML|JSON (Def. XML);
                             CONSTRUCT/DESCRIBE: TURTLE|JSONLD (Def. TURTLE).
   webuser=           (leer) Endpunkt-Auth  -> WEBUSERNAME=.
   webpassword=       (leer) Endpunkt-Auth  -> WEBPASSWORD= (PWENCODE empf.).
   proxyhost=         (leer) Proxy-Server   -> PROXYHOST=.
   proxyport=         (leer) Proxy-Port     -> PROXYPORT=.
   proxyuser=         (leer) Proxy-Auth     -> PROXYUSERNAME= (ab 9.4M4).
   proxypassword=     (leer) Proxy-Auth     -> PROXYPASSWORD= (ab 9.4M4).
   out_fileref=       (req)  Fileref fuer Response-Body.
   headerout_fileref= (leer) Fileref fuer Response-Header (sonst intern).
   timeout=           60     Sekunden.
   debug_nohttp=      N      Y = PROC HTTP ueberspringen (Test, Spec 3.4).
   debug=             N      zusaetzliche Log-Ausgabe.

 Accept-Header (Spec 3.2):
   SELECT/ASK + XML   -> application/sparql-results+xml
   SELECT/ASK + JSON  -> application/sparql-results+json
   CONSTRUCT/DESCRIBE + TURTLE -> text/turtle
   CONSTRUCT/DESCRIBE + JSONLD -> application/ld+json

 VERIFY (ohne Runtime nicht pruefbar): urlencode()-Funktion fuer GET;
   PROXYUSERNAME=/PROXYPASSWORD= in PROC HTTP (laut Nutzer ab 9.4M4 vorhanden).

 Rueckgabe:
   &sparql_rc (0=ok,1=Param,2=HTTP), &sparql_msg, &sparql_http_status

 Abhaengigkeiten:
   keine (Base SAS 9.4M4: PROC HTTP)
\*------------------------------------------------------------------------*/
%macro sparql_execute(endpoint=, in_fileref=, method=POST, queryform=SELECT,
                      resultformat=, webuser=, webpassword=,
                      proxyhost=, proxyport=, proxyuser=, proxypassword=,
                      out_fileref=, headerout_fileref=, timeout=60,
                      debug_nohttp=N, debug=N);

  %global sparql_rc sparql_msg sparql_http_status;
  %let sparql_rc          = 0;
  %let sparql_msg         = ;
  %let sparql_http_status = ;

  %local macnm accept sopt geturl inpath ownhdr n pfx8 raw;
  %let macnm = sparql_execute;

  %let method       = %upcase(&method);
  %let queryform    = %upcase(&queryform);
  %let resultformat = %upcase(&resultformat);
  %let debug        = %upcase(&debug);
  %let debug_nohttp = %upcase(&debug_nohttp);

  /* ================= Validierung (Spec 5) =========================== */

  /* V3: method */
  %if not (&method = POST or &method = GET) %then %do;
    %let sparql_rc = 1; %let sparql_msg = &macnm.: method=&method ungueltig - POST/GET (V3).;
    %put ERROR: &sparql_msg; %return;
  %end;

  /* Pflichtparameter */
  %if (%length(%superq(endpoint)) = 0) %then %do;
    %let sparql_rc = 1; %let sparql_msg = &macnm.: endpoint= ist Pflicht (V4).;
    %put ERROR: &sparql_msg; %return;
  %end;
  %if (%length(%superq(in_fileref)) = 0) %then %do;
    %let sparql_rc = 1; %let sparql_msg = &macnm.: in_fileref= ist Pflicht.;
    %put ERROR: &sparql_msg; %return;
  %end;
  %if (%length(%superq(out_fileref)) = 0) %then %do;
    %let sparql_rc = 1; %let sparql_msg = &macnm.: out_fileref= ist Pflicht.;
    %put ERROR: &sparql_msg; %return;
  %end;

  /* V4: Schema */
  %let n    = %length(%superq(endpoint));
  %let pfx8 = %sysfunc(lowcase(%qsubstr(%superq(endpoint), 1, %sysfunc(min(8, &n)))));
  %if (%index(&pfx8, http://) ne 1) and (%index(&pfx8, https://) ne 1) %then %do;
    %let sparql_rc = 1; %let sparql_msg = &macnm.: endpoint muss mit http:// oder https:// beginnen (V4).;
    %put ERROR: &sparql_msg; %return;
  %end;

  /* V5: queryform */
  %if not (&queryform = SELECT or &queryform = ASK
        or &queryform = CONSTRUCT or &queryform = DESCRIBE) %then %do;
    %let sparql_rc = 1; %let sparql_msg = &macnm.: queryform=&queryform ungueltig (V5).;
    %put ERROR: &sparql_msg; %return;
  %end;

  /* resultformat-Default je queryform */
  %if (%length(&resultformat) = 0) %then %do;
    %if (&queryform = SELECT or &queryform = ASK) %then %let resultformat = XML;
    %else %let resultformat = TURTLE;
  %end;

  /* V6: resultformat passt zu queryform */
  %if (&queryform = SELECT or &queryform = ASK) %then %do;
    %if not (&resultformat = XML or &resultformat = JSON) %then %do;
      %let sparql_rc = 1; %let sparql_msg = &macnm.: resultformat=&resultformat unzulaessig fuer &queryform - XML/JSON (V6).;
      %put ERROR: &sparql_msg; %return;
    %end;
  %end;
  %else %do;
    %if not (&resultformat = TURTLE or &resultformat = JSONLD) %then %do;
      %let sparql_rc = 1; %let sparql_msg = &macnm.: resultformat=&resultformat unzulaessig fuer &queryform - TURTLE/JSONLD (V6).;
      %put ERROR: &sparql_msg; %return;
    %end;
  %end;

  /* V7: proxy-Credentials nur mit proxyhost */
  %if ((%length(%superq(proxyuser)) or %length(%superq(proxypassword)))
       and %length(%superq(proxyhost)) = 0) %then %do;
    %let sparql_rc = 1; %let sparql_msg = &macnm.: proxyuser/proxypassword ohne proxyhost (V7).;
    %put ERROR: &sparql_msg; %return;
  %end;

  /* ================= Accept-Header ================================== */
  %if (&queryform = SELECT or &queryform = ASK) %then %do;
    %if (&resultformat = XML) %then %let accept = application/sparql-results+xml;
    %else %let accept = application/sparql-results+json;
  %end;
  %else %do;
    %if (&resultformat = TURTLE) %then %let accept = text/turtle;
    %else %let accept = application/ld+json;
  %end;

  /* ================= debug_nohttp: kein PROC HTTP (Spec 3.4) ========= */
  %if (&debug_nohttp = Y) %then %do;
    %let sparql_http_status = 200;
    %put NOTE: &macnm.: debug_nohttp=Y - PROC HTTP uebersprungen, Status=200.;
    %return;
  %end;

  /* ================= headerout-Default (intern) ==================== */
  %let ownhdr = 0;
  %if (%length(%superq(headerout_fileref)) = 0) %then %do;
    %let headerout_fileref = _sqhdr;
    filename _sqhdr temp;
    %let ownhdr = 1;
  %end;

  /* ================= GET: URL mit urlencode() bauen ================= */
  %if (&method = GET) %then %do;
    %let inpath = %sysfunc(pathname(&in_fileref));
    %let geturl = ;
    /* Query-Text roh lesen (recfm=n) und in EINEM urlencode() kodieren. */
    data _null_;
      length _q $32767 _u $65534;
      infile "&inpath" recfm=n lrecl=32767 length=_len;
      input _q $varying32767. _len;
      _u = cats("%superq(endpoint)",
                ifc(index("%superq(endpoint)", '?') > 0, '&', '?'),
                'query=', urlencode(strip(_q)));   /* VERIFY urlencode() */
      call symputx('geturl', _u, 'L');
    run;
  %end;

  /* ================= Credentials nicht ins Log (Spec 7) ============= */
  %let sopt = %sysfunc(getoption(mprint)) %sysfunc(getoption(mlogic)) %sysfunc(getoption(symbolgen));
  options nomprint nomlogic nosymbolgen;

  %if (&method = POST) %then %do;
    proc http
        url="%superq(endpoint)"
        method="post"
        in=&in_fileref
        ct="application/sparql-query"
        out=&out_fileref
        headerout=&headerout_fileref
        timeout=&timeout
        %if (%length(%superq(webuser))) %then %do;
          webusername="%superq(webuser)" webpassword="%superq(webpassword)"
        %end;
        %if (%length(%superq(proxyhost))) %then %do;
          proxyhost="%superq(proxyhost)"
          %if (%length(%superq(proxyport))) %then %do; proxyport=%superq(proxyport) %end;
          %if (%length(%superq(proxyuser)) or %length(%superq(proxypassword))) %then %do;
            proxyusername="%superq(proxyuser)" proxypassword="%superq(proxypassword)"
          %end;
        %end;
        ;
        headers "Accept" = "&accept";
    run;
  %end;
  %else %do;
    proc http
        url="%superq(geturl)"
        method="get"
        out=&out_fileref
        headerout=&headerout_fileref
        timeout=&timeout
        %if (%length(%superq(webuser))) %then %do;
          webusername="%superq(webuser)" webpassword="%superq(webpassword)"
        %end;
        %if (%length(%superq(proxyhost))) %then %do;
          proxyhost="%superq(proxyhost)"
          %if (%length(%superq(proxyport))) %then %do; proxyport=%superq(proxyport) %end;
          %if (%length(%superq(proxyuser)) or %length(%superq(proxypassword))) %then %do;
            proxyusername="%superq(proxyuser)" proxypassword="%superq(proxypassword)"
          %end;
        %end;
        ;
        headers "Accept" = "&accept";
    run;
  %end;

  /* Optionen wiederherstellen (Spec 7) */
  options &sopt;

  /* ================= Status uebernehmen (Spec 3.2 / V8) ============= */
  %let raw = ;
  %if %symexist(SYS_PROCHTTP_STATUS_CODE) %then %let raw = &SYS_PROCHTTP_STATUS_CODE;
  %let raw = %sysfunc(strip(&raw));
  %if (%length(&raw) = 0) %then %let sparql_http_status = 000;
  %else %if (%sysfunc(verify(&raw, 0123456789)) ne 0) %then %let sparql_http_status = 000;
  %else %let sparql_http_status = &raw;

  /* interne headerout aufraeumen */
  %if (&ownhdr and &debug ne Y) %then %do; filename _sqhdr clear; %end;

  /* rc aus Status (2xx = ok) */
  %if not (&sparql_http_status >= 200 and &sparql_http_status <= 299) %then %do;
    %let sparql_rc  = 2;
    %let sparql_msg = &macnm.: HTTP-Status &sparql_http_status (kein 2xx).;
    %put ERROR: &sparql_msg;
  %end;
  %else %if (&debug = Y) %then %do;
    %put NOTE: &macnm.: HTTP &sparql_http_status (&method &queryform/&resultformat).;
  %end;

%mend sparql_execute;
