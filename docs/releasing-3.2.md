# Releasing Grux AI 3.2.0

The exact sequence for 3.2.0, in the order `release/RELEASING.md` fixes. That page is the
rule; this one is the run. Nothing below is published until the person who signs releases
says "ship it": the build, the staging folder and a DRAFT GitHub release are all private.

## Before the build

| Gate | How it is read | Floor |
|---|---|---|
| The release branch is ship-ready | the integration owner names the final `release/3.2` sha and the public CI run id that executed the suite on it | "Executed N tests, with K tests skipped and 0 failures" |
| Disk on the build Mac | `df -h /System/Volumes/Data` | 15 GB free, measured immediately before `build.sh` (a release build writes several GB under `.build`) |
| No other Swift build running | `pgrep -fl 'swift-build\|xcodebuild'` prints nothing | |
| Developer ID present | `security find-identity -v -p codesigning \| grep -c 'Developer ID Application'` | 1 |

The test count is READ from that CI run, never typed and never measured on the build Mac:

```bash
RUN=<public CI run id>
gh run view "$RUN" -R github.com/dotcomjack/grux --log 2>/dev/null | grep -o 'Executed [0-9]* tests' | sort -u
```

## 1. Source docs, on release/3.2 before the build

Already on the branch from the notes pull request: `CHANGELOG.md` tops at `[3.2.0]`,
`[Unreleased]` is empty, `Grux-Mac/Info.plist` reads 3.2.0 (13), `npm/package.json` reads
3.2.0, the README says "currently 3.2" and "Download Grux AI 3.2 for Apple silicon". Two
values are set on the day:

```bash
# the count the CI run above measured, nothing else; --check and the bare form run swift test here
python3 Grux-Mac/scripts/update-readme-counts.py --count <N>
# the CHANGELOG date is the ship day; ship-gate pre fails on any other date
sed -i '' 's/^## \[3.2.0\] - .*/## [3.2.0] - '"$(date +%F)"'/' CHANGELOG.md
python3 launch/check-notes.py        # mirrors the five release-notes tests, exit 0
```

Both files are in `docs_only_drift` (`release/surfaces.json`), so they may change after the
build commit. Code may not.

## 2. Build, sign, notarize, staple

The three notarization values are the App Store Connect API key the team already holds:
the `.p8` is a file on the build Mac, and the key id and issuer id are recorded in the
operator's key reference under App Store Connect. Nothing is typed into this document.

```bash
cd Grux-Mac
GRUX_RELEASE=1 GRUX_NOTARIZE=1 \
  ASC_KEY="$HOME/.private_keys/AuthKey_<KEY_ID>.p8" ASC_KEY_ID=<KEY_ID> ASC_ISSUER=<ISSUER_ID> \
  ./build.sh
```

`build.sh` leaves `~/Downloads/Grux-release.app` (notarized, stapled, Gatekeeper accepted)
and `/tmp/grux-build/Grux-release.zip` (cut after stapling) and installs nothing. The build
commit is `git rev-parse HEAD` at that moment; write it down.

## 3. Stage

```bash
S="$HOME/Downloads/Grux-3.2.0-b13"; mkdir -p "$S"
ditto "$HOME/Downloads/Grux-release.app" "$S/Grux.app"
cp /tmp/grux-build/Grux-release.zip "$S/Grux-3.2.0-macOS-arm64.zip"
ASC_KEY="$HOME/.private_keys/AuthKey_<KEY_ID>.p8" ASC_KEY_ID=<KEY_ID> ASC_ISSUER=<ISSUER_ID> \
  bash Grux-Mac/scripts/dmg/make-dmg.sh "$S/Grux.app" "$S"
(cd "$S" && shasum -a 256 Grux.dmg Grux-3.2.0-macOS-arm64.zip > SHA256SUMS.txt && cat SHA256SUMS.txt)
(cd npm && npm pack --pack-destination "$S")          # dotcomjack-grux-3.2.0.tgz
cp launch/GITHUB-RELEASE-BODY-3.2.0.md "$S/GITHUB-RELEASE-BODY.md"   # then paste the two sums in
```

