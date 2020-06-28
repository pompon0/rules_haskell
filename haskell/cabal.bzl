"""Cabal packages"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("//vendor/bazel_json/lib:json_parser.bzl", "json_parse")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load(":cc.bzl", "cc_interop_info")
load(":private/actions/info.bzl", "library_info_output_groups")
load(":private/context.bzl", "haskell_context", "render_env")
load(":private/dependencies.bzl", "gather_dep_info")
load(":private/expansions.bzl", "expand_make_variables")
load(":private/mode.bzl", "is_profiling_enabled")
load(
    ":private/path_utils.bzl",
    "create_rpath_entry",
    "join_path_list",
    "relative_rpath_prefix",
    "truly_relativize",
)
load(":private/set.bzl", "set")
load(":private/typing.bzl", "typecheck_stackage_extradeps")
load(":haddock.bzl", "generate_unified_haddock_info")
load(
    ":private/workspace_utils.bzl",
    _execute_or_fail_loudly = "execute_or_fail_loudly",
)
load(
    ":providers.bzl",
    "HaddockInfo",
    "HaskellInfo",
    "HaskellLibraryInfo",
    "all_dependencies_package_ids",
)
load(
    ":private/cc_libraries.bzl",
    "deps_HaskellCcLibrariesInfo",
    "get_cc_libraries",
    "get_ghci_library_files",
    "get_library_files",
    "haskell_cc_libraries_aspect",
)

def _so_extension(hs):
    return "dylib" if hs.toolchain.is_darwin else "so"

def _dirname(file):
    return file.dirname

def _version(name):
    """Return the version component of a package name."""
    return name.rpartition("-")[2]

def _has_version(name):
    """Check whether a package identifier has a version component."""
    return name.rpartition("-")[2].replace(".", "").isdigit()

def _chop_version(name):
    """Remove any version component from the given package name."""
    return name.rpartition("-")[0]

def _find_cabal(hs, srcs):
    """Check that a .cabal file exists. Choose the root one."""
    cabal = None
    for f in srcs:
        if f.extension == "cabal":
            if not cabal or f.dirname < cabal.dirname:
                cabal = f
    if not cabal:
        fail("A .cabal file was not found in the srcs attribute.")
    return cabal

def _find_setup(hs, cabal, srcs):
    """Check that a Setup script exists. If not, create a default one."""
    setup = None
    for f in srcs:
        if f.basename in ["Setup.hs", "Setup.lhs"]:
            if not setup or f.dirname < setup.dirname:
                setup = f
    if not setup:
        setup = hs.actions.declare_file("Setup.hs", sibling = cabal)
        hs.actions.write(
            output = setup,
            content = """
module Main where
import Distribution.Simple

