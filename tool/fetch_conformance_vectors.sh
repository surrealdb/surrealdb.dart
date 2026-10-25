#!/bin/sh
# Fetches the shared CBOR test vectors from surrealdb-protocol into
# test/conformance/vectors, which git ignores: the vectors are not committed
# here. Run it from the repository root before the tests.
#
#   tool/fetch_conformance_vectors.sh          # the pinned release, checked
#   tool/fetch_conformance_vectors.sh v0.15.0  # a new release: pins it
#
# With no tag it fetches the release in test/conformance/VERSION and checks
# the files against test/conformance/vectors.sha256. With a tag it fetches
# that release and writes both files, to be reviewed and committed.
set -eu
pinned=$(cat test/conformance/VERSION)
tag=${1:-$pinned}
dir=test/conformance/vectors
sums=test/conformance/vectors.sha256
base=https://raw.githubusercontent.com/surrealdb/surrealdb-protocol/$tag/spec/vectors
mkdir -p "$dir"
for file in cbor.yaml cbor2.yaml; do
  curl -fsSL "$base/$file" -o "$dir/$file"
done
if [ "$tag" = "$pinned" ] && [ -z "${1:-}" ]; then
  (cd "$dir" && shasum -a 256 -c "../$(basename "$sums")") || {
    rm -f "$dir"/*.yaml
    echo "The vectors for $tag do not match $sums" >&2
    exit 1
  }
else
  (cd "$dir" && shasum -a 256 cbor.yaml cbor2.yaml) > "$sums"
  echo "$tag" > test/conformance/VERSION
  echo "Pinned $tag: review and commit test/conformance/VERSION and $sums"
fi
