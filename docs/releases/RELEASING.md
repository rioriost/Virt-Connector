# VirtConnector release procedure

This is the canonical procedure for Developer ID package releases through GitHub and `rioriost/homebrew-cask`. Do not borrow another app's notary profile or publish an unstapled package. App Store Connect submission is not part of this distribution route.

## One-time setup or credential replacement

Non-secret release settings live only in `scripts/release-config.sh`:

- Profile: `virt-connector-notary`
- Keychain: the current user's `~/Library/Keychains/login.keychain-db`, explicitly passed to both registration and notarization
- Team: `23889H77KX`
- Application and Installer signing identities: the matching Developer ID certificates

Create a new app-specific password in your Apple account, then run this yourself in Terminal:

```sh
cd /Users/rifujita/Git_Managed/Virt-Connector
scripts/notarytool-store-credentials.sh
scripts/release.sh check
```

Enter the Apple ID at the first prompt and the new app-specific password at notarytool's hidden prompt. The script does not read the password, pass it as a command argument, or store it in a file. notarytool validates the credentials with Apple before storing them. Password arguments and `APPLE_APP_SPECIFIC_PASSWORD` are rejected. Do not put passwords in shell commands, environment files, logs, Git, or chat. Re-run the same registration script when rotating the password; keep the profile name fixed.

The check verifies local tools, signing identities, GitHub repository write access and a real notary service request. A successful build does not substitute for a successful authentication check.

## Prepare a version

1. Review the scoped diff. Set `VERSION` to the next unpublished version, update README package examples, and write `docs/releases/<version>.md` and the validation record. Preserve existing limitations.
2. Run `scripts/release.sh prepare` in an interactive macOS session. It stops before building if authentication fails and refuses to rebuild an already published version. It runs Swift, installer, packaging, release-gate and native UI checks; builds in a clean directory; signs; submits for notarization; requires `Accepted`; staples; verifies the final package; and only then updates the Cask.
3. Keep the final `dist/VirtConnector-<version>-signed.pkg`, `.notary.json`, and `.sha256` together. The JSON records Apple's submission ID and status; the checksum is calculated after stapling. Do not upload a package left by an interrupted or failed preparation.
4. Run `scripts/release.sh verify` immediately before publication. It checks the checksum, expected signing team, valid staple, Gatekeeper install assessment, version, arm64/macOS 13 metadata, signatures, permissions, and source/payload consistency without installing the package.
5. Update the validation record with the actual submission ID, final checksum, checks and remaining limits. Run Homebrew style and `git diff --check`.

If preparation fails or is interrupted, fix the reported issue and rerun `prepare` for the unpublished version. It rebuilds and revalidates rather than trusting partial output. Cask changes occur only at the end. Do not change `VERSION` or the signing/notary environment to bypass a failed gate. The lower-level `build-pkg.sh --unsigned` remains available for development and is not a release command.

## Commit and publish

Use values read from this checkout; the commands below assume the reviewed changes are staged and the branch is `main`.

```sh
scripts/release.sh verify
git diff --cached --check
git commit -m "Release VirtConnector <version>"
git push origin main
release_version="$(cat VERSION)"
release_commit="$(git rev-parse HEAD)"
git ls-remote origin refs/heads/main
```

Confirm the remote main SHA is exactly `release_commit`. Use the full 40-character commit SHA when creating a GitHub release; a short SHA can be rejected. Do not create or move the public tag before the final verification and commit.

For a new release, create a draft, inspect it, then publish:

```sh
gh release create "v${release_version}" \
  "dist/VirtConnector-${release_version}-signed.pkg" \
  --draft --target "$release_commit" \
  --title "Virt-Connector ${release_version}" \
  --notes-file "docs/releases/${release_version}.md"
```

If an unpublished draft already exists, update its target, notes and package instead of creating a duplicate:

```sh
gh release edit "v${release_version}" --target "$release_commit" \
  --title "Virt-Connector ${release_version}" \
  --notes-file "docs/releases/${release_version}.md"
gh release upload "v${release_version}" \
  "dist/VirtConnector-${release_version}-signed.pkg" --clobber
```

`--clobber` is only for the unpublished draft. Never replace a published version's assets. After checking that the draft has the verified package and correct target:

```sh
gh release edit "v${release_version}" --draft=false --latest
```

Verify `isDraft=false`, the release asset, and that tag `v<version>` resolves to `release_commit`. Download the released package into a fresh directory under `.build/` and compare its SHA-256 with the verified local artifact. A successful upload response alone does not establish artifact parity.

## Publish the Homebrew update

Only after the release is public and its downloaded checksum matches:

1. Locate the tap with `brew --repo rioriost/cask`. Check its Git root, branch, worktree and origin; fetch and fast-forward clean main. Preserve unrelated user changes.
2. Copy this repository's verified `Casks/virt-connector.rb` to the same path in the tap. Run `brew style` on the changed Cask.
3. Commit only that Cask, push main, and confirm local/remote SHAs and the remote Cask version/checksum.
4. Confirm both worktrees are clean and the release is GitHub's latest release. Record the package checksum, application commit, release URL and tap commit.

Installation is a separate operation. Do not claim that the running agent has been upgraded merely because a package or Cask has been published. Real shutdown/device checks require their own explicit execution scope.