main :: IO ()
main = defaultMain
""",
        )
    return setup

_CABAL_TOOLS = ["alex", "c2hs", "cpphs", "doctest", "happy"]

# Some old packages are empty compatibility shims. Empty packages
# cause Cabal to not produce the outputs it normally produces. Instead
# of detecting that, we blacklist the offending packages, on the
# assumption that such packages are old and rare.
#
# TODO: replace this with a more general solution.
_EMPTY_PACKAGES_BLACKLIST = [
    "bytestring-builder",
    "fail",
    "mtl-compat",
    "nats",
]

def _cabal_tool_flag(tool):
    """Return a --with-PROG=PATH flag if input is a recognized Cabal tool. None otherwise."""
    if tool.basename in _CABAL_TOOLS:
        return "--with-{}={}".format(tool.basename, tool.path)

def _binary_paths(binaries):
    return [binary.dirname for binary in binaries.to_list()]

def _concat(sequences):
    return [item for sequence in sequences for item in sequence]

def _prepare_cabal_inputs(
        hs,
        cc,
        posix,
        dep_info,
        cc_info,
        direct_cc_info,
        component,
        package_id,
        tool_inputs,
        tool_input_manifests,
        cabal,
        setup,
        setup_deps,
        setup_dep_info,
        srcs,
        compiler_flags,
        flags,
        generate_haddock,
        cabal_wrapper,
        package_database,
        verbose,
        transitive_haddocks,
        dynamic_binary = None):
    """Compute Cabal wrapper, arguments, inputs."""
    with_profiling = is_profiling_enabled(hs)

    # Haskell library dependencies or indirect C library dependencies are
    # already covered by their corresponding package-db entries. We only need
    # to add libraries and headers for direct C library dependencies to the
    # command line.
    direct_libs = get_ghci_library_files(hs, cc.cc_libraries_info, cc.cc_libraries)

    # The regular Haskell rules perform mostly static linking, i.e. where
    # possible all C library dependencies are linked statically. Cabal has no
    # such mode, and since we have to provide dynamic C libraries for
    # compilation, they will also be used for linking. Hence, we need to add
    # RUNPATH flags for all dynamic C library dependencies. Cabal also produces
    # a dynamic and a static Haskell library in one go. The dynamic library
    # will link other Haskell libraries dynamically. For those we need to also
    # provide RUNPATH flags for dynamic Haskell libraries.
    (_, dynamic_libs) = get_library_files(
        hs,
        cc.cc_libraries_info,
        cc.transitive_libraries,
        dynamic = True,
    )

    # Executables build by Cabal will link Haskell libraries statically, so we
    # only need to include dynamic C libraries in the runfiles tree.
    (_, runfiles_libs) = get_library_files(
        hs,
        cc.cc_libraries_info,
        get_cc_libraries(cc.cc_libraries_info, cc.transitive_libraries),
        dynamic = True,
    )

    # Setup dependencies are loaded by runghc.
    setup_libs = get_ghci_library_files(hs, cc.cc_libraries_info, cc.setup_libraries)

    # The regular Haskell rules have separate actions for linking and
    # compilation to which we pass different sets of libraries as inputs. The
    # Cabal rules, in contrast, only have a single action for compilation and
    # linking, so we must provide both sets of libraries as inputs to the same
    # action.
    transitive_compile_libs = get_ghci_library_files(hs, cc.cc_libraries_info, cc.transitive_libraries)
    transitive_link_libs = _concat(get_library_files(hs, cc.cc_libraries_info, cc.transitive_libraries))
    env = dict(hs.env)
    env["PATH"] = join_path_list(hs, _binary_paths(tool_inputs) + posix.paths)
    if hs.toolchain.is_darwin:
        env["SDKROOT"] = "macosx"  # See haskell/private/actions/link.bzl

    if verbose:
        env["CABAL_VERBOSE"] = "True"

    args = hs.actions.args()
    package_databases = dep_info.package_databases
    transitive_headers = cc_info.compilation_context.headers
    direct_include_dirs = depset(transitive = [
        direct_cc_info.compilation_context.includes,
        direct_cc_info.compilation_context.quote_includes,
        direct_cc_info.compilation_context.system_includes,
    ])
    direct_lib_dirs = [file.dirname for file in direct_libs]
    args.add_all([component, package_id, generate_haddock, setup, cabal.dirname, package_database.dirname])
    args.add_joined([
        arg
        for package_id in setup_deps
        for arg in ["-package-id", package_id]
    ] + [
        arg
        for package_db in setup_dep_info.package_databases.to_list()
        for arg in ["-package-db", "./" + _dirname(package_db)]
    ], join_with = " ", format_each = "--ghc-arg=%s", omit_if_empty = False)
    args.add("--flags=" + " ".join(flags))
    args.add_all(compiler_flags, format_each = "--ghc-option=%s")
    if dynamic_binary:
        args.add_all(
            [
                "--ghc-option=-optl-Wl,-rpath," + create_rpath_entry(
                    binary = dynamic_binary,
                    dependency = lib,
                    keep_filename = False,
                    prefix = relative_rpath_prefix(hs.toolchain.is_darwin),
                )
                for lib in dynamic_libs
            ],
            uniquify = True,
        )
    args.add("--")
    args.add_all(package_databases, map_each = _dirname, format_each = "--package-db=%s")
    args.add_all(direct_include_dirs, format_each = "--extra-include-dirs=%s")
    args.add_all(direct_lib_dirs, format_each = "--extra-lib-dirs=%s", uniquify = True)
    if with_profiling:
        args.add("--enable-profiling")

    # Redundant with _binary_paths() above, but better be explicit when we can.
    args.add_all(tool_inputs, map_each = _cabal_tool_flag)

    inputs = depset(
        [setup, hs.tools.ghc, hs.tools.ghc_pkg, hs.tools.runghc],
        transitive = [
            depset(srcs),
            depset(cc.files),
            package_databases,
            setup_dep_info.package_databases,
            transitive_headers,
            depset(setup_libs),
            depset(transitive_compile_libs),
            depset(transitive_link_libs),
            depset(transitive_haddocks),
            setup_dep_info.interface_dirs,
            setup_dep_info.hs_libraries,
            dep_info.interface_dirs,
            dep_info.hs_libraries,
            tool_inputs,
        ],
    )
    input_manifests = tool_input_manifests + hs.toolchain.cc_wrapper.manifests

    return struct(
        cabal_wrapper = cabal_wrapper,
        args = args,
        inputs = inputs,
        input_manifests = input_manifests,
        env = env,
        runfiles = depset(direct = runfiles_libs),
    )

def _gather_transitive_haddocks(deps):
    transitive_haddocks_list = []
    for dep in deps:
        if HaddockInfo in dep:
            for haddock_files in dep[HaddockInfo].transitive_haddocks.values():
                transitive_haddocks_list.extend(haddock_files)
    return depset(
        direct = transitive_haddocks_list,
    )

def _shorten_library_symlink(dynamic_library):
    prefix = dynamic_library.owner.workspace_root.replace("_", "_U").replace("/", "_S")
    basename = dynamic_library.basename
    return paths.join(prefix, basename)

def _haskell_cabal_library_impl(ctx):
    hs = haskell_context(ctx)
    dep_info = gather_dep_info(ctx, ctx.attr.deps)
    setup_dep_info = gather_dep_info(ctx, ctx.attr.setup_deps)
    setup_deps = all_dependencies_package_ids(ctx.attr.setup_deps)
    cc = cc_interop_info(ctx)

    # All C and Haskell library dependencies.
    cc_info = cc_common.merge_cc_infos(
        cc_infos = [dep[CcInfo] for dep in ctx.attr.deps if CcInfo in dep],
    )

    # Separate direct C library dependencies.
    direct_cc_info = cc_common.merge_cc_infos(
        cc_infos = [
            dep[CcInfo]
            for dep in ctx.attr.deps
            if CcInfo in dep and not HaskellInfo in dep
        ],
    )
    posix = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"]
    package_name = ctx.attr.package_name if ctx.attr.package_name else hs.label.name
    package_id = "{}-{}".format(
        package_name,
        ctx.attr.version,
    )
    with_profiling = is_profiling_enabled(hs)

    user_compile_flags = _expand_make_variables("compiler_flags", ctx, ctx.attr.compiler_flags)
    cabal = _find_cabal(hs, ctx.files.srcs)
    setup = _find_setup(hs, cabal, ctx.files.srcs)
    package_database = hs.actions.declare_file(
        "_install/{}.conf.d/package.cache".format(package_id),
        sibling = cabal,
    )
    interfaces_dir = hs.actions.declare_directory(
        "_install/{}_iface".format(package_id),
        sibling = cabal,
    )
    data_dir = hs.actions.declare_directory(
        "_install/{}_data".format(package_id),
        sibling = cabal,
    )
    if ctx.attr.haddock:
        haddock_file = hs.actions.declare_file(
            "_install/{}_haddock/{}.haddock".format(package_id, package_name),
            sibling = cabal,
        )
        haddock_html_dir = hs.actions.declare_directory(
            "_install/{}_haddock_html".format(package_id),
            sibling = cabal,
        )
    else:
        haddock_file = None
        haddock_html_dir = None
    vanilla_library = hs.actions.declare_file(
        "_install/lib/libHS{}.a".format(package_id),
        sibling = cabal,
    )
    if with_profiling:
        profiling_library = hs.actions.declare_file(
            "_install/lib/libHS{}_p.a".format(package_id),
            sibling = cabal,
        )
        static_library = profiling_library
    else:
        profiling_library = None
        static_library = vanilla_library
    if hs.toolchain.is_static:
        dynamic_library = None
    else:
        dynamic_library = hs.actions.declare_file(
            "_install/lib/libHS{}-ghc{}.{}".format(
                package_id,
                hs.toolchain.version,
                _so_extension(hs),
            ),
            sibling = cabal,
        )
    (tool_inputs, tool_input_manifests) = ctx.resolve_tools(tools = ctx.attr.tools)
    c = _prepare_cabal_inputs(
        hs,
        cc,
        posix,
        dep_info,
        cc_info,
        direct_cc_info,
        component = "lib:{}".format(
            ctx.attr.package_name if ctx.attr.package_name else hs.label.name,
        ),
        package_id = package_id,
        tool_inputs = tool_inputs,
        tool_input_manifests = tool_input_manifests,
        cabal = cabal,
        setup = setup,
        setup_deps = setup_deps,
        setup_dep_info = setup_dep_info,
        srcs = ctx.files.srcs,
        compiler_flags = user_compile_flags,
        flags = ctx.attr.flags,
        generate_haddock = ctx.attr.haddock,
        cabal_wrapper = ctx.executable._cabal_wrapper,
        package_database = package_database,
        verbose = ctx.attr.verbose,
        dynamic_binary = dynamic_library,
        transitive_haddocks = _gather_transitive_haddocks(ctx.attr.deps),
    )
    outputs = [
        package_database,
        interfaces_dir,
        vanilla_library,
        data_dir,
    ]
    if ctx.attr.haddock:
        outputs.extend([haddock_file, haddock_html_dir])
    if dynamic_library != None:
        outputs.append(dynamic_library)
    if with_profiling:
        outputs.append(profiling_library)
    ctx.actions.run(
        executable = c.cabal_wrapper,
        arguments = [c.args],
        inputs = c.inputs,
        input_manifests = c.input_manifests,
        tools = [c.cabal_wrapper],
        outputs = outputs,
        env = c.env,
        mnemonic = "HaskellCabalLibrary",
        progress_message = "HaskellCabalLibrary {}".format(hs.label),
    )

    default_info = DefaultInfo(
        files = depset([static_library] + ([dynamic_library] if dynamic_library != None else [])),
        runfiles = ctx.runfiles(
            files = [data_dir],
            collect_default = True,
        ),
    )
    hs_info = HaskellInfo(
        package_databases = depset([package_database], transitive = [dep_info.package_databases]),
        version_macros = set.empty(),
        source_files = depset(),
        extra_source_files = depset(),
        import_dirs = set.empty(),
        hs_libraries = depset(
            direct = [lib for lib in [vanilla_library, dynamic_library, profiling_library] if lib],
            transitive = [dep_info.hs_libraries],
            order = "topological",
        ),
        interface_dirs = depset([interfaces_dir], transitive = [dep_info.interface_dirs]),
        compile_flags = [],
    )
    lib_info = HaskellLibraryInfo(package_id = package_id, version = None, exports = [])
    if ctx.attr.haddock:
        doc_info = generate_unified_haddock_info(
            this_package_id = package_id,
            this_package_html = haddock_html_dir,
            this_package_haddock = haddock_file,
            deps = ctx.attr.deps,
        )
    else:
        doc_info = None
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    library_to_link = cc_common.create_library_to_link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        dynamic_library = dynamic_library,
        dynamic_library_symlink_path =
            _shorten_library_symlink(dynamic_library) if dynamic_library and ctx.attr.unique_name else "",
        static_library = static_library,
        cc_toolchain = cc_toolchain,
    )
    compilation_context = cc_common.create_compilation_context()
    linking_context = cc_common.create_linking_context(
        libraries_to_link = [library_to_link],
    )
    cc_info = cc_common.merge_cc_infos(
        cc_infos = [
            CcInfo(
                compilation_context = compilation_context,
                linking_context = linking_context,
            ),
            cc_info,
        ],
    )
    output_group_info = OutputGroupInfo(**library_info_output_groups(
        name = ctx.label.name,
        hs = hs,
        hs_info = hs_info,
        lib_info = lib_info,
    ))
    result = [default_info, hs_info, cc_info, lib_info, output_group_info]
    if ctx.attr.haddock:
        result.append(doc_info)
    return result

haskell_cabal_library = rule(
    _haskell_cabal_library_impl,
    attrs = {
        "package_name": attr.string(
            doc = "Cabal package name. Defaults to name attribute.",
        ),
        "version": attr.string(
            doc = "Version of the Cabal package.",
            mandatory = True,
        ),
        "haddock": attr.bool(
            default = True,
            doc = "Whether to generate haddock documentation.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "All files required to build the package, including the Cabal file.",
        ),
        "deps": attr.label_list(
            aspects = [haskell_cc_libraries_aspect],
            doc = "Package build dependencies. Note, setup dependencies need to be declared separately using `setup_deps`.",
        ),
        "setup_deps": attr.label_list(
            aspects = [haskell_cc_libraries_aspect],
            doc = "Dependencies for custom setup Setup.hs.",
        ),
        "compiler_flags": attr.string_list(
            doc = """Flags to pass to Haskell compiler, in addition to those defined
            the cabal file. Subject to Make variable substitution.""",
        ),
        "tools": attr.label_list(
            cfg = "host",
            allow_files = True,
            doc = """Tool dependencies. They are built using the host configuration, since
            the tools are executed as part of the build.""",
        ),
        "flags": attr.string_list(
            doc = "List of Cabal flags, will be passed to `Setup.hs configure --flags=...`.",
        ),
        "_cabal_wrapper": attr.label(
            executable = True,
            cfg = "host",
            default = Label("@rules_haskell//haskell:cabal_wrapper"),
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
        "verbose": attr.bool(
            default = True,
            doc = "Whether to show the output of the build",
        ),
        "unique_name": attr.bool(
            default = False,
            doc = """Whether the library name is known to be unique within the
            workspace. This is used by `stack_snapshot` where library names are
            known to be unique within the snapshot. If true, then the dynamic
            library symlink underneath `_solib_<cpu>` will be shortened to
            avoid exceeding the MACH-O header size limit on MacOS.""",
        ),
    },
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
        "@rules_haskell//haskell:toolchain",
        "@rules_sh//sh/posix:toolchain_type",
    ],
    fragments = ["cpp"],
    doc = """\
