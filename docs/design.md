# Design

How the runtime satisfies Amp's [dispatch contract](https://ampcode.com/docs/orbs/self-hosted#dispatch-contract), and
what was measured and tested. Numbers are from one machine: an i9-13900 with 61 GiB of RAM and NVMe btrfs, running
4 vCPU, 8 GiB orbs built from Amp's orb image.

## Parts

| Part | Role |
| --- | --- |
| `dispatch.sh` | The program `amp orb provider` runs once per `spawn`, `pause`, or `delete` job. |
| `fc-orb` | Operator commands: setup, service install, list, exec, console. |
| `lib.sh` | Starts the runtime container and turns an orb image into a root disk. Shared by the two scripts above. |
| `runtime/Dockerfile` | The `fc-orb-runtime` image: Firecracker, the guest kernel, `orbctl`, and the guest files. |
| `runtime/orbctl` | Runs as root in the container and drives Firecracker's API. All orb state is its. |
| `runtime/guest/` | What goes into every orb's disk (`orb-init`, `orb-agent`, its systemd unit) and `kernel.config`. |
| `scripts/smoke-test.sh` | Runs every job against a stand-in for `amp orb bootstrap` and checks what must survive. |

The host side needs only Docker. The container runs with `--device /dev/kvm`, `--device /dev/net/tun`, and
`NET_ADMIN`, so tap devices and NAT rules live in its network namespace.

## What each job does

**spawn**

1. If Firecracker is already running for the orb, resume it in case a pause was interrupted.
2. Otherwise, if the orb has a valid memory snapshot, start Firecracker and load it.
3. Otherwise boot from the orb's disk. A new orb first gets a disk: a copy of the project snapshot named by
   `ORB_SNAPSHOT_ID` if the runtime has it, else a copy of the image's base disk.
4. Set the guest's clock, hostname, and DNS. A restored guest still shows the time it was paused at.
5. Start `amp orb bootstrap` as the image's user with `ORB_TOKEN`, detached.

**pause**

1. Run `sync` in the guest, so the disk alone holds everything written so far.
2. Pause the VM and write a full snapshot next to the previous one.
3. Kill Firecracker, punch the zero pages out of the memory file, fsync it, and swap it in.
4. Remove the tap device.
5. If the job names `ORB_SNAPSHOT_ID`, copy the orb's disk under that ID.

**delete** kills Firecracker and removes the orb's directory.

Every job takes a per-orb lock and is safe to repeat.

## State

Everything is in the `fc-orbs` Docker volume, mounted at `/var/lib/fc-orbs`:

```
images/<image id>-<guest files hash>-<size>g/   base disk built from an orb image
snapshots/<key>/                                project snapshots
orbs/<orb id>/
    rootfs.ext4      the orb's disk
    config.json      image config, vCPUs, memory, network slot
    snap/            memory snapshot: mem, vmstate, and a `valid` marker
    console.log      guest serial console
    fc.log           Firecracker's log
```

A base disk is the output of `docker export` written into a sparse ext4 file with `mkfs.ext4 -d`, plus the guest files.
Its directory name includes a hash of those files and the disk size, so a runtime that changes either builds a new
base disk and leaves existing orbs alone. Disks are copied with `cp --reflink=auto`.

## The guest

The kernel mounts the disk as root, configures `eth0` from its `ip=` argument, and runs `/sbin/orb-init`. When the
image has systemd, as Amp's does, `orb-init` execs it. Amp's image expects systemd: its Docker config uses the systemd
cgroup driver and Amp's own services are units. For an image without systemd, `orb-init` mounts what a container
runtime would and runs `orb-agent` as PID 1.

`orb-agent` is a static C program that listens on vsock port 5252 and runs bash scripts the host sends, one per
connection. Firecracker closes open vsock connections across a snapshot but keeps listening sockets, so the same
channel works after a restore with no keys and no network. The script arrives on a memfd, so the orb token is never
in a process's arguments.

## Memory snapshots

