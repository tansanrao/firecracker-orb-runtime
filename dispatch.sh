#!/usr/bin/env bash
# Amp orb dispatch program that runs each orb as a Firecracker microVM:
#
#   amp orb provider /absolute/path/to/dispatch.sh
#
# Amp calls it once per job with the job in environment variables (see
# https://ampcode.com/docs/orbs/self-hosted#dispatch-contract). `pause` saves
# the orb's memory, so its processes keep running after the next `spawn`.
set -euo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib.sh"

ensure_runtime
case "$ORB_OPERATION" in
	spawn)
		# Only a new orb without a project snapshot needs the image's disk.
		if [[ "$(orbctl needs-image)" == yes ]]; then
			ORB_IMAGE_ID="$(ensure_image "$ORB_IMAGE")"
			export ORB_IMAGE_ID
		fi
		orbctl spawn
		;;
	pause | delete)
		orbctl "$ORB_OPERATION"
		;;
	*)
		echo "unknown ORB_OPERATION: $ORB_OPERATION" >&2
		exit 1
		;;
esac
