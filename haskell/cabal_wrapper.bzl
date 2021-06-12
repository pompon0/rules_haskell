load("@rules_python//python:defs.bzl", "py_binary")

def cabal_wrapper(name, **kwargs):
    py_binary(
        name = name,
        srcs = ["@rules_haskell//haskell:private/cabal_wrapper.py"],
        srcs_version = "PY3",
        python_version = "PY3",
        deps = [
            "@bazel_tools//tools/python/runfiles",
        ],
        **kwargs
    )