A snapshot may be restored once. The `valid` marker is removed before the restored guest runs, because from then on
the disk moves ahead of the saved memory and restoring again would corrupt the filesystem. If a restore fails, or the
host loses power while an orb runs, the orb boots from its disk like a machine after a power cut: files survive,
processes do not.

Firecracker maps the memory file privately and loads pages on demand, which is why a wake takes well under a second
and why the file must stay in place while the orb runs. A new snapshot is written beside it and replaces it only after
Firecracker has exited.

Firecracker's threads are pinned to the host's performance cores (`/sys/devices/cpu_core/cpus`). That gives the
single-thread speed, and it keeps the CPU type the same between snapshot and restore.

## Network

Each orb gets a /30 from `10.213.0.0/16`: the tap device is the gateway and the guest has the other address. The
container masquerades orb traffic, so orbs reach the internet and whatever the host's network allows. A forward rule
drops traffic between orbs.

The tap device is deleted on pause and recreated on spawn with the same MAC address, derived from its IP. Without
that, a restored guest keeps sending to the old gateway MAC from its neighbor cache and has no network until the entry
expires.

## Guest kernel

`runtime/Dockerfile` builds the kernel from a pinned commit of Amazon Linux 2023's `kernel6.18` source, using
`microvm-kernel-ci-x86_64-6.18.config` and `ci.config` from the Firecracker release it installs, plus
`runtime/guest/kernel.config`. Firecracker's
[kernel policy](https://github.com/firecracker-microvm/firecracker/blob/main/docs/kernel-policy.md) names this source
and config as what it validates, and supports 6.18 guests until at least 2028-06-01. Amazon tagged it 31 times
between March and November 2026.

`kernel.config` adds what dockerd reported missing in an orb: nftables for IPv6, NAT, and raw tables, conntrack
netlink, and the ipvlan and macvlan drivers. After `make olddefconfig`, the build checks that every option in the file
is set, because `olddefconfig` drops an option with unmet dependencies without saying so.

Alternatives considered: kernel.org longterm 6.18, which Firecracker does not guarantee its configs against; Kata
Containers' prebuilt kernel, which ships inside a 1 GB archive with a config tuned for Kata's agent; and the prebuilt
kernels in Firecracker's CI bucket, which have no release channel or checksum.

## Measurements

| Measurement | Result |
| --- | --- |
| New orb, job start to bootstrap started | 1.1 to 1.5 s |
| Wake of an idle orb | 0.33 to 0.45 s |
| Wake of an orb with 7.7 GiB in use | 1.3 s |
| Pause | 5 to 8 s alone; about 20 s each when four pause at once |
| Memory snapshot on disk | 192 MiB for an idle orb, 7,689 MiB after a heavy build |
| Python `fib(32)`, best of 3 | 0.132 s in the orb, 0.132 s in a container on the host's P-cores |
| Kernel build | 83 s |
| Amp's `spawn` job for a new thread | 1.5 to 1.8 s |

## What was tested

`scripts/smoke-test.sh` makes 24 checks. Across a pause it confirms the same kernel boot ID, the same PID still
counting, working network, and a correct clock. It also covers repeated jobs, project snapshots, isolation between
orbs, and booting from disk when a memory snapshot cannot be loaded.

A real project ran on it through Amp: a six-container Docker Compose stack with Postgres, a Swift backend, and a web
frontend. In that orb:

- `systemctl start docker`, image builds (8m57s), and the project's test suite (7m05s) worked.
- A portal served the app, inside the orb and from outside through Amp.
- `amp orb desktop ensure` started the Desktop, and its Chrome loaded the app through the portal.
- The tmux session the Terminal tab uses ran commands.
- Amp paused the orb after 20 idle minutes. A message woke it with the same boot ID, container PIDs and start times,
  Chrome, and agent process.
- Rebuilding the runtime under the running orb snapshotted it; the next message restored it with the same processes.

Stopping the runtime with `docker stop` snapshots running orbs, and killing the provider with `SIGKILL` gets it
restarted by systemd. After the kill, the new provider waited 50 s for Amp to drop the old connection before taking
jobs.
