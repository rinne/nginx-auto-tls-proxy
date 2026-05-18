#!/usr/bin/env bash
# Build and publish nginx-auto-tls-proxy to Docker Hub by hand.
#
# Usage: scripts/publish.sh <version> [--no-latest] [--force]
#
# Defaults can be overridden with environment variables:
#   IMAGE       Docker Hub image name      (default: timorinne/nginx-auto-tls-proxy)
#   PLATFORMS   Buildx target platforms    (default: linux/amd64,linux/arm64)
#   BUILDER     Buildx builder name        (default: nginx-auto-tls-proxy)
#   SKIP_SMOKE  Set to 1 to skip smoke test (not recommended)

set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage: $0 <version> [--no-latest] [--force]

    <version>     Semver-style version without leading 'v' (e.g. 0.1.0).
    --no-latest   Do not move the :latest tag (use for back-port releases).
    --force       Skip the clean-tree and main-branch guards.

Environment overrides:
    IMAGE=$IMAGE_DEFAULT
    PLATFORMS=$PLATFORMS_DEFAULT
EOF
    exit 2
}

IMAGE_DEFAULT="timorinne/nginx-auto-tls-proxy"
PLATFORMS_DEFAULT="linux/amd64,linux/arm64"
BUILDER_DEFAULT="nginx-auto-tls-proxy"

IMAGE="${IMAGE:-$IMAGE_DEFAULT}"
PLATFORMS="${PLATFORMS:-$PLATFORMS_DEFAULT}"
BUILDER="${BUILDER:-$BUILDER_DEFAULT}"

VERSION=""
TAG_LATEST=1
FORCE=0

while (( $# > 0 )); do
    case "$1" in
        --no-latest) TAG_LATEST=0 ;;
        --force)     FORCE=1 ;;
        -h|--help)   usage ;;
        -*)          echo "unknown flag: $1" >&2; usage ;;
        *)
            if [[ -n "$VERSION" ]]; then
                echo "unexpected extra argument: $1" >&2
                usage
            fi
            VERSION="$1"
            ;;
    esac
    shift
done

[[ -n "$VERSION" ]] || usage

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "version must be semver like 1.2.3 or 1.2.3-rc1, got: $VERSION" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

GIT_TAG="v$VERSION"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found in PATH" >&2
    exit 1
fi
if ! docker buildx version >/dev/null 2>&1; then
    echo "docker buildx is required" >&2
    exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" && "$FORCE" -ne 1 ]]; then
    echo "refusing to publish from branch '$BRANCH'; pass --force to override" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" && "$FORCE" -ne 1 ]]; then
    echo "refusing to publish from a dirty working tree; pass --force to override" >&2
    git status --short >&2
    exit 1
fi

if git rev-parse --verify --quiet "refs/tags/$GIT_TAG" >/dev/null; then
    echo "git tag $GIT_TAG already exists; delete it locally and remotely first if you mean to re-cut" >&2
    exit 1
fi

REVISION="$(git rev-parse HEAD)"
SOURCE_URL="$(git config --get remote.origin.url 2>/dev/null || true)"
if [[ "$SOURCE_URL" =~ ^git@([^:]+):(.+)\.git$ ]]; then
    SOURCE_URL="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
elif [[ "$SOURCE_URL" =~ ^https?://.*\.git$ ]]; then
    SOURCE_URL="${SOURCE_URL%.git}"
fi

if [[ "${SKIP_SMOKE:-0}" != "1" ]]; then
    echo "==> running smoke test"
    tests/smoke.sh
else
    echo "==> SKIP_SMOKE=1; not running tests/smoke.sh"
fi

if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
    echo "==> creating buildx builder '$BUILDER'"
    docker buildx create --name "$BUILDER" --use >/dev/null
else
    docker buildx use "$BUILDER"
fi
docker buildx inspect --bootstrap "$BUILDER" >/dev/null

TAGS=( "--tag" "${IMAGE}:${VERSION}" )
if [[ "$TAG_LATEST" -eq 1 ]]; then
    TAGS+=( "--tag" "${IMAGE}:latest" )
fi

echo "==> building and pushing ${IMAGE}:${VERSION}$([[ $TAG_LATEST -eq 1 ]] && echo ' + :latest') for $PLATFORMS"
docker buildx build \
    --platform "$PLATFORMS" \
    --build-arg "IMAGE_VERSION=${VERSION}" \
    --build-arg "IMAGE_REVISION=${REVISION}" \
    --build-arg "IMAGE_SOURCE=${SOURCE_URL}" \
    "${TAGS[@]}" \
    --push \
    nginx-auto-tls-proxy

DIGEST="$(docker buildx imagetools inspect "${IMAGE}:${VERSION}" --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
if [[ -n "$DIGEST" ]]; then
    echo "==> pushed ${IMAGE}:${VERSION} @ ${DIGEST}"
else
    echo "==> pushed ${IMAGE}:${VERSION} (digest lookup failed; image is published)"
fi

echo "==> tagging and pushing git tag $GIT_TAG"
git tag -a "$GIT_TAG" -m "Release $GIT_TAG"
if git config --get remote.origin.url >/dev/null 2>&1; then
    git push origin "$GIT_TAG"
else
    echo "    no 'origin' remote configured; git tag created locally only" >&2
fi

echo "==> done: ${IMAGE}:${VERSION}"