Use Cabal to build a library.

### Examples

  ```bzl
  haskell_cabal_library(
      name = "lib-0.1.0.0",
      srcs = ["lib.cabal", "Lib.hs", "Setup.hs"],
  )

  haskell_toolchain_library(name = "base")

  haskell_binary(
      name = "bin",
      deps = [":base", ":lib-0.1.0.0"],
      srcs = ["Main.hs"],
  )
  ```

This rule does not use `cabal-install`. It calls the package's
`Setup.hs` script directly if one exists, or the default one if not.
All sources files that would have been part of a Cabal sdist need to
be listed in `srcs` (crucially, including the `.cabal` file).
A `haskell_cabal_library` can be substituted for any
`haskell_library`. The two are interchangeable in most contexts.
However, using a plain `haskell_library` sometimes leads to better
build times, and does not require drafting a `.cabal` file.

""",
)

def _haskell_cabal_binary_impl(ctx):
    hs = haskell_context(ctx)
    dep_info = gather_dep_info(ctx, ctx.attr.deps)
    setup_dep_info = gather_dep_info(ctx, ctx.attr.setup_deps)
    setup_deps = all_dependencies_package_ids(ctx.attr.setup_deps)
    cc = cc_interop_info(ctx)

    # All C and Haskell library dependencies.
    cc_info = cc_common.merge_cc_infos(
        cc_infos = [dep[CcInfo] for dep in ctx.attr.deps if CcInfo in dep],
    )
    package_id = "{}-{}".format(
        hs.label.name,
        ctx.attr.version,
    )

    # Separate direct C library dependencies.
    direct_cc_info = cc_common.merge_cc_infos(
        cc_infos = [
            dep[CcInfo]
            for dep in ctx.attr.deps
            if CcInfo in dep and not HaskellInfo in dep
        ],
    )
    posix = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"]

    exe_name = ctx.attr.exe_name if ctx.attr.exe_name else hs.label.name
    user_compile_flags = _expand_make_variables("compiler_flags", ctx, ctx.attr.compiler_flags)
    cabal = _find_cabal(hs, ctx.files.srcs)
    setup = _find_setup(hs, cabal, ctx.files.srcs)
    package_database = hs.actions.declare_file(
        "_install/{}.conf.d/package.cache".format(package_id),
        sibling = cabal,
    )
    binary = hs.actions.declare_file(
        "_install/bin/{name}{ext}".format(
            name = exe_name,
            ext = ".exe" if hs.toolchain.is_windows else "",
        ),
        sibling = cabal,
    )
    data_dir = hs.actions.declare_directory(
        "_install/{}_data".format(package_id),
        sibling = cabal,
    )
    (tool_inputs, tool_input_manifests) = ctx.resolve_tools(tools = ctx.attr.tools)
    c = _prepare_cabal_inputs(
        hs,
        cc,
        posix,
        dep_info,
        cc_info,
        direct_cc_info,
        component = "exe:{}".format(exe_name),
        package_id = package_id,
        tool_inputs = tool_inputs,
        tool_input_manifests = tool_input_manifests,
        cabal = cabal,
        setup = setup,
        setup_deps = setup_deps,
        setup_dep_info = setup_dep_info,
        srcs = ctx.files.srcs,
        compiler_flags = user_compile_flags,
        flags = ctx.attr.flags,
        generate_haddock = False,
        cabal_wrapper = ctx.executable._cabal_wrapper,
        package_database = package_database,
        verbose = ctx.attr.verbose,
        dynamic_binary = binary,
        transitive_haddocks = _gather_transitive_haddocks(ctx.attr.deps),
    )
    ctx.actions.run(
        executable = c.cabal_wrapper,
        arguments = [c.args],
        inputs = c.inputs,
        input_manifests = c.input_manifests,
        outputs = [
            package_database,
            binary,
            data_dir,
        ],
        tools = [c.cabal_wrapper],
        env = c.env,
        mnemonic = "HaskellCabalBinary",
        progress_message = "HaskellCabalBinary {}".format(hs.label),
    )

    hs_info = HaskellInfo(
        package_databases = dep_info.package_databases,
        version_macros = set.empty(),
        source_files = depset(),
        extra_source_files = depset(),
        import_dirs = set.empty(),
        hs_libraries = dep_info.hs_libraries,
        interface_dirs = dep_info.interface_dirs,
        compile_flags = [],
    )
    default_info = DefaultInfo(
        files = depset([binary]),
        executable = binary,
        runfiles = ctx.runfiles(
            files = [data_dir],
            transitive_files = c.runfiles,
            collect_default = True,
        ),
    )

    return [hs_info, cc_info, default_info]

haskell_cabal_binary = rule(
    _haskell_cabal_binary_impl,
    executable = True,
    attrs = {
        "version": attr.string(
            doc = "Version of the Cabal package.",
            mandatory = True,
        ),
        "exe_name": attr.string(
            doc = "Cabal executable component name. Defaults to the value of the name attribute.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "All files required to build the package, including the Cabal file.",
        ),
        "deps": attr.label_list(
            aspects = [haskell_cc_libraries_aspect],
            doc = "Package build dependencies. Note, setup dependencies need to be declared separately using `setup_deps`.",
        ),
        "setup_deps": attr.label_list(
            aspects = [haskell_cc_libraries_aspect],
            doc = "Dependencies for custom setup Setup.hs.",
        ),
        "compiler_flags": attr.string_list(
            doc = """Flags to pass to Haskell compiler, in addition to those defined
            the cabal file. Subject to Make variable substitution.""",
        ),
        "tools": attr.label_list(
            cfg = "host",
            doc = """Tool dependencies. They are built using the host configuration, since
            the tools are executed as part of the build.""",
        ),
        "flags": attr.string_list(
            doc = "List of Cabal flags, will be passed to `Setup.hs configure --flags=...`.",
        ),
        "_cabal_wrapper": attr.label(
            executable = True,
            cfg = "host",
            default = Label("@rules_haskell//haskell:cabal_wrapper"),
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
        "verbose": attr.bool(
            default = True,
            doc = "Whether to show the output of the build",
        ),
    },
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
        "@rules_haskell//haskell:toolchain",
        "@rules_sh//sh/posix:toolchain_type",
    ],
    fragments = ["cpp"],
    doc = """\
