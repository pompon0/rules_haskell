#!/bin/sh

# Run the start script in its own workspace
# and build the example binary target.

set -e

pwd=$(pwd)
cd $(mktemp -d)
# arguments are passed on to the start script
$pwd/start "$@"

# Set Nixpkgs in environment variable to avoid hardcoding it in
# start script itself.

# overrides the used rules_haskell, because
# when we're testing the start on a feature branch (CI),
# the latest rules_haskell version doesn't always work.
# If on the branch we update Bazel to a version with breaking
# changes, then we need to adapt to those changes in the branch.
# Which in turn means the start script should pull in those changes too.

NIX_PATH=nixpkgs=$pwd/nixpkgs/default.nix \
  bazel run \
  --config=ci \
  --override_repository=rules_haskell=$pwd \
  //:example
