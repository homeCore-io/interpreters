# homeCore interpreters

The interpreters homeCore's plugin runtimes run plugins on: Python, and
Node.js. Each is listed in the signed registry index by kind and series
(`python` `cp313`, `node` `node24`); homeCore matches a plugin build's series
to the newest patch here and knows nothing else about the language.

A Python plugin is built for one Python minor, such as 3.13, because the
compiled wheels it carries load only on that minor. The runtime doesn't bring
its own Python: when homeCore places a plugin on it, the runtime fetches the
interpreter the plugin was built for, through homeCore, and keeps one copy of
each it uses. Plugin authors choose their Python, and a Python fix reaches
every plugin on that minor without rebuilding any of them.

The design is in
[core/docs/pythonInterpretersPlan.md](https://github.com/homeCore-io/homeCore/blob/develop/docs/pythonInterpretersPlan.md).

## What's here

| File | What it does |
|---|---|
| `versions.toml` | The patch shipped for each supported minor, and the upstream release it comes from |
| `build-python.sh` | Builds one Python: download, check, prune, test, pack |
| `build-node.sh` | Builds one Node.js, the same way |
| `check-upstream.py` | Compares `versions.toml` with upstream's latest release |
| `.github/workflows/release.yml` | On a `python-<version>` or `node-<version>` tag: build, test, release, add to the registry |
| `.github/workflows/check-upstream.yml` | Weekly: opens a pull request when upstream has newer patches of either |

## Where the builds come from

[python-build-standalone](https://github.com/astral-sh/python-build-standalone),
the same builds `uv python install` uses, so a plugin author's machine, CI and
the house run identical interpreters. `build-python.sh` takes the
`install_only_stripped` build for linux, checks it against the release's
`SHA256SUMS`, and removes what a plugin never needs:

- the test suite, IDLE, Tk and Tcl, turtle, `pydoc_data`;
- `ensurepip` and pip (uv makes and fills plugin environments);
- the shared and static libpython and the headers (the interpreter is linked
  statically, and manylinux wheels never link libpython).

It then checks that the version is right, that the standard library modules
plugins rely on still import, and that a venv can be made from it, and packs
`python-<version>-linux-<arch>.tar.zst` with one top directory, `python/`.
That's about 13 MB, against 36 MB upstream.

## Node.js

The official builds from [nodejs.org](https://nodejs.org/dist/), one per
supported LTS major. `build-node.sh` checks the download against the
release's `SHASUMS256.txt`, removes npm, npx, corepack, the headers and the
docs (a plugin arrives with its `node_modules`, so a runtime never runs npm),
checks that TLS, UDP over IPv6, workers and full ICU work, and packs
`node-<version>-linux-<arch>.tar.zst` with one top directory, `node/`: about
31 MB. Node.js is built for x86_64 and aarch64. A plugin built for Node.js 24
says so with the ABI tag `node24-glibc_2_28`.

## Releasing

A new patch:

1. The weekly check opens a pull request updating `versions.toml`. Merge it.
2. Tag each version it lists: `git tag python-3.13.19 && git push origin python-3.13.19`,
   or `node-24.22.4` for Node.js.

The release workflow builds and tests it again, attaches it to a GitHub Release,
and asks [homeCore-io/registry](https://github.com/homeCore-io/registry) to add
it to the signed index. It waits until the served index carries it. Houses then
see the update next to their plugin updates; nothing applies it on its own.

A new minor: add a `[python."3.x"]` entry once the compiled libraries plugins
use (pydantic-core, cryptography, jiter, rpds-py, cffi) publish wheels for it,
merge, and tag it.

A minor Python stops fixing: set `eol = true` on it and tag its current version
again, or wait for its last patch. Plugins built for it keep running, and the
Catalog says they need rebuilding for a newer Python.

To build without releasing, run the workflow by hand with a version, or locally:

```bash
./build-python.sh --version 3.13.18 --upstream 20261110 --out dist
```

It needs curl, tar, zstd and sha256sum.

## License

The scripts here are MIT or Apache 2.0, at your option. The interpreters are
Python, under the [PSF license](https://docs.python.org/3/license.html), built
by python-build-standalone; each archive keeps Python's license files.
