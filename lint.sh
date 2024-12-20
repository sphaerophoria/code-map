#!/bin/sh

set -ex

zig fmt src --check
zig build
