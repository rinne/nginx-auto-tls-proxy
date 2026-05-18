#!/usr/bin/env bash
# Build and publish nginx-auto-tls-proxy to Docker Hub by hand.
#
# Usage: scripts/publish.sh <version> [--no-latest] [--force] [--retag-latest-only]
#
# Publishes four tags from one git revision:
#   <IMAGE>:<version>          (plain image, today's behavior)
#   <IMAGE>:<version>-php      (same source + php-fpm + curated PHP extensions)
#   <IMAGE>:latest             (unless --no-latest)
#   <IMAGE>:latest-php         (unless --no-latest)
#
# Two `docker buildx build --push` invocations are required (one per WITH_PHP
# value), so this script is NOT truly atomic. Instead it is "moving-tags-last":
# both versioned tags are pushed first; the moving :latest and :latest-php tags
# only flip when both versioned builds succeeded. Most users pull moving tags,
# so protecting those from half-shipped state matters more than protecting
# versioned tags (which are immutable identifiers — a stranded :<ver>-php with
# no matching :<ver> is ugly but causes no wrong-image incident).
#
# If buildx fails partway:
#   - Build of :<ver>-php fails (step 3): registry unchanged; just re-run.
#   - Build of :<ver> fails after :<ver>-php pushed (step 4): registry has an
#     orphan :<ver>-php. :latest unchanged. Re-run with --force after cleaning
#     up the orphan upstream tag, or accept the orphan and ship the next
#     version.
#   - Moving-tag promotion fails (step 5): both versioned tags exist, :latest
#     stale. Re-run with --force --retag-latest-only to promote without
#     rebuilding.
#
# Defaults can be overridden with environment variables:
#   IMAGE       Docker Hub image name      (default: timorinne/nginx-auto-tls-proxy)
#   PLATFORMS   Buildx target platforms    (default: linux/amd64,linux/arm64)
#   BUILDER     Buildx builder name        (default: nginx-auto-tls-proxy)
#   SKIP_SMOKE  Set to 1 to skip smoke test (not recommended)

set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage: $0 <version> [--no-latest] [--force] [--retag-latest-only]

    <version>              Semver-style version without leading 'v' (e.g. 0.1.0).
    --no-latest            Do not move :latest / :latest-php (use for back-port releases).
    --force                Skip the clean-tree, main-branch, and upstream-tag-presence guards.
    --retag-latest-only    Skip both builds; only re-promote :latest and :latest-php from
                           the existing :<version>{,-php} tags. Useful when step 5 failed
                           but both versioned builds already shipped. Requires --force.

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
RETAG_LATEST_ONLY=0

while (( $# > 0 )); do
    case "$1" in
        --no-latest)          TAG_LATEST=0 ;;
        --force)              FORCE=1 ;;
        --retag-latest-only)  RETAG_LATEST_ONLY=1 ;;
        -h|--help)            usage ;;
        -*)                   echo "unknown flag: $1" >&2; usage ;;
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

if [[ "$RETAG_LATEST_ONLY" -eq 1 && "$FORCE" -ne 1 ]]; then
    echo "--retag-latest-only requires --force (acknowledging that you know what you're doing)" >&2
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
    if [[ "$FORCE" -ne 1 ]]; then
        echo "git tag $GIT_TAG already exists; delete it locally and remotely first, or pass --force" >&2
        exit 1
    fi
    echo "==> WARNING: git tag $GIT_TAG already exists (continuing because --force)"
fi

REVISION="$(git rev-parse HEAD)"
SOURCE_URL="$(git config --get remote.origin.url 2>/dev/null || true)"
if [[ "$SOURCE_URL" =~ ^git@([^:]+):(.+)\.git$ ]]; then
    SOURCE_URL="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
