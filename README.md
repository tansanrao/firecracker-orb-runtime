# firecracker-orb-runtime

Runs [self-hosted Amp orbs](https://ampcode.com/docs/orbs/self-hosted) as Firecracker microVMs on one Linux machine.

When Amp pauses an orb, the runtime saves the guest's memory to disk and exits Firecracker, so a sleeping orb uses no
CPU or RAM. The next message restores it with its processes still running: containers, dev servers, the Desktop's
Chrome, and tmux sessions keep their PIDs. Docker-backed orbs lose all of that on every pause.

Measured on an i9-13900 with 4 vCPU, 8 GiB orbs:

| | |
| --- | --- |
| New orb, from job to bootstrap started | 1.1 to 1.5 s |
| Wake from sleep | 0.5 s idle, 1.3 s with 7.7 GiB of memory in use |
| Pause | about 5 s |
| Single-thread speed | same as a container on the host (Python `fib(32)`: 0.132 s in both) |

It is built for one trusted user on one host. See [Known limits](#known-limits) before relying on it, and
[docs/design.md](docs/design.md) for how it works and what was tested.

## Requirements

- Linux x86-64 with KVM (`/dev/kvm`).
- systemd, `sudo`, Podman (`apt install podman`), and nftables.
- The `amp` CLI, signed in.
- A filesystem with reflinks (btrfs or XFS) under `/var/lib/fc-orbs`, so that creating an orb's disk is instant.
  Other filesystems work and copy the disk instead.
- Disk space: each orb takes what it writes to its disk, plus up to its memory size while it sleeps.
- Swap about the size of RAM, so orbs can be configured for up to twice RAM in total (see step 2).

The runtime runs on the host. `setup` installs Firecracker, its jailer, the guest kernel, and `orbctl` to
`/opt/fc-orb`, the `fc-orbd` system service, and a sudo rule that lets you, and so the provider, run `orbctl` as root.
Each orb's Firecracker runs under the jailer: as its own user, in a chroot, in its own PID and network namespaces, and
in a systemd unit that caps it at the vCPUs and memory it asked for. Orb state lives in `/var/lib/fc-orbs`, and the
orbs' NAT and isolation rules in the `inet fc_orbs` nftables table.

## Setup

1. Build and install the runtime, and prepare the orb image's disk. It asks for your password through `sudo`. The
   first run builds the guest kernel and pulls Amp's 6 GB orb image, which takes about five minutes plus the
   download.

   ```bash
   ./fc-orb setup
   ```

2. Add swap, with zswap in front of it, so that orbs configured for more than RAM swap instead of meeting the OOM
   killer. On btrfs root, with RAM of 64 GiB:

   ```bash
   sudo btrfs subvolume create /swap
   sudo btrfs filesystem mkswapfile --size 64g /swap/swapfile
   sudo swapon /swap/swapfile
   echo '/swap/swapfile none swap defaults 0 0' | sudo tee -a /etc/fstab
   echo 'GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT zswap.enabled=1 zswap.compressor=zstd"' |
       sudo tee /etc/default/grub.d/90-fc-orb-zswap.cfg
   sudo update-grub                       # zswap from the next boot; also `echo Y` to its sysfs `enabled` now
   ```

   Spawns count swap, so without it orbs are limited to RAM.

3. Check it. This drives `dispatch.sh` the way Amp does, without an Amp account, and takes about a minute.

   ```bash
   ./scripts/smoke-test.sh
   ```

4. Create an orb provider. This saves its token with your Amp credentials on this machine. Pick any name.

   ```bash
   amp orb provider create my-firecracker
   ```

5. Run the provider as a systemd user service.

   ```bash
   ./fc-orb install-service
   loginctl enable-linger "$USER"      # start it at boot, without a login
   ```

6. Start a thread on it. In the composer, open **Orb** and choose the provider under **Self-Hosted**, or:

   ```bash
   amp -ox "uname -r; nproc" --orb-provider my-firecracker
   ```

7. Optionally make it the default for your new threads. `builtin` switches back to Amp-hosted orbs.

   ```bash
   amp orb provider set-default my-firecracker
   ```

Run exactly one provider per token. Do not also run `amp orb provider` by hand while the service is active.

## Operating it

```bash
./fc-orb list                                    # orbs: running, paused (memory saved), or stopped (disk only)
./fc-orb exec --user user <orb> 'nproc; free -m' # run a script in a running orb
./fc-orb console <orb>                           # guest serial console and Firecracker log
./fc-orb pause-all                               # snapshot and stop every running orb

systemctl --user status fc-orb-provider          # the provider
journalctl --user -u fc-orb-provider -f          # its log: every job, and the runtime's output for it
systemctl status 'fc-orb-*.service'              # running orbs' Firecracker units, with CPU and memory use
```

An orb's ID is `amp-` followed by its thread ID without the `T-`.

Stopping `fc-orbd` (`sudo systemctl stop fc-orbd`, or a host shutdown) snapshots the running orbs first, and they
resume from memory on their next message. That message waits about 35 s, because Amp did not know the orb was asleep.

## Updating

| What | How |
| --- | --- |
| This repository's code | `./fc-orb setup`. Running orbs keep running; the next job uses the new `orbctl`. |
| Guest kernel | Set `KERNEL_COMMIT` in `runtime/Containerfile` to the commit of the newest `kernel6.18-*` tag (the command is in a comment there), then `./fc-orb setup` and `./scripts/smoke-test.sh`. |
| Kernel options | Add them to `runtime/guest/kernel.config`. The build fails if an option does not take effect. |
| Firecracker | Set `FIRECRACKER_VERSION`, `FIRECRACKER_SHA256`, and `FIRECRACKER_COMMIT` in `runtime/Containerfile`. Memory snapshots from another version may not load; those orbs boot from disk and keep their files. |
| Orb image | Automatic: `fc-orbd` pulls each orb image every hour and builds a disk for a new version, so new orbs start from it. `./fc-orb refresh-images` does it now. Existing orbs keep the image they started from. To pin a version, set `ORB_IMAGE` to a reference by digest. |

The guest kernel is Amazon Linux 2023's `kernel6.18` source built with Firecracker's own microVM config, which is the
pairing Firecracker validates and supports until at least June 2028. A sleeping orb keeps the kernel it booted, because
its memory snapshot contains the running kernel; it gets a new one the next time it boots from disk.

## Settings

Set these in the provider's environment: run `systemctl --user edit fc-orb-provider`, add `Environment=` lines under
`[Service]`, and restart the service. The sudo rule passes only these variables to `orbctl`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `FC_ORB_VCPUS`, `FC_ORB_MEM_MIB` | `4`, `8192` | Size of an orb whose thread picked no orb type. |
| `FC_ORB_MEM_OVERCOMMIT` | `2` | Orbs may be configured for this many times RAM in total, less what the rest of the host uses, and never more than RAM plus swap less the reserve. A spawn past that fails. |
| `FC_ORB_MEM_RESERVE_MIB` | a tenth of RAM | Memory kept for the host. Below this much available, `fc-orbd` asks guests to drop file cache. Set it for `fc-orbd` with `sudo systemctl edit fc-orbd` to change that too. |
| `FC_ORB_DISK_GIB` | `64` | Root disk size for orbs created afterwards. The file is sparse. |
| `FC_ORB_CPU_OVERCOMMIT` | `4` | Running orbs may have this many times the host's CPUs in vCPUs. Each orb is capped at its own vCPUs. |
| `FC_ORB_CPUSET` | all | Host CPUs orbs run on, such as `0-15`. By default they use every thread, performance and efficiency cores alike. |
| `FC_ORB_JOB_SECONDS` | `270` | How long a job may take. Amp allows five minutes. |
| `FC_ORB_SNAPSHOT_DAYS` | `14` | Project snapshots no new orb has used for this many days are deleted. `fc-orbd` reads this one: set it with `sudo systemctl edit fc-orbd`. |
| `ORB_IMAGE` | Amp's orb image | The image new orbs boot from. |

If you add orb types to the provider in Amp's settings, the names `small` (2 vCPUs, 4 GiB), `medium` (4, 8), `large`
(8, 16), and `xlarge` (16, 32) set an orb's size. Edit `ORB_TYPES` in `runtime/orbctl` for others.

## Removing it

```bash
amp orb provider set-default builtin
systemctl --user disable --now fc-orb-provider
rm ~/.config/systemd/user/fc-orb-provider.service
./fc-orb destroy                                 # deletes ALL orbs, disks, and snapshots, and /opt/fc-orb
```

Then delete the provider under **Settings → Orbs**.

## Known limits

- **One trusted user.** Each orb is jailed and capped, but `orbctl` runs as root for anyone in the sudo rule, there
  is no AppArmor profile yet, orbs can reach the LAN, and there are no I/O limits. Do not run other people's threads
  on it.
- **Running orbs return freed memory, but not their page cache.** After a process in an orb exits, the host gets its
  memory back at about 250 MiB/s. Files the orb has read stay cached in it until the host runs short of memory, when
  `fc-orbd` asks the guests with the most cache to drop it. Past that, orb memory goes to swap: a heavily swapped orb
  is slow, and its pause takes longer because the snapshot reads its memory back in (41 s for a 5 GiB orb). The
  thread's setup log says why a spawn was refused. Archiving idle threads pauses their orbs and frees their memory.
- **Pause time follows configured memory.** Firecracker writes all of an orb's memory before the unused part is
  dropped. One 8 GiB orb takes about 5 s; four at once took about 20 s each.
- **A portal does not wake a sleeping orb.** Amp answers the request itself and sends no job. Send the thread a
  message to wake it.
- **Orbs stay until their thread is deleted.** Amp sends no job when a thread is archived, so a paused orb keeps its
  disk. Clean-up removes only what no orb uses: see [State](docs/design.md#state). An orb's disk keeps the size it
  was created with.
- **The first spawn of a new image can fail.** Pulling Amp's image and building its disk takes longer than a job may.
  The build keeps going, and starting the orb again once it is done works. `./fc-orb setup` prepares the default
  image ahead of time.
- **Open connections do not survive a long sleep.** Processes resume, but the other end of a TCP connection will have
  hung up.
- **Untested:** Amp saving and reusing a project snapshot, and stopping the provider during a job.
- **x86-64 only.**
