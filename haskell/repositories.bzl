"""Workspace rules (repositories)"""

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

def rules_haskell_dependencies():
    """Provide all repositories that are necessary for `rules_haskell` to
    function.
    """
    excludes = native.existing_rules().keys()

    if "bazel_skylib" not in excludes:
        http_archive(
            name = "bazel_skylib",
            sha256 = "eb5c57e4c12e68c0c20bc774bfbc60a568e800d025557bc4ea022c6479acc867",
            strip_prefix = "bazel-skylib-0.6.0",
            urls = ["https://github.com/bazelbuild/bazel-skylib/archive/0.6.0.tar.gz"],
        )

    if "rules_sh" not in excludes:
        http_archive(
            name = "rules_sh",
            sha256 = "2613156e96b41fe0f91ac86a65edaea7da910b7130f2392ca02e8270f674a734",
            strip_prefix = "rules_sh-0.1.0",
            urls = ["https://github.com/tweag/rules_sh/archive/v0.1.0.tar.gz"],
        )

    if "io_tweag_rules_nixpkgs" not in excludes:
        http_archive(
            name = "io_tweag_rules_nixpkgs",
            sha256 = "f5af641e16fcff5b24f1a9ba5d93cab5ad26500271df59ede344f1a56fc3b17d",
            strip_prefix = "rules_nixpkgs-0.6.0",
            urls = ["https://github.com/tweag/rules_nixpkgs/archive/v0.6.0.tar.gz"],
        )

def haskell_repositories():
    """DEPRECATED alias for rules_haskell_dependencies"""
    rules_haskell_dependencies()
