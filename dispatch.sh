#!/usr/bin/env bash
# Amp orb dispatch program that runs each orb as a Firecracker microVM:
#
#   amp orb provider /absolute/path/to/dispatch.sh
#
# Amp calls it once per job with the job in environment variables (see
# https://ampcode.com/docs/orbs/self-hosted#dispatch-contract). `pause` saves
# the orb's memory, so its processes keep running after the next `spawn`.
#
# orbctl needs root to start the jailer. The sudo rule that `fc-orb setup`
# installs allows only this command and passes the job's variables through
# the environment, so the orb token never appears in a command line.
set -euo pipefail
case "$ORB_OPERATION" in
	spawn | pause | delete) exec sudo --non-interactive /opt/fc-orb/bin/orbctl "$ORB_OPERATION" ;;
	*)
		echo "unknown ORB_OPERATION: $ORB_OPERATION" >&2
		exit 1
		;;
esac
