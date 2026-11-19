# Design

How the runtime satisfies Amp's [dispatch contract](https://ampcode.com/docs/orbs/self-hosted#dispatch-contract), and
what was measured and tested. Numbers are from one machine: an i9-13900 with 61 GiB of RAM and NVMe btrfs, running
4 vCPU, 8 GiB orbs built from Amp's orb image.

## Parts

| Part | Role |
| --- | --- |
| `dispatch.sh` | The program `amp orb provider` runs once per `spawn`, `pause`, or `delete` job. It runs `orbctl` through `sudo`. |
| `fc-orb` | Operator commands: setup (build, install, sudo rule, `fc-orbd`), provider service install, list, exec, console. |
| `runtime/Containerfile` | Builds Firecracker and its jailer (pinned release), the guest kernel, and `orb-agent`. Nothing runs in it; `setup` copies the files to `/opt/fc-orb`. |
| `runtime/orbctl` | Runs as root on the host, starts each orb's jailer, and drives Firecracker's API. All orb state is its. As `orbctl serve` it is `fc-orbd`. |
| `runtime/guest/` | What goes into every orb's disk (`orb-init`, `orb-agent`, its systemd unit) and `kernel.config`. |
| `scripts/smoke-test.sh` | Runs every job against a stand-in for `amp orb bootstrap` and checks what must survive. |

`fc-orb setup` installs the sudo rule `/etc/sudoers.d/fc-orb`, which lets the operator, and so the provider, run
`/opt/fc-orb/bin/orbctl` as root and passes only the job's variables and the `FC_ORB_*` settings through. The orb
token reaches `orbctl` in its environment, never in a command line. `orbctl` is root-owned in `/opt/fc-orb`, so the
rule cannot be used to run a file the operator can edit.

## The jail

Each orb's Firecracker runs under Firecracker's jailer, in a transient systemd unit `fc-orb-<orb id>.service` in
`fc-orbs.slice`:

- **User:** UID and GID 300000 plus the orb's network slot, clear of `/etc/subuid` and LXD's ranges.
- **Chroot:** `/var/lib/fc-orbs/jail/firecracker/<orb id>/root`, holding the orb's disk, memory snapshot, sockets,
  log, and a hard link to the kernel. Firecracker sees them as `/rootfs.ext4`, `/snap/mem`, and so on, which is also
  what a memory snapshot records, so restores find them again. The jailer makes `/dev` with only `kvm`, `net/tun`,
  `urandom`, and `userfaultfd`, and refuses to start if it already exists, so `orbctl` removes it first.
- **Namespaces:** a new mount namespace, a new PID namespace in which Firecracker is PID 1, and the orb's network
  namespace.
- **Seccomp:** Firecracker's default filters, which are built in.
- **Caps:** `CPUQuota` of the orb's vCPUs × 100%, `CPUWeight` proportional to them, `MemoryMax` of guest memory plus
  256 MiB, `MemorySwapMax=infinity`, and `OOMScoreAdjust=500`. Orbs run on every host CPU unless `FC_ORB_CPUSET` names some (`AllowedCPUs`).
- **Stop:** PID 1 ignores SIGTERM, so the unit is stopped with SIGKILL. A pause has saved the orb by then.

Orb units are ordered before `fc-orbd.service`, so at shutdown systemd stops `fc-orbd` first. `fc-orbd` pauses every
running orb as it stops, and only then are the orb units killed.

## What each job does

**spawn**

