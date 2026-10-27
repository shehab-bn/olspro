#!/bin/sh
# OLS PRO - build and run the std-only ESI parser tests.
#   ESI_SANITIZE=1  build with ASan/UBSan (looser timing bound)
#   CXX=g++         pick the compiler
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/olspro_test_esi.$$
trap 'rm -f "$out"' EXIT INT TERM
CXX=${CXX:-c++}
bound=0.25; amp=2.0
[ -n "$ESI_SANITIZE" ] && bound=3.0 && amp=20
$CXX -std=c++17 -O2 -g -Wall -Wextra -Werror \
    ${ESI_SANITIZE:+-fsanitize=address,undefined} -DESI_TIME_BOUND=$bound -DESI_AMP_BOUND=$amp \
    "$here/../esiparser.cpp" "$here/test_esi.cpp" -o "$out"
set +e
"$out"
rc=$?
exit $rc
