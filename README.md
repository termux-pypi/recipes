# termux-pypi recipes

Build recipes for the [Termux-PyPI](tpypi.loamfy-tools.workers.dev) index: patches, flags and system dependencies needed to turn PyPI source distributions into self-contained wheels that install on Termux without compiling.

Recipes are consumed by [`tpip build`](https://github.com/termux-pypi/termux-pip). CI builds every recipe for all supported architectures and publishes the repaired wheels.

> ⚠️ Recipes (`env`, `pip_args`, patches) are executed during the build. Only build recipes you trust and review every pull request carefully.

## Layout

```
recipes/
└── <package>/
    └── <version>/
        ├── recipe.yaml
        └── patches/
            ├── 0001-some-fix.patch
            └── 0002-another-fix.patch
```

## `recipe.yaml`

```yaml
metadata:
  name: "scipy"              # PyPI project name, written as in the sdist file name
  version: "1.17.1"          # version of the produced wheel
  download_version: "1.17.1" # sdist version to download (may differ from `version`)

build:
  system_dependencies:       # installed with `pkg install`
    - "libopenblas"
    - "flang"
  exclude_arches:            # optional: aarch64, arm, x86_64, i686
    - "arm"
    - "i686"
  env:                       # optional: extra environment variables for the build
    CXXFLAGS: "-Wno-c++11-narrowing"
  pip_args: []               # optional: extra arguments for `pip wheel`
  patches:                   # optional: applied in order with `git apply`
    - "patches/0001-use-system-dependencies.patch"
```

Notes:
- `name` must match the directory inside the sdist (`<name>-<download_version>`). That is why some recipes use underscores (`argon2_cffi_bindings`, `pydantic_core`) while the folder name keeps hyphens.
- `download_version` differs from `version` when the upstream sdist has to be rebuilt under another version. Fix the metadata with a patch (see `ninja` and `patchelf`, which patch `PKG-INFO`).
- `exclude_arches` skips an architecture both locally and in CI (for example `scipy` needs `flang`, which is not available on `arm` and `i686`).
- `system_dependencies` are Termux package names (letters, digits, `+`, `.`, `-`).
- `patches` paths are relative to the recipe folder and must stay inside it.

## Adding a recipe

1. Create `recipes/<package>/<version>/recipe.yaml`.
2. If the build needs source changes, unpack the sdist, `git init` and commit it, edit the files, and save `git diff` as `patches/NNNN-description.patch`.
3. Build locally in Termux to check it:
   ```
   pip install termux-pip
   tpip setup
   pip install "termux-pip[build]"
   tpip build recipes/<package>/<version>/recipe.yaml -w ./dist
   tpip repair ./dist/<wheel>.whl
   ```
4. Open a pull request.

## CI

Workflow: `.github/workflows/build.yml`

- **Pull request / push to `main`** touching `recipes/**`: builds only the changed `<package>/<version>` folders.
- **Manual run** (`workflow_dispatch`): enter a pattern, `*` for everything or e.g. `numpy/*` for one package. Only letters, digits, `.`, `_`, `-`, `*` and `/` are allowed.
- Each recipe is built in `termux/termux-docker` for `aarch64`, `arm`, `x86_64` and `i686` (architectures listed in `exclude_arches` are skipped), then repaired with `tpip repair`.
- Wheels are uploaded to storage only on `main` (push or manual run); pull requests build without publishing and without access to secrets.
