#!/bin/sh
# Builds and runs the apacheconf fixture test with the host C++ compiler.
set -e
cd "$(dirname "$0")"
${CXX:-c++} -std=c++17 -Wall -Wextra -O1 -o /tmp/test_apacheconf test_apacheconf.cpp ../../../src/main/apacheconf.cpp
/tmp/test_apacheconf fixtures
