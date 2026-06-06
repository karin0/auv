# auv

[![build](https://github.com/karin0/auv/actions/workflows/image.yml/badge.svg)](https://github.com/karin0/auv/actions/workflows/image.yml)

A GitHub action that builds [AUR](https://aur.archlinux.org/) packages and publishes them as a pacman repository served by GitHub releases.

> [!CAUTION]
> Use this only for sources you **absolutely trust**, as they are built, signed and distributed blindly without any review.

## Features

- Keeps the repository up to date with the specified package list
- Builds only the new and updated packages
- Signs the database and packages with an optional GPG key
- Posts an optional Telegram summary when the repository updates

## Getting started

Create a workflow and a package list in your GitHub repository:

```yaml
# .github/workflows/build.yml
on:
  schedule:
    - cron: '0 0 * * *'
  workflow_dispatch:

permissions:
  contents: write   # Required to publish release assets

jobs:
  build:
    runs-on: ubuntu-latest
    concurrency:
      group: build-my-aur-repo
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v6
      - uses: karin0/auv@main
        with:
          release_tag: my-aur-repo
          packages_file: packages.txt
          gpg_private_key: ${{ secrets.GPG_PRIVATE_KEY }}  # Optional but recommended
```

```ini
# packages.txt
# Comments and blank lines are ignored
osu-lazer-bin
google-chrome
visual-studio-code-bin
```

Append the repository to the local `/etc/pacman.conf`:

```ini
[my-aur-repo]  # Should match `repo_name` (defaults to `release_tag`)
SigLevel = Required
Server = https://github.com/<owner>/<repo>/releases/download/my-aur-repo  # Should match `release_tag`
```

If a GPG key is specified, import and trust it locally:

```bash
gpg --export <key-id> | sudo pacman-key --add -
sudo pacman-key --lsign-key <key-id>
```

Otherwise, replace `SigLevel = Required` above with `SigLevel = Optional TrustAll`.

See [karin0/aur](https://github.com/karin0/aur) for a working example with matrix profiles.

## Maintenance

For each run, this action synchronizes the assets of the specified release tag with the package list, building any new/updated/missing packages and removing any dropped ones, along with their dependencies.

To rebuild a specific package, simply delete it from the release assets and trigger the workflow again.~

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `release_tag` | yes | Release tag the repository is published to. |
| `packages_file` | yes | Path to the package list. |
| `repo_name` | no | Pacman repository name, defaults to `release_tag`. |
| `makepkg_conf_file` | no | Path to the file containing extra flags to be appended to `makepkg.conf`. |
| `patches_dir` | no | Path to the directory of build patches, see below. |
| `gpg_private_key` | no | GPG private key, ASCII-armored or base64, for signing the database and packages. |
| `gpg_key_id` | no | GPG key ID to sign with, defaults to the first secret key. |
| `telegram_bot_token`, `telegram_chat_id` | no | Telegram credentials for change notifications. |
| `builder_image` | no | Docker image with `aurutils`, defaults to `ghcr.io/karin0/auv/auv-builder:latest`. |

Output `updated` is set to `1` if the repository was changed.

## Patches

`patches_dir` can be specified to patch the AUR clones before the build starts.

For each package `<pkgbase>`, `patches_dir` may contain:

- `<pkgbase>.patch`, applied with `git apply` against the clone directory, or
- An executable `<pkgbase>.sh`, invoked with the path to the clone directory as the only argument.

## Standalone

To build and host the packages locally without GitHub, [`sync.sh`](./sync.sh) and [`build-all.sh`](./build-all.sh) can be used with `aurutils` and `pyalpm` installed.

## Credits

Inspired by [kopp/build-aur-packages](https://github.com/kopp/build-aur-packages).
