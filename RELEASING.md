# Releasing

Each module is versioned and published on its own. A release of one module
never requires releasing another; the modules only share the
[HTTP contract](spec/README.md).

## Tags

Swift Package Manager reads package versions from the repository's git tags
and treats **every** semver-looking tag (`1.2.3` or `v1.2.3`) as a version of
the Swift package. So only the iOS SDK uses plain tags; every other module
uses a prefix, which SPM ignores:

| Module | Version lives in | Tag |
| --- | --- | --- |
| iOS (`Package.swift`, `ios/`) | `ios/CHANGELOG.md` (SPM has no version field) | `0.1.0` |
| Flutter (`flutter/`) | `flutter/pubspec.yaml` | `flutter-v0.1.1` |
| React Native (`react-native/`) | `react-native/package.json` | `react-native-v0.1.0` |
| Android (`android/`) | `VERSION_NAME` in `android/gradle.properties` | `android-v0.1.0` |
| Worker (`worker/`) | not published; deployed with `npm run deploy` | none |

## Checklist for every release

1. The module's CI workflow is green on `main`, including the shared fixtures
   in `spec/fixtures/`.
2. Bump the version and add a `CHANGELOG.md` entry in the module.
3. If the release changes behaviour covered by [spec/README.md](spec/README.md),
   update the spec and the fixtures, and check that the other SDKs still pass
   (or plan their follow-up releases).
4. Publish (below), then tag the published commit and push the tag.

## Flutter (pub.dev)

```bash
cd flutter
flutter pub publish --dry-run
flutter pub publish
git tag flutter-v0.1.1 && git push origin flutter-v0.1.1
```

## React Native (npm)

One-time setup: an npm account with two-factor authentication **enabled**
(npmjs.com → Account → Two-Factor Authentication, or
`npm profile enable-2fa auth-and-writes`), logged in with `npm login`.
`npm profile get` shows `two-factor auth: disabled` while it is off. In that
state, `npm publish` fails with `E403 … Two-factor authentication or granular access
token with bypass 2fa enabled is required to publish packages`.

```bash
cd react-native
npm ci
npm publish --dry-run      # runs the build, type-check and tests
npm publish                # asks for a one-time password (or: npm publish --otp=123456)
git tag react-native-v0.1.0 && git push origin react-native-v0.1.0
```

To publish from CI later, configure
[trusted publishing](https://docs.npmjs.com/trusted-publishers) for the
package on npmjs.com once it exists, instead of storing a token.

## Android (Maven Central)

The library is published with the
[vanniktech Maven Publish plugin](https://vanniktech.github.io/gradle-maven-publish-plugin/central/)
through the Sonatype Central Portal.

One-time setup:

1. Create an account on [central.sonatype.com](https://central.sonatype.com/)
   and verify the namespace `io.github.huynguyennovem` (Central verifies
   `io.github.*` namespaces through the GitHub account).
2. Generate a user token in the portal.
3. Create a GPG signing key and publish it to a key server (install GnuPG
   first, e.g. `brew install gnupg`):

   ```bash
   export GPG_TTY=$(tty)   # lets gpg ask for the passphrase in this terminal
   gpg --quick-generate-key "Your Name <you@example.com>" rsa4096 sign 2y
   gpg --list-secret-keys --keyid-format long
   gpg --keyserver keyserver.ubuntu.com --send-keys <key id>
   ```

   The key id is the part after `rsa4096/` on the `sec` line, e.g.
   `3AA5C34371567BD2`. Remember the passphrase: it is
   `signingInMemoryKeyPassword` below.
4. Add the credentials to `~/.gradle/gradle.properties`, never to the
   repository. Gradle reads that file but doesn't create it, so create it
   first, readable only by you:

   ```bash
   touch ~/.gradle/gradle.properties && chmod 600 ~/.gradle/gradle.properties
   ```

   Then add the token from step 2. Its username and password are not your
   portal login:

   ```properties
   mavenCentralUsername=<token username>
   mavenCentralPassword=<token password>
   signingInMemoryKeyPassword=<GPG key passphrase>
   ```

   The private key goes on one line, with `\n` for its line breaks, because a
   properties value can't span lines. This command appends it in that form:

   ```bash
   gpg --export-secret-keys --armor <key id> \
     | awk 'BEGIN { printf "signingInMemoryKey=" } { printf "%s\\n", $0 } END { print "" }' \
     >> ~/.gradle/gradle.properties
   ```

   Add `signingInMemoryKey` only once you have the real key. Signing runs
   whenever that property exists, even with an empty value. With a
   placeholder, `publishToMavenLocal` fails; without the property, local
   builds work and nothing is signed.

   `Could not read PGP secret key … checksum mismatch` means
   `signingInMemoryKeyPassword` is missing or wrong. The exported key keeps
   the passphrase it had when you exported it. So after `gpg --passwd`,
   replace the `signingInMemoryKey` line by exporting again.

   In CI, use environment variables instead
   (`ORG_GRADLE_PROJECT_mavenCentralUsername` and so on). There the key can
   keep its normal line breaks.

Release (Gradle needs the Android SDK: set `ANDROID_HOME`, or create
`android/local.properties` as described in
[android/README.md](android/README.md#running-the-tests)):

```bash
cd android
./gradlew :cloudflare-worker-kv:testDebugUnitTest :cloudflare-worker-kv:publishToMavenLocal   # inspect ~/.m2 first
./gradlew :cloudflare-worker-kv:publishToMavenCentral   # then press "Publish" in the Central Portal
git tag android-v0.1.0 && git push origin android-v0.1.0
```

`publishAndReleaseToMavenCentral` does both steps at once.

## iOS (Swift Package Manager)

There is nothing to upload: SPM reads the tag straight from this repository.

```bash
swift test
git tag 0.1.0 && git push origin 0.1.0
```

Apps then depend on
`.package(url: "https://github.com/huynguyennovem/cloudflare-worker-kv", .upToNextMinor(from: "0.1.0"))`.
While the version is `0.x`, recommend `.upToNextMinor` rather than `from:`,
which would accept breaking `0.x` minors.
