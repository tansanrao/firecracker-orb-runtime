# firecracker-orb-runtime

Runs [self-hosted Amp orbs](https://ampcode.com/docs/orbs/self-hosted) as Firecracker microVMs on one Linux machine.

When Amp pauses an orb, the runtime saves the guest's memory to disk and exits Firecracker, so a sleeping orb uses no
CPU or RAM. The next message restores it with its processes still running: containers, dev servers, the Desktop's
Chrome, and tmux sessions keep their PIDs. Docker-backed orbs lose all of that on every pause.

Measured on an i9-13900 with 4 vCPU, 8 GiB orbs:

| | |
| --- | --- |
| New orb, from job to bootstrap started | 1.1 to 1.5 s |
| Wake from sleep | 0.4 s idle, 1.3 s with 7.7 GiB of memory in use |
| Pause | about 5 s |
| Single-thread speed | same as a container on the host (Python `fib(32)`: 0.132 s in both) |

It is built for one trusted user on one host. See [Known limits](#known-limits) before relying on it, and
[docs/design.md](docs/design.md) for how it works and what was tested.

## Requirements

- Linux x86-64 with KVM (`/dev/kvm`).
- Docker, and a user who can run it. Nothing else needs root.
- The `amp` CLI, signed in.
- A filesystem with reflinks (btrfs or XFS) under Docker's data directory, so that creating an orb's disk is instant.
  Other filesystems work and copy the disk instead.
- Disk space: each orb takes what it writes to its disk, plus up to its memory size while it sleeps.

Firecracker, the guest kernel, the tap devices, and the NAT rules all live in one container, `fc-orb-runtime`. No
packages are installed on the host and its network configuration is not changed.

## Setup

1. Build the runtime and prepare the orb image's disk. The first run builds the guest kernel and pulls Amp's 6 GB orb
   image, which takes about five minutes plus the download.

   ```bash
   ./fc-orb setup
   ```

2. Check it. This drives `dispatch.sh` the way Amp does, without an Amp account, and takes about a minute.

   ```bash
   ./scripts/smoke-test.sh
   ```

3. Create an orb provider. This saves its token with your Amp credentials on this machine. Pick any name.

   ```bash
   amp orb provider create my-firecracker
   ```

4. Run the provider as a systemd user service.

   ```bash
   ./fc-orb install-service
   loginctl enable-linger "$USER"      # start it at boot, without a login
   ```

5. Start a thread on it. In the composer, open **Orb** and choose the provider under **Self-Hosted**, or:

   ```bash
   amp -ox "uname -r; nproc" --orb-provider my-firecracker
   ```

6. Optionally make it the default for your new threads. `builtin` switches back to Amp-hosted orbs.

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
```

An orb's ID is `amp-` followed by its thread ID without the `T-`.

`docker stop fc-orb-runtime` snapshots the running orbs first, and they resume from memory on their next message.
That message waits about 35 s, because Amp did not know the orb was asleep. The container has a 300 s stop timeout so
that a host shutdown can do the same; that path is untested.

## Updating

| What | How |
| --- | --- |
| This repository's code | `./fc-orb setup`. It rebuilds the runtime and, if the image changed, pauses running orbs and restarts the container. |
| Guest kernel | Set `KERNEL_COMMIT` in `runtime/Dockerfile` to the commit of the newest `kernel6.18-*` tag (the command is in a comment there), then `./fc-orb setup` and `./scripts/smoke-test.sh`. |
| Kernel options | Add them to `runtime/guest/kernel.config`. The build fails if an option does not take effect. |
| Firecracker | Set `FIRECRACKER_VERSION`, `FIRECRACKER_SHA256`, and `FIRECRACKER_COMMIT` in `runtime/Dockerfile`. Memory snapshots from another version may not load; those orbs boot from disk and keep their files. |
| Orb image | `docker pull` the image, then `./fc-orb setup`. The runtime never pulls an image it already has. Existing orbs keep the image they started from. |

The guest kernel is Amazon Linux 2023's `kernel6.18` source built with Firecracker's own microVM config, which is the
pairing Firecracker validates and supports until at least June 2028. A sleeping orb keeps the kernel it booted, because
its memory snapshot contains the running kernel; it gets a new one the next time it boots from disk.

## Settings

Set these in the provider's environment: run `systemctl --user edit fc-orb-provider`, add `Environment=` lines under
`[Service]`, and restart the service.

| Variable | Default | Meaning |
| --- | --- | --- |
| `FC_ORB_VCPUS`, `FC_ORB_MEM_MIB` | `4`, `8192` | Size of an orb whose thread picked no orb type. |
| `FC_ORB_DISK_GIB` | `64` | Root disk size for orbs created afterwards. The file is sparse. |
| `FC_ORB_CPUSET` | performance cores, else all | Host CPUs orbs run on, such as `0-15`. On a hybrid Intel CPU the default keeps vCPUs off the efficiency cores. |
| `ORB_IMAGE` | Amp's orb image | The image new orbs boot from. |

If you add orb types to the provider in Amp's settings, the names `small` (2 vCPUs, 4 GiB), `medium` (4, 8), `large`
(8, 16), and `xlarge` (16, 32) set an orb's size. Edit `ORB_TYPES` in `runtime/orbctl` for others.

## Removing it

```bash
amp orb provider set-default builtin
systemctl --user disable --now fc-orb-provider
rm ~/.config/systemd/user/fc-orb-provider.service
./fc-orb destroy                                 # deletes the container and ALL orbs, disks, and snapshots
```

Then delete the provider under **Settings → Orbs**.

## Known limits

- **One trusted user.** Firecracker runs as root in a container, without its jailer and without per-orb CPU or I/O
  limits. Do not run untrusted code or other people's threads on it.
- **Running orbs do not return memory.** Each one can grow to its full size on the host until it pauses.
- **Pause time follows configured memory.** Firecracker writes all of an orb's memory before the unused part is
  dropped. One 8 GiB orb takes about 5 s; four at once took about 20 s each.
- **A portal does not wake a sleeping orb.** Amp answers the request itself and sends no job. Send the thread a
  message to wake it.
- **Nothing is cleaned up.** Base disks of old images and unused project snapshots stay in the `fc-orbs` volume. An
  orb's disk keeps the size it was created with.
- **Open connections do not survive a long sleep.** Processes resume, but the other end of a TCP connection will have
  hung up.
- **Untested:** a host reboot, Amp saving and reusing a project snapshot, and stopping the provider during a job.
- **x86-64 only.**
