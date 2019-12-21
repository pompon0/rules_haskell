#!/bin/sh

set -eux

V=1.1.0

curl -LO https://github.com/bazelbuild/bazel/releases/download/$V/bazel-$V-installer-linux-x86_64.sh
chmod +x bazel-$V-installer-linux-x86_64.sh
./bazel-$V-installer-linux-x86_64.sh --user