Use Cabal to build a binary.

### Examples

  ```bzl
  haskell_cabal_binary(
      name = "happy",
      srcs = glob(["**"]),
  )
  ```

This rule assumes that the .cabal file defines a single executable
with the same name as the package.

This rule does not use `cabal-install`. It calls the package's
`Setup.hs` script directly if one exists, or the default one if not.
All sources files that would have been part of a Cabal sdist need to
be listed in `srcs` (crucially, including the `.cabal` file).

""",
)

# Temporary hardcoded list of core libraries. This will no longer be
# necessary once Stack 2.0 is released.
#
# TODO remove this list and replace it with Stack's --global-hints
# mechanism.
_CORE_PACKAGES = [
    "Cabal",
    "array",
    "base",
    "binary",
    "bytestring",
    "containers",
    "deepseq",
    "directory",
    "filepath",
    "ghc",
    "ghc-boot",
    "ghc-boot-th",
    "ghc-compact",
    "ghc-heap",
    "ghc-prim",
    "ghci",
    "haskeline",
    "hpc",
    "integer-gmp",
    "integer-simple",
    "libiserv",
    "mtl",
    "parsec",
    "pretty",
    "process",
    "rts",
    "stm",
    "template-haskell",
    "terminfo",
    "text",
    "time",
    "transformers",
    "unix",
    "Win32",
    "xhtml",
]

_STACK_DEFAULT_VERSION = "2.3.1"

# Only ever need one version, but use same structure as for GHC bindists.
_STACK_BINDISTS = \
    {
        "2.3.1": {
            "linux-x86_64": (
                "https://github.com/commercialhaskell/stack/releases/download/v2.3.1/stack-2.3.1-linux-x86_64-static.tar.gz",
                "4bae8830b2614dddf3638a6d1a7bbbc3a5a833d05b2128eae37467841ac30e47",
            ),
            "osx-x86_64": (
                "https://github.com/commercialhaskell/stack/releases/download/v2.3.1/stack-2.3.1-osx-x86_64.tar.gz",
                "73eee7e5f24d11fd0af00cb05f16119e86be5d578c35083250e6b85ed1ca3621",
            ),
            "windows-x86_64": (
                "https://github.com/commercialhaskell/stack/releases/download/v2.3.1/stack-2.3.1-windows-x86_64.tar.gz",
                "440588c92ffcb42b88fd6455dc68728dae9b08bdd1a683d1cf5f80aa9aa8b014",
            ),
        },
    }

def _stack_version_check(repository_ctx, stack_cmd):
    """Returns False if version not recent enough."""
    exec_result = _execute_or_fail_loudly(repository_ctx, [stack_cmd, "--numeric-version"])

    stack_major_version = int(exec_result.stdout.split(".")[0])
    stack_minor_version = int(exec_result.stdout.split(".")[1])
    return stack_major_version >= 2 and stack_minor_version >= 3

def _parse_components(package, components):
    """Parse and validate a list of Cabal components.

    Components take the following shape:
      * `lib`: The library component.
      * `lib:<package>`: The library component.
      * `exe`: The executable component `exe:<package>`.
      * `exe:<name>`: An executable component.

    Args:
      package: string, The package name.
      components: list of string, The Cabal components

    Returns:
      struct(lib, exe):
        lib: bool, Whether the package has a library component.
        exe: list of string, List of executables.
    """
    lib = False
    exe = []

    for component in components:
        if component == "lib":
            lib = True
        elif component.startswith("lib:"):
            if component == "lib:%s" % package:
                lib = True
            else:
                fail("Sublibrary components are not supported: %s in %s" % (component, package), "components")
        elif component == "exe":
            exe.append(package)
        elif component.startswith("exe:"):
            exe.append(component[4:])
        elif component.startswith("test"):
            fail("Cabal test components are not supported: %s in %s" % (component, package), "components")
        else:
            fail("Invalid Cabal component: %s in %s" % (component, package), "components")

    if package in _CORE_PACKAGES:
        if not lib or exe != []:
            fail("Invalid core package components: %s" % package, "components")

    return struct(lib = lib, exe = exe)

_default_components = {
    "alex": struct(lib = False, exe = ["alex"]),
    "c2hs": struct(lib = False, exe = ["c2hs"]),
    "cpphs": struct(lib = True, exe = ["cpphs"]),
    "doctest": struct(lib = True, exe = ["doctest"]),
    "happy": struct(lib = False, exe = ["happy"]),
}

def _get_components(components, package):
    """Look-up the components of a package.

    If the package is not listed in the user-defined components then it
    will be taken from the `_default_components`. If it is not listed
    there then it will default to a library and no executable components.
    """
    return components.get(package, _default_components.get(package, struct(lib = True, exe = [])))

def _validate_package_specs(package_specs):
    found_ty = type(package_specs)
    if found_ty != "list":
        fail("Unexpected output format for `stack ls dependencies json`. Expected 'list', but got '%s'." % found_ty)

def _validate_package_spec(package_spec):
    fields = [
        ("name", "string"),
        ("version", "string"),
        ("dependencies", "list"),
    ]
    for (field, ty) in fields:
        if not field in package_spec:
            fail("Unexpected output format for `stack ls dependencies json`. Missing field '%s'." % field)
        found_ty = type(package_spec[field])
        if found_ty != ty:
            fail("Unexpected output format for `stack ls dependencies json`. Expected field '%s' of type '%s', but got type '%s'." % (field, ty, found_ty))

def _compute_dependency_graph(repository_ctx, snapshot, core_packages, versioned_packages, unversioned_packages, vendored_packages, user_components):
    """Given a list of root packages, compute a dependency graph.

    Returns:
      dict(name: struct(name, version, versioned_name, deps, is_core_package, sdist)):
        name: The unversioned package name.
        version: The version of the package.
        versioned_name: <name>-<version>.
        flags: Cabal flags for this package.
        deps: The list of library dependencies.
        tools: The list of build tools.
        vendored: Label of vendored package, None if not vendored.
        user_components: Mapping from package names to Cabal components.
        is_core_package: Whether the package is a core package.
        sdist: directory name of the unpackaged source distribution or None if core package or vendored.

    """
    all_packages = {}
    for core_package in core_packages:
        all_packages[core_package] = struct(
            name = core_package,
            components = struct(lib = True, exe = []),
            version = None,
            versioned_name = None,
            flags = repository_ctx.attr.flags.get(core_package, []),
            deps = [],
            tools = [],
            vendored = None,
            is_core_package = True,
            sdist = None,
        )

    if not versioned_packages and not unversioned_packages and not vendored_packages:
        return all_packages

    # Create a dummy package depending on all requested packages.
    resolve_package = "rules-haskell-stack-resolve"
    repository_ctx.file(
        "{name}/{name}.cabal".format(name = resolve_package),
        executable = False,
        content = """\
