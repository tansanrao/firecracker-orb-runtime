// orb-agent: the host's way into a Firecracker orb.
//
// It runs scripts that the host sends over vsock. In an image with systemd it
// is a service (orb-agent.service); in any other image it is PID 1, so it also
// reaps orphaned processes.
// The host needs this because `spawn` must start `amp orb bootstrap` inside the
// guest on every wake, and the listening vsock socket survives a memory
// snapshot, so the same channel works after a restore.
//
// Protocol, one request per connection:
//   host:  "<length>\n" followed by <length> bytes of bash script
//   guest: the script's stdout and stderr, then "\n\x1eORB-EXIT <code>\n"
//
// Built static so it runs in any orb image.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#include <linux/vm_sockets.h> // needs sys/socket.h first

#define AGENT_PORT 5252
#define MAX_SCRIPT_BYTES (1 << 20)

static void on_sigchld(int sig) { (void)sig; }

static void bring_up_loopback(void) {
	int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (fd < 0) return;
	struct ifreq ifr = {0};
	strncpy(ifr.ifr_name, "lo", IFNAMSIZ - 1);
	if (ioctl(fd, SIOCGIFFLAGS, &ifr) == 0) {
		ifr.ifr_flags |= IFF_UP;
		ioctl(fd, SIOCSIFFLAGS, &ifr);
	}
	close(fd);
}

// Reads the script into an anonymous file, so its text (which can hold the orb
// token) never appears in a process's argv.
static int receive_script(int conn) {
	char header[16];
	size_t n = 0;
	for (;;) {
		char ch;
		if (read(conn, &ch, 1) != 1) return -1;
		if (ch == '\n') break;
		if (ch < '0' || ch > '9' || n >= sizeof(header) - 1) return -1;
		header[n++] = ch;
	}
	header[n] = '\0';
	long remaining = atol(header);
	if (remaining <= 0 || remaining > MAX_SCRIPT_BYTES) return -1;

	int script = memfd_create("orb-script", 0);
	if (script < 0) return -1;
	char buf[65536];
	while (remaining > 0) {
		size_t want = remaining < (long)sizeof(buf) ? (size_t)remaining : sizeof(buf);
		ssize_t got = read(conn, buf, want);
		if (got < 0 && errno == EINTR) continue;
		if (got <= 0) return -1;
		if (write(script, buf, (size_t)got) != got) return -1;
		remaining -= got;
	}
	if (lseek(script, 0, SEEK_SET) < 0) return -1;
	return script;
}

static void serve(int conn, const sigset_t *default_mask) {
	int script = receive_script(conn);
	if (script < 0) _exit(1);

	pid_t child = fork();
	if (child < 0) _exit(1);
	if (child == 0) {
		setsid();
		signal(SIGCHLD, SIG_DFL);
		sigprocmask(SIG_SETMASK, default_mask, NULL);
		int devnull = open("/dev/null", O_RDONLY);
		if (devnull >= 0) dup2(devnull, STDIN_FILENO);
		dup2(conn, STDOUT_FILENO);
		dup2(conn, STDERR_FILENO);
		// The script closes this descriptor itself (see ORB_SCRIPT_FD), so
		// the processes it starts do not inherit the script text.
		char path[64], fd_env[16];
		snprintf(path, sizeof(path), "/proc/self/fd/%d", script);
		snprintf(fd_env, sizeof(fd_env), "%d", script);
		setenv("ORB_SCRIPT_FD", fd_env, 1);
		execl("/bin/bash", "bash", path, (char *)NULL);
		dprintf(STDERR_FILENO, "orb-agent: exec /bin/bash: %s\n", strerror(errno));
		_exit(127);
	}
	close(script);
	signal(SIGCHLD, SIG_DFL);
	signal(SIGPIPE, SIG_IGN);
	sigprocmask(SIG_SETMASK, default_mask, NULL);

	int status = 0;
	while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
	}
	int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
	dprintf(conn, "\n\x1eORB-EXIT %d\n", code);
	close(conn);
	_exit(0);
}

int main(void) {
	bring_up_loopback();

	// The kernel starts PID 1 with a 1024 file limit, which every process
	// in the orb would inherit. Match what a container runtime grants.
	struct rlimit files = {.rlim_cur = 65536, .rlim_max = 1048576};
	setrlimit(RLIMIT_NOFILE, &files);

	// SIGCHLD stays blocked except inside ppoll, so a child that exits
	// between reaping and waiting cannot be missed.
	struct sigaction sa = {.sa_handler = on_sigchld};
	sigaction(SIGCHLD, &sa, NULL);
	sigset_t blocked, default_mask;
	sigemptyset(&blocked);
	sigaddset(&blocked, SIGCHLD);
	sigprocmask(SIG_BLOCK, &blocked, &default_mask);

	int listener = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	struct sockaddr_vm addr = {
		.svm_family = AF_VSOCK,
		.svm_port = AGENT_PORT,
		.svm_cid = VMADDR_CID_ANY,
	};
	if (listener < 0 || bind(listener, (struct sockaddr *)&addr, sizeof(addr)) < 0 ||
	    listen(listener, 16) < 0) {
		// Exiting would panic the kernel. Keep reaping so the console log
		// shows this message and the orb stays inspectable.
		dprintf(STDERR_FILENO, "orb-agent: vsock listen on port %d: %s\n", AGENT_PORT, strerror(errno));
		listener = -1;
	}

	for (;;) {
		while (waitpid(-1, NULL, WNOHANG) > 0) {
		}
		struct pollfd pfd = {.fd = listener, .events = POLLIN};
		if (ppoll(&pfd, listener >= 0 ? 1 : 0, NULL, &default_mask) <= 0) continue;

		int conn = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
		if (conn < 0) continue;
		pid_t handler = fork();
		if (handler == 0) {
			close(listener);
			serve(conn, &default_mask);
		}
		close(conn);
	}
}
