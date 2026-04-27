#!/usr/bin/env bash
set -euo pipefail

# Oracle fork release helper (DanielLi202/oracle).
#
# Phases: gates | notifier | artifacts | tag | publish | smoke | all
#   gates      pnpm lint + test + build
#   notifier   ad-hoc sign + build vendor/oracle-notifier/OracleNotifier.app
#              (override with CODESIGN_ID + APP_STORE_CONNECT_* for real signing)
#   artifacts  npm pack -> oracle-X.Y.Z.tgz + sha1 + sha256
#   tag        git tag vX.Y.Z (skipped if it already exists)
#   publish    git push origin main + the tag, then create/upload assets to
#              the GitHub release via `gh`
#   smoke      install the freshly built tarball into an isolated npm prefix
#              and run `oracle --version`
#
# Environment:
#   VERSION         override version (default = package.json)
#   GH_REPO         GitHub repo slug (default DanielLi202/oracle)
#   SKIP_NOTIFIER=1 skip the macOS notifier build (Linux/CI without Xcode)
#   DRY_RUN=1       print git push / gh commands instead of running them

cd "$(git rev-parse --show-toplevel)"

VERSION="${VERSION:-$(node -p "require('./package.json').version")}"
GH_REPO="${GH_REPO:-DanielLi202/oracle}"
TGZ="oracle-${VERSION}.tgz"
TAG="v${VERSION}"

banner() { printf "\n==== %s ====\n" "$1"; }
run()    { echo ">> $*"; "$@"; }
maybe_run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "DRY_RUN >> $*"
  else
    run "$@"
  fi
}

phase_gates() {
  banner "Gates: lint + test + build"
  run pnpm run lint
  run pnpm run test
  run pnpm run build
}

phase_notifier() {
  if [[ "${SKIP_NOTIFIER:-0}" == "1" ]]; then
    echo "SKIP_NOTIFIER=1 -> skipping OracleNotifier.app build"
    return
  fi
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Not on macOS -> skipping OracleNotifier.app build"
    return
  fi
  banner "Build vendor/oracle-notifier/OracleNotifier.app"
  # Default to ad-hoc signing for the fork. Set CODESIGN_ID + APP_STORE_CONNECT_*
  # in the environment to use a real Developer ID + notarization.
  CODESIGN_ID="${CODESIGN_ID:--}" run bash vendor/oracle-notifier/build-notifier.sh
}

phase_artifacts() {
  banner "Artifacts: npm pack + checksums (v${VERSION})"
  run pnpm run build
  rm -f "$TGZ" "$TGZ.sha1" "$TGZ.sha256" /tmp/steipete-oracle-*.tgz
  run npm pack --pack-destination /tmp >/dev/null

  local packed
  packed=$(ls -1 "/tmp/"*"${VERSION}.tgz" 2>/dev/null | head -n1 || true)
  if [[ -z "$packed" ]]; then
    echo "No tarball produced by npm pack" >&2
    exit 1
  fi
  mv "$packed" "$TGZ"

  shasum "$TGZ"        > "$TGZ.sha1"
  shasum -a 256 "$TGZ" > "$TGZ.sha256"
  ls -lh "$TGZ" "$TGZ.sha1" "$TGZ.sha256"
}

phase_tag() {
  banner "Tag $TAG"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG already exists locally -> skipping"
  else
    run git tag -a "$TAG" -m "Release $VERSION"
  fi
}

phase_publish() {
  banner "Publish $TAG to $GH_REPO"
  maybe_run git push origin main
  maybe_run git push origin "$TAG"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "DRY_RUN >> gh release create/upload would run here for $TAG"
    return
  fi

  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists -> uploading assets (--clobber)"
    run gh release upload "$TAG" --repo "$GH_REPO" --clobber \
      "$TGZ" "$TGZ.sha1" "$TGZ.sha256"
  else
    run gh release create "$TAG" --repo "$GH_REPO" \
      --title "$TAG" --generate-notes \
      "$TGZ" "$TGZ.sha1" "$TGZ.sha256"
  fi
}

phase_smoke() {
  banner "Smoke test: install $TGZ into a clean npm prefix"
  local prefix
  prefix=$(mktemp -d)
  (
    npm install -g --prefix "$prefix" "./$TGZ" >/dev/null
    "$prefix/bin/oracle" --version
  )
  rm -rf "$prefix"
}

usage() {
  sed -n '3,21p' "$0"
}

main() {
  local phase="${1:-all}"
  case "$phase" in
    gates)     phase_gates ;;
    notifier)  phase_notifier ;;
    artifacts) phase_artifacts ;;
    tag)       phase_tag ;;
    publish)   phase_publish ;;
    smoke)     phase_smoke ;;
    all)
      phase_gates
      phase_notifier
      phase_artifacts
      phase_tag
      phase_smoke
      phase_publish
      ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
