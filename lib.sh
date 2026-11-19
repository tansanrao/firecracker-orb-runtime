# Shared by dispatch.sh and fc-orb: manages the fc-orb-runtime container and
# turns orb images into root disks. Needs only Docker access, not root.

shopt -s inherit_errexit

FC_ORB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FC_ORB_CONTAINER="${FC_ORB_CONTAINER:-fc-orb-runtime}"
FC_ORB_RUNTIME_IMAGE="${FC_ORB_RUNTIME_IMAGE:-fc-orb-runtime:local}"
FC_ORB_VOLUME="${FC_ORB_VOLUME:-fc-orbs}"

# Runs orbctl in the runtime container. A bare --env NAME copies the value
# from this process, so the orb token never appears in a command line.
orbctl() {
	docker exec -i \
		--env ORB_ID --env ORB_IMAGE_ID --env ORB_SNAPSHOT_ID --env ORB_TYPE \
		--env ORB_TOKEN --env AMP_URL \
		--env FC_ORB_VCPUS --env FC_ORB_MEM_MIB --env FC_ORB_MEM_RESERVE_MIB --env FC_ORB_DISK_GIB \
		--env FC_ORB_CPUSET --env FC_ORB_BOOTSTRAP_CMD \
		"$FC_ORB_CONTAINER" orbctl "$@"
}

build_runtime() {
	docker build --quiet --tag "$FC_ORB_RUNTIME_IMAGE" "$FC_ORB_ROOT/runtime" >/dev/null
}

# Starts the runtime container unless it is running. Orbs do not survive the
# container, so nothing here replaces a running one; `fc-orb setup` does that.
ensure_runtime() {
	if [[ "$(docker inspect --format '{{.State.Running}}' "$FC_ORB_CONTAINER" 2>/dev/null)" == true ]]; then
		return
	fi
	(
		flock 9
		if docker inspect "$FC_ORB_CONTAINER" >/dev/null 2>&1; then
			docker start "$FC_ORB_CONTAINER" >/dev/null
			return
		fi
		docker image inspect "$FC_ORB_RUNTIME_IMAGE" >/dev/null 2>&1 || build_runtime
		# --stop-timeout gives `orbctl serve` time to snapshot running orbs
		# when the container or the host shuts down.
		docker run --detach --init --name "$FC_ORB_CONTAINER" \
			--device /dev/kvm --device /dev/net/tun --cap-add NET_ADMIN \
			--sysctl net.ipv4.ip_forward=1 \
			--stop-timeout 300 --restart unless-stopped \
			--volume "$FC_ORB_VOLUME:/var/lib/fc-orbs" \
			"$FC_ORB_RUNTIME_IMAGE" >/dev/null
	) 9>"${TMPDIR:-/tmp}/fc-orb-runtime.lock"
}

# Prints the ID of the orb image's root disk, building the disk on first use:
# the image's filesystem becomes an ext4 file that new orbs are cloned from.
ensure_image() {
	local image="$1" image_id container
	(
		flock 9
		if ! image_id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null)"; then
			docker pull --quiet "$image" >&2
			image_id="$(docker image inspect --format '{{.Id}}' "$image")"
		fi
		if [[ "$(orbctl has-image "$image_id")" != yes ]]; then
			echo "[fc-orb] building a root disk from $image (once per image, about a minute)" >&2
			container="$(docker create "$image")"
			trap 'docker rm --force "$container" >/dev/null' EXIT
			docker export "$container" |
				orbctl import-image "$image_id" "$(docker image inspect --format '{{json .Config}}' "$image")"
		fi
		echo "$image_id"
	) 9>"${TMPDIR:-/tmp}/fc-orb-image.lock"
}