`make-dmg.sh` signs the image, notarizes and staples it, and refuses to finish unless
Gatekeeper accepts both the image and the app inside it.

## 4. The pre gate

```bash
release/ship-gate.py pre --version 3.2.0 --stage "$S" \
    --build-commit <build sha> --source-ref origin/release/3.2 --tests <N> --date <ship day>
```

Exit 0 or stop. It reports any step that already landed; skip those, never redo one.

## 5. The draft release (private until published)

```bash
gh release create v3.2.0 --repo github.com/dotcomjack/grux --draft --title "Grux AI 3.2" \
    --notes-file "$S/GITHUB-RELEASE-BODY.md" \
    "$S/Grux.dmg" "$S/Grux-3.2.0-macOS-arm64.zip" "$S/SHA256SUMS.txt"
gh release view v3.2.0 --repo github.com/dotcomjack/grux --json isDraft,assets --jq '{isDraft, assets: [.assets[].name]}'
```

A draft creates no tag and is invisible to the update check and to `releases/latest`.

## 6. On "ship it", in this order

1. **Public source.** OSS extract from the build sha (`oss-guarantee.sh` PASS), fresh public
   clone, list WOULD DELETE and trace every deletion, rsync, commit, `GRUX_SKIP_PREPUSH=1 git
   push origin main`, public CI green (RELEASING steps 3 and 4). Send the site owner the new
   public `main` sha at once: gruxai.com renders /changelog and /docs from one pinned commit
   (grux-site `tools/fetch-upstream.py`), and the pin moves to this sha before step 6.
2. **Tags.** Public `v3.2.0` at that public commit, private `v3.2.0` at the build commit.
   `v3.0.0` is protected; never move it.
3. **Publish the release.** The tag now exists, so publishing attaches to it:
   `gh release edit v3.2.0 --repo github.com/dotcomjack/grux --draft=false --latest`. Then
   `curl -sIL https://github.com/dotcomjack/grux/releases/latest/download/Grux.dmg` resolves to
   the v3.2.0 asset with the size in `SHA256SUMS.txt`.
4. **Homebrew.** On the tap branch `grux-3.2.0`, replace the placeholder sha256 with the
   ZIP's sum from `SHA256SUMS.txt`, `brew style Casks/grux.rb`, push, merge the tap pull
   request. Tap CI fetches the release URL, so it stays red until step 3 is done.
5. **npm.** `npm publish "$S/dotcomjack-grux-3.2.0.tgz" --access public` (the two-factor prompt
   is the one human screen). `npm view @dotcomjack/grux version` reads 3.2.0.
6. **Site**, last, from a fresh grux-site worktree: RELEASING step 9 verbatim
   (`repin-citations.py --from v3.1.0 --to v3.2.0`, `fetch-facts.py`, the hand-written
   versions, both share cards, `build-geo.py`, `check.sh`, `tools/ship.sh`).
7. **Post gate.** `release/ship-gate.py post --version 3.2.0 --stage "$S" --build-commit <build sha>
   --tests <N> --site-dir <grux-site worktree> --json "$S/gate-post.json"`, exit 0, kept as evidence.

## Homebrew core: the gating metric for leaving the tap

`brew install --cask dotcomjack/tap/grux` works today with no review. A cask in
homebrew/cask needs public interest beyond its author, read 2026-10-31 from
docs.brew.sh/Package-Acceptance-Policy: "at least 30 forks, 30 watchers or 75 stars",
and "at least 90 forks, 90 watchers or 225 stars for a self-submission by the repository
owner"; "A code repository less than 30 days old is normally not eligible." Measured the
same day on github.com/dotcomjack/grux: 30 stars, 0 forks, 0 watchers. The first bar this release can
cross is 225 stars; a third party could submit at 75. Until then the cask lives in the tap.