name: {name}
cabal-version: >= 1.2
version: 1.0
library
  build-depends:
    {packages}
""".format(
            name = resolve_package,
            packages = ",\n    ".join(core_packages + unversioned_packages + vendored_packages.keys() + [
                _chop_version(pkg)
                for pkg in versioned_packages
            ]),
        ),
    )

    # Create a stack.yaml capturing user overrides to the snapshot.
    stack_yaml_content = struct(**{
        "resolver": str(snapshot),
        "packages": [resolve_package] + [
            # Determines path to vendored package's root directory relative to
            # stack.yaml. Note, this requires that the Cabal file exists in the
            # package root and is called `<name>.cabal`.
            truly_relativize(
                str(repository_ctx.path(label.relative(name + ".cabal")).dirname),
                relative_to = str(repository_ctx.path("stack.yaml").dirname),
            )
            for (name, label) in vendored_packages.items()
        ],
        "extra-deps": versioned_packages,
        "flags": {
            pkg: {
                flag[1:] if flag.startswith("-") else flag: not flag.startswith("-")
                for flag in flags
            }
            for (pkg, flags) in repository_ctx.attr.flags.items()
        },
    }).to_json()
    repository_ctx.file("stack.yaml", content = stack_yaml_content, executable = False)

    # Invoke stack to calculate the transitive dependencies.
    stack_cmd = repository_ctx.path(repository_ctx.attr.stack)
    if not _stack_version_check(repository_ctx, stack_cmd):
        fail("Stack version not recent enough. Need version 2.3 or newer.")
    stack = [stack_cmd]
    exec_result = _execute_or_fail_loudly(
        repository_ctx,
        stack + ["ls", "dependencies", "json", "--global-hints", "--external"],
    )
    package_specs = json_parse(exec_result.stdout)
    _validate_package_specs(package_specs)

    # Collect package metadata
    remaining_components = dict(**user_components)
    for package_spec in package_specs:
        _validate_package_spec(package_spec)
        name = package_spec["name"]
        if name == resolve_package:
            continue
        version = package_spec["version"]
        package = "%s-%s" % (name, version)
        vendored = vendored_packages.get(name, None)
        is_core_package = name in _CORE_PACKAGES
        all_packages[name] = struct(
            name = name,
            components = _get_components(remaining_components, name),
            version = version,
            versioned_name = package,
            flags = repository_ctx.attr.flags.get(name, []),
            deps = [
                dep
                for dep in package_spec["dependencies"]
                if _get_components(remaining_components, dep).lib
            ],
            tools = [
                (dep, exe)
                for dep in package_spec["dependencies"]
                for exe in _get_components(remaining_components, dep).exe
            ],
            vendored = vendored,
            is_core_package = is_core_package,
            sdist = None if is_core_package or vendored != None else package,
        )
        remaining_components.pop(name, None)

        if is_core_package or vendored != None:
            continue

        if version == "<unknown>":
            fail("""\
