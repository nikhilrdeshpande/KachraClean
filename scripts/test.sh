#!/bin/sh
# Runs the test suite. With only the Command Line Tools installed (no Xcode), the Testing
# framework lives outside the default search paths, so point the compiler and linker at it.
set -e
CLT=/Library/Developer/CommandLineTools/Library/Developer
if xcodebuild -version >/dev/null 2>&1; then
  exec swift test "$@"
fi
exec swift test \
  -Xswiftc -F -Xswiftc "$CLT/Frameworks" \
  -Xlinker -F -Xlinker "$CLT/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
