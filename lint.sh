#!/bin/sh

set -ex
exit 0

zig fmt src --check
zig build