elif [[ "$SOURCE_URL" =~ ^https?://.*\.git$ ]]; then
    SOURCE_URL="${SOURCE_URL%.git}"
fi

# Pre-flight: refuse to overwrite versioned tags already present upstream
# (manifest existence is checked via imagetools inspect). Doesn't apply to
# moving tags (those are intended to move).
check_tag_absent() {
    local tag="$1"
    if docker buildx imagetools inspect "$tag" >/dev/null 2>&1; then
        if [[ "$FORCE" -ne 1 ]]; then
            echo "refusing to publish: $tag already exists on the registry. Pass --force to override." >&2
            exit 1
        fi
        echo "==> WARNING: $tag already exists upstream (continuing because --force)"
    fi
}

if [[ "$RETAG_LATEST_ONLY" -ne 1 ]]; then
    check_tag_absent "${IMAGE}:${VERSION}"
    check_tag_absent "${IMAGE}:${VERSION}-php"
fi

if [[ "${SKIP_SMOKE:-0}" != "1" ]]; then
    echo "==> running smoke tests (plain + php)"
    tests/smoke.sh
    tests/smoke-php.sh
else
    echo "==> SKIP_SMOKE=1; not running smoke tests"
fi

if [[ "$RETAG_LATEST_ONLY" -ne 1 ]]; then
    if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
        echo "==> creating buildx builder '$BUILDER'"
        docker buildx create --name "$BUILDER" --use >/dev/null
    else
        docker buildx use "$BUILDER"
    fi
    docker buildx inspect --bootstrap "$BUILDER" >/dev/null

    # Build the riskier variant first. If this fails, registry is unchanged
    # and moving tags are not touched.
    echo "==> [1/2] building and pushing ${IMAGE}:${VERSION}-php for $PLATFORMS"
    docker buildx build \
        --platform "$PLATFORMS" \
        --build-arg "WITH_PHP=1" \
        --build-arg "IMAGE_VERSION=${VERSION}" \
        --build-arg "IMAGE_REVISION=${REVISION}" \
        --build-arg "IMAGE_SOURCE=${SOURCE_URL}" \
        --tag "${IMAGE}:${VERSION}-php" \
        --push \
        nginx-auto-tls-proxy

    echo "==> [2/2] building and pushing ${IMAGE}:${VERSION} for $PLATFORMS"
    docker buildx build \
        --platform "$PLATFORMS" \
        --build-arg "WITH_PHP=0" \
        --build-arg "IMAGE_VERSION=${VERSION}" \
        --build-arg "IMAGE_REVISION=${REVISION}" \
        --build-arg "IMAGE_SOURCE=${SOURCE_URL}" \
        --tag "${IMAGE}:${VERSION}" \
        --push \
        nginx-auto-tls-proxy
fi

if [[ "$TAG_LATEST" -eq 1 ]]; then
    echo "==> promoting :latest -> ${IMAGE}:${VERSION}"
    docker buildx imagetools create --tag "${IMAGE}:latest"      "${IMAGE}:${VERSION}"
    echo "==> promoting :latest-php -> ${IMAGE}:${VERSION}-php"
    docker buildx imagetools create --tag "${IMAGE}:latest-php"  "${IMAGE}:${VERSION}-php"
fi

DIGEST_PLAIN="$(docker buildx imagetools inspect "${IMAGE}:${VERSION}"      --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
DIGEST_PHP="$(docker   buildx imagetools inspect "${IMAGE}:${VERSION}-php"  --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
echo "==> pushed ${IMAGE}:${VERSION}     ${DIGEST_PLAIN:-(digest lookup failed; image is published)}"
echo "==> pushed ${IMAGE}:${VERSION}-php ${DIGEST_PHP:-(digest lookup failed; image is published)}"

if [[ "$RETAG_LATEST_ONLY" -ne 1 ]]; then
    if git rev-parse --verify --quiet "refs/tags/$GIT_TAG" >/dev/null; then
        echo "==> git tag $GIT_TAG already exists locally; not retagging"
    else
        echo "==> tagging and pushing git tag $GIT_TAG"
        git tag -a "$GIT_TAG" -m "Release $GIT_TAG"
        if git config --get remote.origin.url >/dev/null 2>&1; then
            git push origin "$GIT_TAG"
        else
            echo "    no 'origin' remote configured; git tag created locally only" >&2
        fi
    fi
fi

echo "==> done: ${IMAGE}:${VERSION} + ${IMAGE}:${VERSION}-php$([[ $TAG_LATEST -eq 1 ]] && echo ' (latest + latest-php moved)')"