1. If Firecracker is already running for the orb, resume it in case a pause was interrupted.
2. Otherwise check that the host has the memory for it (see [Host memory](#host-memory)). If it has, and the orb has a
   valid memory snapshot, start Firecracker and load it.
3. Otherwise boot from the orb's disk. A new orb first gets a disk: a copy of the project snapshot named by
   `ORB_SNAPSHOT_ID` if the runtime has it, else a copy of the image's base disk.
4. Set the guest's clock, hostname, and DNS. A restored guest still shows the time it was paused at.
5. Start `amp orb bootstrap` as the image's user with `ORB_TOKEN`, detached.

**pause**

1. Run `sync` in the guest, so the disk alone holds everything written so far.
2. Pause the VM and write a full snapshot next to the previous one.
3. Kill Firecracker, punch the zero pages out of the memory file, fsync the snapshot and the disk, mark the snapshot
   valid, and swap it in.
4. Remove the orb's network namespace.
5. If the job names `ORB_SNAPSHOT_ID`, copy the orb's disk under that ID.

**delete** kills Firecracker and removes the orb's directory and its jail.

Every job takes a per-orb lock and is safe to repeat.

Amp gives a job five minutes, and every step of one waits only for what is left of `FC_ORB_JOB_SECONDS` (270 s): the
locks, the Firecracker API, and the guest agent. A job out of time fails, and what it leaves the next job can use:

- A pause keeps 60 s for what follows the snapshot. If the snapshot is not written by then, it kills Firecracker and
  stops the orb with its disk, which the `sync` in step 1 brought up to date; the next spawn boots from it.
- A spawn whose boot does not finish stops Firecracker, so the next one boots again rather than resuming a guest
  that never started.
- Pulling a new image and building its base disk runs in a unit of its own, `fc-orb-image-<hash>.service`. The spawn
  waits for it while it has a minute to spare, then fails; the build carries on and a later spawn uses it.

## State

Everything is in `/var/lib/fc-orbs`:

```
images/<image id>-<guest files hash>-<size>g/   base disk built from an orb image
snapshots/<key>/                                project snapshots
orbs/<orb id>/
    config.json      image config, vCPUs, memory, network slot
    console.log      guest serial console
jail/firecracker/<orb id>/root/                 the orb's chroot, owned by its user
    rootfs.ext4      the orb's disk
    snap/            memory snapshot: mem, vmstate, and a `valid` marker
    fc.log           Firecracker's log
```

Orb images are pulled with root's Podman. A base disk is the output of `podman export` written into a sparse ext4 file with `mkfs.ext4 -d`, plus the guest files.
Its directory name includes a hash of those files and the disk size, so a runtime that changes either builds a new
base disk and leaves existing orbs alone. Disks are copied with `cp --reflink=auto`.

A spawn never pulls an image the host has. Instead, every hour (and on `./fc-orb refresh-images`), `fc-orbd` pulls
each tag that has a base disk again, and when the tag has moved, builds a disk of the same size for the new version.
New orbs then start from it; existing orbs keep their own disks. A spawn of that image while the new disk is being
built waits for it. An image pulled by digest has no tag, so it never changes.

Then, and on `./fc-orb gc`, `fc-orbd` deletes what no orb uses and no spawn will:

- base disks whose image is no longer tagged in Podman, or that hold older guest files;
- dangling Podman images, left when a pull replaces a tag;
- project snapshots no new orb was created from in `FC_ORB_SNAPSHOT_DAYS` (14), counted from when one last was;
- the staging directories of an interrupted build or save.

An orb's disk is its own copy, so this never changes an orb. Each start of an orb also trims its `console.log` and
`fc.log` to their last MiB once either passes 4 MiB.

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

The order of writes keeps that true across a power loss. On pause, the memory file, the VM state, and the orb's disk
are fsynced after Firecracker exits, because the guest's last writes may still be in the host's page cache. Only then
is the marker created and its directory synced. On restore, the marker's removal is synced before Firecracker starts.
A marker on disk therefore always means that the memory and the disk next to it belong together. Disk copies, project
snapshots, and imported images are synced before they are renamed into place, so a name never points at a file whose
data was lost.

Firecracker maps the memory file privately and loads pages on demand, which is why a wake takes well under a second
and why the file must stay in place while the orb runs. A new snapshot is written beside it and replaces it only after
Firecracker has exited.

## Host CPUs

Orbs run on all 32 threads, performance and efficiency cores alike. On this i9-13900 both kinds report the same CPU
flags, so a snapshot taken on one restores on the other: an orb booted on the E-cores restored on the P-cores with the
same boot ID and process, and the reverse too. A lone busy vCPU gets the P-cores' speed from the scheduler: `fib(32)`
took 0.132 s unpinned, as it did pinned. The same loop took 0.063 s on P-cores and 0.103 s on E-cores.

Each orb's unit caps it at its vCPUs (`CPUQuota`), so orbs' vCPUs may add up to more than the host's threads. A spawn
is refused past `FC_ORB_CPU_OVERCOMMIT` (4) times the host CPUs, 128 vCPUs here; memory runs out first with 8 GiB
orbs. Eight 4-vCPU orbs with eight busy processes each used 378% to 396% each, kept the host 96% busy on all 32
threads, and a short command on the host still took 29 ms. Orbs sit in `fc.slice`, beside `user.slice` and
`system.slice` at equal CPU weight, so the desktop keeps a share however busy the orbs are.

## Host memory

Every orb booted from disk has Firecracker's balloon device with free page reporting, inflated to 0 MiB. The guest
reports the memory it frees, and Firecracker releases it with `MADV_DONTNEED`. The guest reports about 512 MiB every
2 s. In a cold-booted orb, 3 GiB freed by a process was back on the host within 14 s. In a restored orb, a reported
page reads the snapshot file's old contents again instead of zeros. The guest makes no assumption about free pages,
and a 1 GiB checksummed buffer survived freeing memory and two pause and restore cycles.

Page cache is not free memory, so it is not reported and stays on the host until the orb pauses. Dropping caches at
pause does not help, because reporting is slower than writing the pages into the snapshot. DAMON_RECLAIM (in the guest
kernel) freed cold cache unevenly in testing: 1 GiB, then a stall of a minute or more.

Pause time still follows configured memory, because a full snapshot reads all of guest memory. A diff snapshot without
dirty page tracking writes the pages `mincore` reports as resident. For a restored orb that is every page of the
snapshot file in the host's page cache, so it wrote all 8 GiB and was slower than a full snapshot. KVM dirty page
tracking would make diffs exact. It is a developer preview in Firecracker v1.18 and costs CPU in every running orb.

### Overcommit

Orbs are overcommitted: their configured memory may add up to more than RAM, and swap absorbs what they use beyond
it. Before Firecracker starts, spawn adds the new orb's size to the configured memory of the running orbs. The total
must stay within

```
min(FC_ORB_MEM_OVERCOMMIT × RAM, RAM + swap − reserve) − what the rest of the host uses
```

`FC_ORB_MEM_OVERCOMMIT` is 2 and the reserve (`FC_ORB_MEM_RESERVE_MIB`) a tenth of RAM by default. What the rest of
the host uses (the desktop, libvirt VMs) is measured at spawn: MemTotal − MemAvailable − the orbs' `RssAnon`. The
second term means that if every orb grew to its full size at once, RAM and swap would still hold it. A refused spawn
fails with the numbers, leaves a paused orb's snapshot as it was, and removes a new orb's disk. Spawns hold a lock
from the check until the guest answers, so concurrent spawns each count the orbs the others start.

On this host (61 GiB RAM, a 64 GiB swapfile with zswap, 18 GiB used by the rest of the host) the limit came to
101 GiB: twelve 8 GiB orbs started and the thirteenth was refused. Each of the twelve then filled 4.5 GiB with random
data, the worst case for zswap. The host swapped 32 GiB, with no OOM kill, and stayed responsive (40 ms for a short
command). All twelve buffers' checksums were intact afterwards. Reading an orb's swapped memory back took about 17 s;
pausing one took 41 s, because the snapshot reads its memory in. Swap use was higher than the orbs' data alone,
because zswap kept random pages it could barely compress; real orb memory compresses better.

### Pressure loop

Every 5 s, `fc-orbd` compares the host's MemAvailable with the reserve. When it is short, it asks the guests holding
the most file cache (`Active(file)` + `Inactive(file)`) to drop the difference, keeping 256 MiB each, through their
root cgroup's `memory.reclaim`. Free page reporting returns the pages to the host, so it waits 30 s before asking
again. That keeps the host from swapping out guest page cache, which would cost a disk write now and a read later.
Asked for 5,000 MiB with three orbs holding 3 GiB of cache each, it took 2,869 and 2,131 MiB from the two largest, and
the host had them back within 20 s.

The check does not pause other orbs to make room. The runtime cannot tell an idle orb from one whose agent is
waiting on a model, and Amp pauses idle orbs itself.

Firecracker runs with `oom_score_adj` 500. User processes, including the provider, run at 200, so otherwise the
OOM killer would pick them before an orb many times their size. An orb it kills boots from its disk.

## Network

Each orb has a network namespace `orb<slot>`. In it, the orb's tap device, owned by the orb's user, is the guest's
gateway on a /30 from `10.213.0.0/16`. A veth pair (`vorb<slot>` on the host) on a /30 from `10.214.0.0/16` joins the
namespace to the host, which routes the orb's /30 to it. The `inet fc_orbs` nftables table masquerades orb traffic
out of the host and drops traffic between orbs and to the host's own addresses. It also refuses what orbs send to
any non-public IPv4 range (`NON_PUBLIC_NETWORKS` in `orbctl`): the LAN, Tailscale's `100.64.0.0/10`, libvirt and
Multipass networks, and link-local and metadata addresses. Refusing rather than dropping makes such a connection
fail at once. Guests have no IPv6, but the host forwards it, so the table drops IPv6 from orbs. Orbs get only the
host's public DNS servers, else `1.1.1.1` and `8.8.8.8`, since a private resolver such as a home router's is out of
reach. `orbctl` replaces the table on every spawn.

The namespace is deleted on pause and recreated on spawn, with the tap's MAC address derived from its IP. Without
that, a restored guest keeps sending to the old gateway MAC from its neighbor cache and has no network until the entry
expires.

## Guest kernel

`runtime/Containerfile` builds the kernel from a pinned commit of Amazon Linux 2023's `kernel6.18` source, using
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
| Pause | 5 to 8 s alone; four at once take as long in total as four in a row, so `pause-all` goes one at a time |
| Memory snapshot on disk | 192 MiB for an idle orb, 7,689 MiB after a heavy build |
| Python `fib(32)`, best of 3 | 0.132 s in the orb, 0.132 s in a container on the host's P-cores |
| Kernel build | 83 s |
| Amp's `spawn` job for a new thread | 1.5 to 1.8 s |

## What was tested

`scripts/smoke-test.sh` makes 27 checks. Across a pause it confirms the same kernel boot ID, the same PID still
counting, working network, and a correct clock. It also covers repeated jobs, project snapshots, isolation between
orbs and from the LAN, and booting from disk when a memory snapshot cannot be loaded.

A real project ran on it through Amp: a six-container Docker Compose stack with Postgres, a Swift backend, and a web
frontend. In that orb:

- `systemctl start docker`, image builds (8m57s), and the project's test suite (7m05s) worked.
- A portal served the app, inside the orb and from outside through Amp.
- `amp orb desktop ensure` started the Desktop, and its Chrome loaded the app through the portal.
- The tmux session the Terminal tab uses ran commands.
- Amp paused the orb after 20 idle minutes. A message woke it with the same boot ID, container PIDs and start times,
  Chrome, and agent process.
- Rebuilding the runtime under the running orb snapshotted it; the next message restored it with the same processes.

A host reboot kept four running jailed orbs, each holding a 2 GiB process, with the same boot ID and process. During
shutdown `fc-orbd` paused them in 24 s, one at a time, before systemd went on. After boot, `fc-orbd` and the provider
started on their own and each orb restored in about 0.5 s. Restarting `fc-orbd` paused a
running orb and the next spawn restored it with the same boot ID and process. Orbs could not reach the host on its
LAN, Tailscale, or veth addresses. Jailing adds about 0.1 s to a wake (0.5 s instead of 0.4 s).

Killing the provider with `SIGKILL` gets it
restarted by systemd. After the kill, the new provider waited 50 s for Amp to drop the old connection before taking
jobs.

Deadlines, with `FC_ORB_JOB_SECONDS` lowered to force each case:

- A spawn waiting on a held orb lock failed after 5.08 s.
- A pause with a second left for the snapshot stopped the orb with its disk and exited 0 within 2 s. The next spawn
  booted from disk with the files written before the pause.
- A new orb whose cold boot ran out of time left no Firecracker running, and the next spawn booted it.
- The first spawn of `debian:stable-slim` failed while the image was still pulling. The build finished in its unit,
  and the next spawn booted from it in 1.4 s.

`./fc-orb gc` deleted the base disk of an untagged image and one built with other guest files, a project snapshot
untouched for 20 days, and a leftover staging directory. It kept the current base disk and a fresh snapshot.

Image refresh: with `debian:stable-slim` retagged to bookworm and an orb running from it, a refresh pulled trixie and
built its 8 GiB disk. A new orb got trixie, the old orb kept bookworm across a pause, and garbage collection then
deleted bookworm's disk and image. The same pass picked up a real update of Amp's image in 43 s. A refresh with no
change took 2.6 s.

Egress: before the block, an orb opened SSH connections to another host on the campus network and to a Tailscale
peer. After it, those, the gateway, a Multipass VM, and `169.254.169.254` were all refused at once, while GitHub,
PyPI, `1.1.1.1`, and the host's DNS servers worked. The smoke test's LAN check fails against the previous firewall.