Could not resolve version of {}. It is not in the snapshot.
Specify a fully qualified package name of the form <package>-<version>.
            """.format(package))

    for package in remaining_components.keys():
        if not package in _default_components:
            fail("Unknown package: %s" % package, "components")

    # Unpack all remote packages.
    remote_packages = [
        package.name
        for package in all_packages.values()
        if package.sdist != None
    ]
    if remote_packages:
        _execute_or_fail_loudly(repository_ctx, stack + ["--resolver", snapshot, "unpack"] + remote_packages)

    return all_packages

def _invert(d):
    """Invert a dictionary."""
    return dict(zip(d.values(), d.keys()))

def _from_string_keyed_label_list_dict(d):
    """Convert string_keyed_label_list_dict to label_keyed_string_dict."""

    # TODO Remove _from_string_keyed_label_list_dict once following issue
    # is resolved: https://github.com/bazelbuild/bazel/issues/7989.
    out = {}
    for (string_key, label_list) in d.items():
        for label in label_list:
            if label in out:
                out[label] += " " + string_key
            else:
                out[label] = string_key
    return out

def _to_string_keyed_label_list_dict(d):
    """Convert label_keyed_string_dict to string_keyed_label_list_dict."""

    # TODO Remove _to_string_keyed_label_list_dict once following issue
    # is resolved: https://github.com/bazelbuild/bazel/issues/7989.
    out = {}
    for (label, string_key_list) in d.items():
        for string_key in string_key_list.split(" "):
            out.setdefault(string_key, []).append(label)
    return out

def _label_to_string(label):
    return "@{}//{}:{}".format(label.workspace_name, label.package, label.name)

def _stack_snapshot_impl(repository_ctx):
    if repository_ctx.attr.snapshot and repository_ctx.attr.local_snapshot:
        fail("Please specify either snapshot or local_snapshot, but not both.")
    elif repository_ctx.attr.snapshot:
        snapshot = repository_ctx.attr.snapshot
    elif repository_ctx.attr.local_snapshot:
        snapshot = repository_ctx.path(repository_ctx.attr.local_snapshot)
    else:
        fail("Please specify one of snapshot or local_snapshot")

    # Enforce dependency on stack_update
    repository_ctx.read(repository_ctx.attr.stack_update)

    vendored_packages = _invert(repository_ctx.attr.vendored_packages)
    packages = repository_ctx.attr.packages
    core_packages = []
    versioned_packages = []
    unversioned_packages = []
    for package in packages:
        has_version = _has_version(package)
        unversioned = _chop_version(package) if has_version else package
        if unversioned in vendored_packages:
            fail("Duplicate package '{}'. Packages may not be listed in both 'packages' and 'vendored_packages'.".format(package))
        if unversioned in _CORE_PACKAGES:
            if has_version:
                fail("{} is a core package, built into GHC. Its version is determined entirely by the version of GHC you are using. You cannot pin it to {}.".format(unversioned, _version(package)))
            core_packages.append(unversioned)
        elif has_version:
            versioned_packages.append(package)
        else:
            unversioned_packages.append(package)
    user_components = {
        name: _parse_components(name, components)
        for (name, components) in repository_ctx.attr.components.items()
    }
    all_packages = _compute_dependency_graph(
        repository_ctx,
        snapshot,
        core_packages,
        versioned_packages,
        unversioned_packages,
        vendored_packages,
        user_components,
    )

    extra_deps = _to_string_keyed_label_list_dict(repository_ctx.attr.extra_deps)
    tools = [_label_to_string(label) for label in repository_ctx.attr.tools]

    # Write out dependency graph as importable Starlark value.
    repository_ctx.file(
        "packages.bzl",
        "packages = " + repr({
            package.name: struct(
                name = package.name,
                version = package.version,
                library = package.components.lib,
                executables = package.components.exe,
                deps = [Label("@{}//:{}".format(repository_ctx.name, dep)) for dep in package.deps],
                tools = [Label("@{}-exe//{}:{}".format(repository_ctx.name, dep, exe)) for (dep, exe) in package.tools],
                flags = package.flags,
            )
            for package in all_packages.values()
        }),
        executable = False,
    )

    # Write out the dependency graph as a BUILD file.
    build_file_builder = []
    build_file_builder.append("""
load("@rules_haskell//haskell:cabal.bzl", "haskell_cabal_binary", "haskell_cabal_library")
load("@rules_haskell//haskell:defs.bzl", "haskell_library", "haskell_toolchain_library")
""")
    for package in all_packages.values():
        if package.name in packages or package.versioned_name in packages or package.vendored != None:
            visibility = ["//visibility:public"]
        else:
            visibility = ["//visibility:private"]
        if package.vendored != None:
            build_file_builder.append(
                """
alias(name = "{name}", actual = "{actual}", visibility = {visibility})
""".format(name = package.name, actual = package.vendored, visibility = visibility),
            )
        elif package.is_core_package:
            build_file_builder.append(
                """
haskell_toolchain_library(name = "{name}", visibility = {visibility})
""".format(name = package.name, visibility = visibility),
            )
        elif package.name in _EMPTY_PACKAGES_BLACKLIST:
            build_file_builder.append(
                """
haskell_library(
    name = "{name}",
    version = "{version}",
    visibility = {visibility},
)
""".format(
                    name = package.name,
                    version = package.version,
                    visibility = visibility,
                ),
            )
        else:
            library_deps = package.deps + [
                _label_to_string(label)
                for label in extra_deps.get(package.name, [])
            ]
            library_tools = [
                "_%s_exe_%s" % (dep, exe)
                for (dep, exe) in package.tools
            ] + tools
            setup_deps = [
                _label_to_string(Label("@{}//:{}".format(repository_ctx.name, package.name)).relative(label))
                for label in repository_ctx.attr.setup_deps.get(package.name, [])
            ]
            if package.components.lib:
                build_file_builder.append(
                    """
haskell_cabal_library(
    name = "{name}",
    version = "{version}",
    haddock = {haddock},
    flags = {flags},
    srcs = glob(["{dir}/**"]),
    deps = {deps},
    setup_deps = {setup_deps},
    tools = {tools},
    visibility = {visibility},
    compiler_flags = ["-w", "-optF=-w"],
    verbose = {verbose},
    unique_name = True,
)
""".format(
                        name = package.name,
                        version = package.version,
                        haddock = repr(repository_ctx.attr.haddock),
                        flags = package.flags,
                        dir = package.sdist,
                        deps = library_deps,
                        setup_deps = setup_deps,
                        tools = library_tools,
                        visibility = visibility,
                        verbose = repr(repository_ctx.attr.verbose),
                    ),
                )
                if package.versioned_name != None:
                    build_file_builder.append(
                        """alias(name = "{name}", actual = ":{actual}", visibility = {visibility})""".format(
                            name = package.versioned_name,
                            actual = package.name,
                            visibility = visibility,
                        ),
                    )
            for exe in package.components.exe:
                build_file_builder.append(
                    """
