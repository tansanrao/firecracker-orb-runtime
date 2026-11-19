#!/usr/bin/env bash
# Drives dispatch.sh the way `amp orb provider` does, with a stand-in for
# `amp orb bootstrap`, and checks what an orb must keep across each job.
# Needs no Amp account. Takes about a minute.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
RUNTIME="${FC_ORB_CONTAINER:-fc-orb-runtime}"

A="amp-smoketest-a-$$"
B="amp-smoketest-b-$$"
SNAPSHOT="smoketest/snapshot:$$"
export ORB_IMAGE="${ORB_IMAGE:-us-central1-docker.pkg.dev/amp-prod-0/amp-orb/amp-orb:latest}"
export FC_ORB_BOOTSTRAP_CMD='echo "bootstrap user=$(id -un) token=$ORB_TOKEN" >>/tmp/bootstrap.log; exec sleep infinity'

job() { # job <operation> <orb> [NAME=value ...]
	local operation="$1" orb="$2"
	shift 2
	env ORB_OPERATION="$operation" ORB_ID="$orb" "$@" "$ROOT/dispatch.sh"
}
guest() { "$ROOT/fc-orb" exec --user user "$@"; }
state() { "$ROOT/fc-orb" list | awk -v orb="$1" '$1 == orb { print $2 }'; }
guest_ip() { "$ROOT/fc-orb" list | awk -v orb="$1" '$1 == orb { print $NF }'; }

failures=0
check() { # check <description> <command...>
	local description="$1"
	shift
	if "$@"; then
		echo "ok    $description"
	else
		echo "FAIL  $description"
		failures=$((failures + 1))
	fi
}
equal() { [[ "$1" == "$2" ]] || { echo "      expected '$2', got '$1'"; return 1; }; }

cleanup() {
	job delete "$A" >/dev/null 2>&1 || true
	job delete "$B" >/dev/null 2>&1 || true
	docker exec "$RUNTIME" sh -c 'rm -rf /var/lib/fc-orbs/snapshots/smoketest_snapshot_*' || true
}
trap cleanup EXIT

echo "== spawn a new orb"
job spawn "$A" ORB_TOKEN=first
check "new orb is running" equal "$(state "$A")" running
check "bootstrap ran as the image's user with the token" \
	equal "$(guest "$A" 'cat /tmp/bootstrap.log')" "bootstrap user=user token=first"
check "guest reaches ampcode.com" guest "$A" 'curl -fsS -m 10 -o /dev/null https://ampcode.com/'
check "user has passwordless sudo" equal "$(guest "$A" 'sudo -n id -u')" 0

# A process whose state lives only in memory (tmpfs and its own counter).
guest "$A" 'nohup python3 -c "
import time
n = 0
while True:
    n += 1
    open(\"/dev/shm/counter\", \"w\").write(str(n))
    time.sleep(0.1)
" >/dev/null 2>&1 &
echo $! >/dev/shm/counter.pid
echo on-disk >~/disk-marker
python3 -m http.server 8000 >/dev/null 2>&1 &
sleep 1'
boot_id="$(guest "$A" 'cat /proc/sys/kernel/random/boot_id')"
counter_pid="$(guest "$A" 'cat /dev/shm/counter.pid')"

echo "== pause, then spawn again"
job pause "$A"
check "paused orb has a memory snapshot" equal "$(state "$A")" paused
check "paused orb has no Firecracker process" \
	equal "$(docker exec "$RUNTIME" pgrep -fc "orbs/$A/fc.sock" || true)" 0
job pause "$A"
check "pausing a paused orb changes nothing" equal "$(state "$A")" paused
sleep 3
job spawn "$A" ORB_TOKEN=second
check "same kernel boot after resume (restored, not rebooted)" \
	equal "$(guest "$A" 'cat /proc/sys/kernel/random/boot_id')" "$boot_id"
before="$(guest "$A" 'cat /dev/shm/counter')"
sleep 1
after="$(guest "$A" 'cat /dev/shm/counter')"
check "process from before the pause is the same PID" guest "$A" "kill -0 $counter_pid"
check "that process keeps counting ($before -> $after)" test "$after" -gt "$before"
check "bootstrap ran again with the new token" \
	equal "$(guest "$A" 'tail -n 1 /tmp/bootstrap.log')" "bootstrap user=user token=second"
check "guest network works after resume" guest "$A" 'curl -fsS -m 10 -o /dev/null https://ampcode.com/'
skew="$(($(guest "$A" 'date +%s') - $(date +%s)))"
check "guest clock matches the host after resume (skew ${skew}s)" test "${skew#-}" -le 2

echo "== spawn a running orb"
job spawn "$A" ORB_TOKEN=third
check "spawning a running orb keeps it running" \
	equal "$(guest "$A" 'cat /proc/sys/kernel/random/boot_id')" "$boot_id"

echo "== project snapshot"
job pause "$A" ORB_SNAPSHOT_ID="$SNAPSHOT"
job spawn "$A" ORB_TOKEN=fourth
check "orb still has its memory after saving a project snapshot" guest "$A" "kill -0 $counter_pid"
job spawn "$B" ORB_TOKEN=first ORB_SNAPSHOT_ID="$SNAPSHOT"
check "new orb from the snapshot has the first orb's files" \
	equal "$(guest "$B" 'cat ~/disk-marker')" on-disk
check "new orb from the snapshot is a separate machine" \
	test "$(guest "$B" 'cat /proc/sys/kernel/random/boot_id')" != "$boot_id"
guest "$B" 'echo only-in-b >~/disk-marker'
check "the two orbs' disks are independent" equal "$(guest "$A" 'cat ~/disk-marker')" on-disk

echo "== isolation between orbs"
a_ip="$(guest_ip "$A")"
check "an orb reaches its own service" guest "$A" "curl -fsS -m 3 -o /dev/null http://$a_ip:8000/"
check "another orb cannot reach that service" \
	bash -c "! '$ROOT/fc-orb' exec --user user '$B' 'curl -fsS -m 3 -o /dev/null http://$a_ip:8000/' 2>/dev/null"

echo "== unusable memory snapshot"
job pause "$A"
docker exec "$RUNTIME" sh -c "echo corrupt >/var/lib/fc-orbs/orbs/$A/snap/vmstate"
job spawn "$A" ORB_TOKEN=fifth
check "orb boots from its disk when the snapshot cannot be loaded" \
	test "$(guest "$A" 'cat /proc/sys/kernel/random/boot_id')" != "$boot_id"
check "its files survive that" equal "$(guest "$A" 'cat ~/disk-marker')" on-disk

echo "== delete"
job delete "$A"
job delete "$B"
job delete "$B"
check "deleted orbs are gone" equal "$(state "$A")$(state "$B")" ""
check "their tap devices are gone" \
	equal "$(docker exec "$RUNTIME" sh -c 'ls /sys/class/net | grep -c orbtap' || true)" \
	"$("$ROOT/fc-orb" list | grep -c running || true)"

echo
if ((failures > 0)); then
	echo "$failures check(s) failed"
	exit 1
fi
echo "all checks passed"
