#!/bin/bash
# Build OLS PRO natively on AlmaLinux 9 (run inside the olspro-dev container).
# Usage: pro/server/build.sh   (from the source root, e.g. /root/olspro)
# Upstream build.sh fetches+builds BoringSSL/brotli/udns/ModSecurity into
# ../third-party, then CMake. Current brotli names its libs without the
# "-static" suffix upstream asks for, so the first pass links-fails once; we
# add the symlinks and run again (incremental, takes seconds).
set -u
cd "$(dirname "$0")/../.."
rm -rf lsquic && git submodule update --init --recursive lsquic
./build.sh -p OFF -o ON -l OFF
for l in common dec enc; do ln -sf libbrotli$l.a ../third-party/lib/libbrotli$l-static.a; done
./build.sh -p OFF -o ON -l OFF
ls -l build/src/openlitespeed 2>&1 && build/src/openlitespeed -v
