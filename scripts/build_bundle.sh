#!/usr/bin/env bash
#
# build_bundle.sh — konkateniert macros/*.sas in FESTER Reihenfolge zu
# sparqlquery_bundle.sas und stellt einen Header mit Version/Commit/Datum
# voran (Spec 8.1/8.2).
#
# Nutzung:  scripts/build_bundle.sh [VERSION] [COMMIT] [BUILD_DATE]
# Im CI:    scripts/build_bundle.sh "${GITHUB_REF_NAME}" "${GITHUB_SHA}"
#
set -euo pipefail

VERSION="${1:-dev}"
COMMIT="${2:-local}"
BUILD_DATE="${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

SRC_DIR="macros"
OUT="sparqlquery_bundle.sas"

# Reihenfolge zwingend: sparqlquery setzt die anderen drei voraus.
ORDER=(
  "sparql_build_request.sas"
  "sparql_execute.sas"
  "sparql_parse_response.sas"
  "sparqlquery.sas"
)

{
  echo "/*=========================================================================="
  echo "  sparqlquery_bundle.sas  —  GENERIERTES Bundle, NICHT von Hand bearbeiten."
  echo "  Version : ${VERSION}"
  echo "  Commit  : ${COMMIT}"
  echo "  Datum   : ${BUILD_DATE}"
  echo "  Quelle  : macros/  (Build: scripts/build_bundle.sh)"
  echo "==========================================================================*/"
  echo ""
  for f in "${ORDER[@]}"; do
    echo "/* ---------- ${f} ---------- */"
    cat "${SRC_DIR}/${f}"
    echo ""
  done
} > "${OUT}"

echo "Wrote ${OUT} ($(wc -l < "${OUT}") Zeilen)."
