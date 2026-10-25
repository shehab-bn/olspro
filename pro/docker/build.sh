#!/bin/bash
# Build OLS PRO inside the olspro-build image using upstream's build.sh.
# Works on a copy of the tree in a named volume so third-party artifacts
# (BoringSSL, brotli, udns, ...) never pollute the git working tree and
# rebuilds are incremental.   Usage: pro/docker/build.sh [extra build.sh args]
set -euo pipefail
cd "$(dirname "$0")/../.."
docker --context colima-olspro run --rm -v "$PWD":/host:ro -v olspro-build-cache:/build olspro-build bash -c '
  set -euo pipefail
  mkdir -p /build/src
  rsync -a --delete --exclude=/graft \
        --exclude=/boringssl --exclude="/brotli*" --exclude="/udns*" --exclude=/ssl --exclude=/lsquic \
        --exclude="/libmaxminddb*" --exclude="/IP2Location*" --exclude=/build --exclude=/third-party \
        /host/ /build/src/
  cd /build/src
  # newer brotli drops the -static suffix upstream's CMake still asks for
  for l in common dec enc; do ln -sf libbrotli$l.a /build/third-party/lib/libbrotli$l-static.a; done
  rm -rf lsquic && git -c protocol.file.allow=always submodule update --init --recursive lsquic
  ./build.sh -p OFF -o ON -l OFF '"$*"'
  ls -l build/openlitespeed && build/openlitespeed -v || true
'