haskell_cabal_binary(
    name = "_{name}_exe_{exe}",
    exe_name = "{exe}",
    flags = {flags},
    srcs = glob(["{dir}/**"]),
    deps = {deps},
    tools = {tools},
    visibility = ["@{workspace}-exe//{name}:__pkg__"],
    compiler_flags = ["-w", "-optF=-w"],
    verbose = {verbose},
)
""".format(
                        workspace = repository_ctx.name,
                        name = package.name,
                        exe = exe,
                        flags = package.flags,
                        dir = package.sdist,
                        deps = library_deps + ([package.name] if package.components.lib else []),
                        setup_deps = setup_deps,
                        tools = library_tools,
                        visibility = visibility,
                        verbose = repr(repository_ctx.attr.verbose),
                    ),
                )
    build_file_content = "\n".join(build_file_builder)
    repository_ctx.file("BUILD.bazel", build_file_content, executable = False)

_stack_snapshot = repository_rule(
    _stack_snapshot_impl,
    attrs = {
        "snapshot": attr.string(),
        "local_snapshot": attr.label(allow_single_file = True),
        "packages": attr.string_list(),
        "vendored_packages": attr.label_keyed_string_dict(),
        "flags": attr.string_list_dict(),
        "haddock": attr.bool(default = True),
        "extra_deps": attr.label_keyed_string_dict(),
        "setup_deps": attr.string_list_dict(),
        "tools": attr.label_list(),
        "components": attr.string_list_dict(),
        "stack": attr.label(),
        "stack_update": attr.label(),
        "verbose": attr.bool(default = False),
    },
)

def _stack_executables_impl(repository_ctx):
    workspace = repository_ctx.name[:-len("-exe")]
    packages = [
        _chop_version(package) if _has_version(package) else package
        for package in repository_ctx.attr.packages
    ]
    for package in packages:
        repository_ctx.file(package + "/BUILD.bazel", executable = False, content = """\
load("@{workspace}//:packages.bzl", "packages")
[
    alias(
        name = exe,
        actual = "@{workspace}//:_{package}_exe_" + exe,
        visibility = ["//visibility:public"],
    )
    for exe in packages["{package}"].executables
]
""".format(
            workspace = workspace,
            package = package,
        ))

_stack_executables = repository_rule(
    _stack_executables_impl,
    attrs = {
        "packages": attr.string_list(),
    },
)

def _stack_update_impl(repository_ctx):
    stack_cmd = repository_ctx.path(repository_ctx.attr.stack)
    _execute_or_fail_loudly(repository_ctx, [stack_cmd, "update"])
    repository_ctx.file("stack_update")
    repository_ctx.file("BUILD.bazel", content = "exports_files(['stack_update'])")

_stack_update = repository_rule(
    _stack_update_impl,
    attrs = {
        "stack": attr.label(),
    },
    # Marked as local so that stack update is always executed before
    # _stack_snapshot is executed.
    local = True,
)
"""Execute stack update.

