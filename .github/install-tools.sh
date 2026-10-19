#!/usr/bin/env bash
# Installs the pipeline's tools on a GitHub-hosted runner (linux/amd64), in the
# versions of the setup guide: the hosted runner has its own Go and kubectl,
# in versions that change with the runner image. The runner of the training
# git server and a Jenkins agent have these tools installed on the host; this
# script is the GitHub counterpart of that host setup, not a pipeline stage.
#
# Usage: .github/install-tools.sh <dir> <tool>...   tools: go k3d kubectl
# Installs into <dir> and prints the directories to put on PATH, one per line
# (the workflows append them to $GITHUB_PATH). Every download is checked
# against the SHA-256 pinned here, not against a checksum file from the same
# server. A version change = new version + new checksum.
set -euo pipefail

GO_VERSION=1.27.2
GO_SHA256=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5
K3D_VERSION=v5.9.0
K3D_SHA256=06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0
KUBECTL_VERSION=v1.37.1
KUBECTL_SHA256=65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8

[ $# -ge 2 ] || { echo "usage: $0 <dir> <tool>... (go k3d kubectl)" >&2; exit 1; }
dir=$1; shift
mkdir -p "$dir/bin"

# fetch <url> <sha256> <file>
fetch() {
	curl -fsSL -o "$3" "$1"
	echo "$2  $3" | sha256sum -c --quiet - >&2
}

for tool in "$@"; do
	case "$tool" in
	go)
		fetch "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz" "$GO_SHA256" "$dir/go.tar.gz"
		rm -rf "$dir/go"
		tar -C "$dir" -xzf "$dir/go.tar.gz"
		rm "$dir/go.tar.gz"
		echo "$dir/go/bin"
		;;
	k3d)
		fetch "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-linux-amd64" "$K3D_SHA256" "$dir/bin/k3d"
		chmod 0755 "$dir/bin/k3d"
		;;
	kubectl)
		fetch "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl" "$KUBECTL_SHA256" "$dir/bin/kubectl"
		chmod 0755 "$dir/bin/kubectl"
		;;
	*)
		echo "unknown tool: $tool (go k3d kubectl)" >&2; exit 1
		;;
	esac
done
echo "$dir/bin"