This is extracted into a singleton repository rule to avoid concurrent
invocations of stack update.
See https://github.com/tweag/rules_haskell/issues/1090
"""

def _get_platform(repository_ctx):
    """Map OS name and architecture to Stack platform identifiers."""
    os_name = repository_ctx.os.name.lower()
    if os_name.startswith("linux"):
        os = "linux"
    elif os_name.startswith("mac os"):
        os = "osx"
    elif os_name.find("freebsd") != -1:
        os = "freebsd"
    elif os_name.find("windows") != -1:
        os = "windows"
    else:
        fail("Unknown OS: '{}'".format(os_name))

    if os == "windows":
        reg_query = ["reg", "QUERY", "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment", "/v", "PROCESSOR_ARCHITECTURE"]
        result = repository_ctx.execute(reg_query)
        value = result.stdout.strip().split(" ")[-1].lower()
        if value in ["amd64", "ia64"]:
            arch = "x86_64"
        elif value in ["x86"]:
            arch = "i386"
        else:
            fail("Failed to determine CPU architecture:\n{}\n{}".format(result.stdout, result.stderr))
    else:
        result = repository_ctx.execute(["uname", "-m"])
        if result.stdout.strip() in ["arm", "armv7l"]:
            arch = "arm"
        elif result.stdout.strip() in ["aarch64"]:
            arch = "aarch64"
        elif result.stdout.strip() in ["amd64", "x86_64", "x64"]:
            arch = "x86_64"
        elif result.stdout.strip() in ["i386", "i486", "i586", "i686"]:
            arch = "i386"
        else:
            fail("Failed to determine CPU architecture:\n{}\n{}".format(result.stdout, result.stderr))

    return (os, arch)

def _fetch_stack_impl(repository_ctx):
    repository_ctx.file("BUILD.bazel")
    #stack_cmd = repository_ctx.which("stack")
    #if stack_cmd:
    #    if _stack_version_check(repository_ctx, stack_cmd):
    #        repository_ctx.symlink(stack_cmd, "stack")
    #        return
    #    else:
    #        print("Stack version not recent enough. Downloading a newer version...")

    # If we can't find Stack, download it.
    (os, arch) = _get_platform(repository_ctx)
    version = _STACK_DEFAULT_VERSION
    (url, sha256) = _STACK_BINDISTS[version]["{}-{}".format(os, arch)]
    prefix = paths.basename(url)[:-len(".tar.gz")]
    repository_ctx.download_and_extract(url = url, sha256 = sha256)
    stack_cmd = repository_ctx.path(prefix).get_child("stack.exe" if os == "windows" else "stack")
    _execute_or_fail_loudly(repository_ctx, [stack_cmd, "--version"])
    exec_result = repository_ctx.execute([stack_cmd, "--version"], quiet = True)
    if exec_result.return_code != 0:
        error_messsage = ["A Stack binary for your platform exists, but it failed to execute."]
        if os == "linux":
            error_messsage.append("HINT: If you are on NixOS,")
            error_messsage.append("* make Stack available on the PATH, or")
            error_messsage.append("* specify a Stack binary using the stack attribute.")
        fail("\n".join(error_messsage).format(exec_result.return_code))
    repository_ctx.symlink(stack_cmd, "stack")

_fetch_stack = repository_rule(
    _fetch_stack_impl,
)
"""Find a suitably recent local Stack or download it."""

def stack_snapshot(
        name,
        stack = None,
        extra_deps = {},
        vendored_packages = {},
        snapshot = "",
        local_snapshot = None,
        packages = [],
        flags = {},
        haddock = True,
        setup_deps = {},
        tools = [],
        components = {},
        stack_update = None,
        verbose = False,
        **kwargs):
    """Use Stack to download and extract Cabal source distributions.

    This rule will use Stack to compute the transitive closure of the
    subset of the given snapshot listed in the `packages` attribute, and
    generate a dependency graph. If a package in the closure depends on
    system libraries or other external libraries, use the `extra_deps`
    attribute to list them. This attribute works like the
    `--extra-{include,lib}-dirs` flags for Stack and cabal-install do.
    If a package has a custom setup with setup dependencies, use the
    `setup_deps` attribute to list them.

    Packages that are in the snapshot need not have their versions
    specified. But any additional packages or version overrides will have
    to be specified with a package identifier of the form
    `<package>-<version>` in the `packages` attribute. Note that you cannot
    override the version of any [packages built into GHC][ghc-builtins].

    By default `stack_snapshot` defines a library target for each package. If a
    package does not contain a library component or contains executable
    components, then you need to declare so yourself using the `components`
    attribute. Library targets are exposed as `@stackage//:<package-name>` and
    executables are exposed as
    `@stackage-exe//<package-name>:<executable-name>`, assuming that you
    invoked `stack_snapshot` with `name = "stackage"`.

    In the external repository defined by the rule, all given packages are
    available as top-level targets named after each package. Additionally, the
    dependency graph is made available within `packages.bzl` as the `dict`
    `packages` mapping unversioned package names to structs holding the fields

      - name: The unversioned package name.
      - version: The package version.
      - library: Whether the package has a declared library component.
      - executables: List of declared executable components.
      - deps: The list of library dependencies according to stack.
      - tools: The list of tool dependencies according to stack.
      - flags: The list of Cabal flags.

    **NOTE:** Make sure your GHC version matches the version expected by the
    snapshot. E.g. if you pass `snapshot = "lts-13.15"`, make sure you use
    GHC 8.6.4 (e.g. by invoking `rules_haskell_toolchains(version="8.6.4")`).
    Sadly, rules_haskell cannot maintain this correspondence for you. You will
    need to manage it yourself. If you have a version mismatch, you will end up
    with versions of [core GHC packages][ghc-builtins] which do not match the
    versions listed in the snapshot, and potentially other problems.

    [ghc-builtins]: https://downloads.haskell.org/ghc/latest/docs/html/users_guide/8.10.1-notes.html#included-libraries

    ### Examples

      ```bzl
      stack_snapshot(
          name = "stackage",
          packages = ["conduit", "doctest", "lens", "zlib-0.6.2"],
          vendored_packages = {"split": "//split:split"},
          tools = ["@happy//:happy"],  # Use externally provided `happy`
          components = {
              "doctest": ["lib", "exe"],  # Optional since doctest is known to have an exe component.
              "happy": [],  # Override happy's default exe component.
          },
          snapshot = "lts-13.15",
          extra_deps = {"zlib": ["@zlib.dev//:zlib"]},
      )
      ```
      defines `@stackage//:conduit`, `@stackage//:doctest`, `@stackage//:lens`,
      `@stackage//:zlib` library targets and a `@stackage-exe//doctest`
      executable target. It also uses an externally provided `happy` rather
      than the one provided by the snapshot.

      Alternatively

      ```bzl
      stack_snapshot(
          name = "stackage",
          packages = ["conduit", "doctest", "lens", "zlib"],
          flags = {"zlib": ["-non-blocking-ffi"]},
          tools = ["@happy//:happy"],  # Use externally provided `happy`
          components = {
              "doctest": ["lib", "exe"],  # Optional since doctest is known to have an exe component.
              "happy": [],  # Override happy's default exe component.
          },
          local_snapshot = "//:snapshot.yaml",
          extra_deps = {"zlib": ["@zlib.dev//:zlib"]},
      ```

      Does the same as the previous example, provided there is a
      `snapshot.yaml`, at the root of the repository with content

      ```yaml
      resolver: lts-13.15

      packages:
        - zlib-0.6.2
      ```

    Args:
      name: The name of the Bazel workspace.
      snapshot: The name of a Stackage snapshot. Incompatible with local_snapshot.
      local_snapshot: A custom Stack snapshot file, as per the Stack documentation.
        Incompatible with snapshot.
      packages: A set of package identifiers. For packages in the snapshot,
        version numbers can be omitted.
      vendored_packages: Add or override a package to the snapshot with a custom
        unpacked source distribution. Each package must contain a Cabal file
        named `<package-name>.cabal` in the package root.
      flags: A dict from package name to list of flags.
      extra_deps: Extra dependencies of packages, e.g. system libraries or C/C++ libraries.
        Dict of stackage package names to a list of targets. The list of targets is given
        as input to the named stackage package.
        ```
        {
            "postgresql-libpq": ["@postgresql//:include"],
            "zlib": ["@zlib.dev//:zlib"]
        }
        ```
        means `@postgresql//:include` is passed to the stackage package `postgresql-libpq`
        while `@zlib.dev//:zlib` is passed to the stackage package `zlib`.
      setup_deps: Setup dependencies of packages, e.g. `cabal-doctest`.
        Dict of stackage package names to a list of targets in the same format as for `extra_deps`.
      tools: Tool dependencies. They are built using the host configuration, since
        the tools are executed as part of the build.
      components: Defines which Cabal components to build for each package.
        A dict from package name to list of components. Use `lib` for the
        library component and `exe:<exe-name>` for an executable component,
        `exe` is a short-cut for `exe:<package-name>`. The library component
        will have the label `@<workspace>//:<package>` and an executable
        component will have the label `@<workspace>-exe//<package>:<exe-name>`,
        where `<workspace>` is the name given to the `stack_snapshot`
        invocation.
      stack: The stack binary to use to enumerate package dependencies.
      haddock: Whether to generate haddock documentation.
      verbose: Whether to show the output of the build.
      stack_update: A meta repository that is used to avoid multiple concurrent invocations of
        `stack update` which could fail due to a race on the hackage security lock.
    """
    typecheck_stackage_extradeps(extra_deps)
    if not stack:
        _fetch_stack(name = "rules_haskell_stack")
        stack = Label("@rules_haskell_stack//:stack")

    # Execute stack update once before executing _stack_snapshot.
    # This is to avoid multiple concurrent executions of stack update,
    # which may fail due to ~/.stack/pantry/hackage/hackage-security-lock.
    # See https://github.com/tweag/rules_haskell/issues/1090.
    maybe(
        _stack_update,
        name = "rules_haskell_stack_update",
        stack = stack,
    )
    _stack_snapshot(
        name = name,
        stack = stack,
        # Dependency for ordered execution, stack update before stack unpack.
        stack_update = "@rules_haskell_stack_update//:stack_update",
        # TODO Remove _from_string_keyed_label_list_dict once following issue
        # is resolved: https://github.com/bazelbuild/bazel/issues/7989.
        extra_deps = _from_string_keyed_label_list_dict(extra_deps),
        # TODO Remove _invert once following issue is resolved:
        # https://github.com/bazelbuild/bazel/issues/7989.
        vendored_packages = _invert(vendored_packages),
        snapshot = snapshot,
        local_snapshot = local_snapshot,
        packages = packages,
        flags = flags,
        haddock = haddock,
        setup_deps = setup_deps,
        tools = tools,
        components = components,
        verbose = verbose,
        **kwargs
    )
    _stack_executables(
        name = name + "-exe",
        packages = packages,
    )

def _expand_make_variables(name, ctx, strings):
    extra_label_attrs = [
        ctx.attr.srcs,
        ctx.attr.tools,
    ]
    return expand_make_variables(name, ctx, strings, extra_label_attrs)
