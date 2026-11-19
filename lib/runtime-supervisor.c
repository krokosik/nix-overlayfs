#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sched.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef FUSERMOUNT3_PATH
#error "FUSERMOUNT3_PATH must be defined"
#endif
#ifndef MOUNTPOINT_PATH
#error "MOUNTPOINT_PATH must be defined"
#endif
#ifndef UMOUNT_PATH
#error "UMOUNT_PATH must be defined"
#endif

enum { supervisor_failure = 125 };

struct options {
    double term_timeout_seconds;
    const char *mountpoint;
    const char *label;
    int state_lock_fd;
    bool pid_namespace;
    char **command;
};

struct pid_list {
    pid_t *items;
    size_t count;
    size_t capacity;
};

static sigset_t original_signal_mask;

static void usage(FILE *stream, const char *program)
{
    fprintf(stream,
            "usage: %s --term-timeout DURATION [--mountpoint PATH] "
            "[--label LABEL] [--state-lock-fd FD] [--pid-namespace] -- COMMAND [ARG ...]\n",
            program);
}

static bool parse_duration(const char *value, double *seconds)
{
    char *end = NULL;
    double multiplier = 1.0;

    errno = 0;
    double parsed = strtod(value, &end);
    if (errno || end == value || !isfinite(parsed) || parsed < 0.0) return false;

    if (!strcmp(end, "") || !strcmp(end, "s")) multiplier = 1.0;
    else if (!strcmp(end, "ms")) multiplier = 0.001;
    else if (!strcmp(end, "m")) multiplier = 60.0;
    else if (!strcmp(end, "h")) multiplier = 3600.0;
    else if (!strcmp(end, "d")) multiplier = 86400.0;
    else return false;

    parsed *= multiplier;
    if (parsed > (double)INT_MAX) return false;
    *seconds = parsed;
    return true;
}

static bool parse_options(int argc, char **argv, struct options *options)
{
    options->term_timeout_seconds = -1.0;
    options->mountpoint = NULL;
    options->label = "runtime session";
    options->state_lock_fd = -1;
    options->pid_namespace = false;
    options->command = NULL;

    for (int index = 1; index < argc; index++) {
        if (!strcmp(argv[index], "--")) {
            if (++index >= argc) return false;
            options->command = &argv[index];
            break;
        }
        if (!strcmp(argv[index], "--term-timeout") && index + 1 < argc) {
            if (!parse_duration(argv[++index], &options->term_timeout_seconds)) return false;
            continue;
        }
        if (!strcmp(argv[index], "--mountpoint") && index + 1 < argc) {
            options->mountpoint = argv[++index];
            continue;
        }
        if (!strcmp(argv[index], "--label") && index + 1 < argc) {
            options->label = argv[++index];
            continue;
        }
        if (!strcmp(argv[index], "--state-lock-fd") && index + 1 < argc) {
            char *end = NULL;
            errno = 0;
            long fd = strtol(argv[++index], &end, 10);
            if (errno || end == argv[index] || *end || fd < 0 || fd > INT_MAX) return false;
            options->state_lock_fd = (int)fd;
            continue;
        }
        if (!strcmp(argv[index], "--pid-namespace")) {
            options->pid_namespace = true;
            continue;
        }
        return false;
    }

    return options->term_timeout_seconds >= 0.0 && options->command;
}

static double monotonic_seconds(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) {
        perror("clock_gettime");
        exit(supervisor_failure);
    }
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static int remaining_milliseconds(double deadline, int maximum)
{
    double remaining = deadline - monotonic_seconds();
    if (remaining <= 0.0) return 0;
    if (remaining * 1000.0 < (double)maximum) return (int)(remaining * 1000.0 + 0.5);
    return maximum;
}

static bool pid_list_contains(const struct pid_list *list, pid_t pid)
{
    for (size_t index = 0; index < list->count; index++) {
        if (list->items[index] == pid) return true;
    }
    return false;
}

static void pid_list_add(struct pid_list *list, pid_t pid)
{
    if (pid_list_contains(list, pid)) return;
    if (list->count == list->capacity) {
        size_t next_capacity = list->capacity ? list->capacity * 2 : 16;
        pid_t *next_items = realloc(list->items, next_capacity * sizeof(*next_items));
        if (!next_items) {
            perror("realloc");
            exit(supervisor_failure);
        }
        list->items = next_items;
        list->capacity = next_capacity;
    }
    list->items[list->count++] = pid;
}

static FILE *open_children_file(void)
{
    char path[128];
    int length = snprintf(path, sizeof(path), "/proc/self/task/%ld/children", (long)getpid());
    if (length < 0 || (size_t)length >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return NULL;
    }
    return fopen(path, "re");
}

static bool read_children(struct pid_list *children)
{
    FILE *stream = open_children_file();
    long value;

    children->count = 0;
    if (!stream) return false;
    while (fscanf(stream, "%ld", &value) == 1) {
        if (value > 0 && value <= INT_MAX) pid_list_add(children, (pid_t)value);
    }
    bool ok = !ferror(stream);
    if (fclose(stream) < 0) ok = false;
    return ok;
}

static bool child_has_exited(pid_t pid)
{
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) == 0) {
        return info.si_pid != 0;
    }
    return errno == ECHILD;
}

static void reap_available_children(pid_t primary_pid, bool *primary_exited, int *primary_status)
{
    int status;
    pid_t pid;

    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        if (pid == primary_pid) {
            *primary_exited = true;
            *primary_status = status;
        }
    }
    if (pid < 0 && errno != ECHILD) {
        perror("waitpid");
        exit(supervisor_failure);
    }
}

static int decoded_wait_status(int status)
{
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return supervisor_failure;
}

static void forward_signal(pid_t primary_pid, bool primary_exited, int signal_number)
{
    if (!primary_exited && kill(primary_pid, signal_number) < 0 && errno != ESRCH) {
        fprintf(stderr, "warning: nix-overlayfs: could not forward signal %d: %s\n",
                signal_number, strerror(errno));
    }
}

static void handle_signal_events(int signal_fd, pid_t primary_pid, bool *primary_exited,
                                 int *primary_status, bool *force_kill)
{
    struct signalfd_siginfo event;

    for (;;) {
        ssize_t length = read(signal_fd, &event, sizeof(event));
        if (length == (ssize_t)sizeof(event)) {
            if (event.ssi_signo == SIGCHLD) {
                reap_available_children(primary_pid, primary_exited, primary_status);
            } else {
                if (*primary_exited) *force_kill = true;
                forward_signal(primary_pid, *primary_exited, (int)event.ssi_signo);
            }
            continue;
        }
        if (length < 0 && (errno == EAGAIN || errno == EINTR)) break;
        if (length < 0) perror("read signalfd");
        break;
    }
}

static void handle_drain_signal_events(int signal_fd, bool *force_kill)
{
    struct signalfd_siginfo event;

    for (;;) {
        ssize_t length = read(signal_fd, &event, sizeof(event));
        if (length == (ssize_t)sizeof(event)) {
            if (event.ssi_signo != SIGCHLD) *force_kill = true;
            continue;
        }
        if (length < 0 && (errno == EAGAIN || errno == EINTR)) return;
        if (length < 0) perror("read signalfd");
        return;
    }
}

static bool wait_for_primary(int signal_fd, pid_t primary_pid, int *primary_status)
{
    struct pollfd descriptor = { .fd = signal_fd, .events = POLLIN };
    bool primary_exited = false;
    bool force_kill = false;

    while (!primary_exited) {
        reap_available_children(primary_pid, &primary_exited, primary_status);
        if (primary_exited) break;
        int result = poll(&descriptor, 1, -1);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) {
            perror("poll");
            exit(supervisor_failure);
        }
        handle_signal_events(signal_fd, primary_pid, &primary_exited, primary_status, &force_kill);
    }
    return force_kill;
}

static bool signal_descendants(const struct pid_list *children, struct pid_list *term_signaled,
                               int signal_number)
{
    bool live_child = false;

    for (size_t index = 0; index < children->count; index++) {
        pid_t pid = children->items[index];
        if (child_has_exited(pid)) continue;
        live_child = true;
        if (signal_number == SIGTERM && pid_list_contains(term_signaled, pid)) continue;
        if (kill(pid, signal_number) < 0 && errno != ESRCH) {
            fprintf(stderr, "warning: nix-overlayfs: could not signal descendant %ld: %s\n",
                    (long)pid, strerror(errno));
        }
        if (signal_number == SIGTERM) pid_list_add(term_signaled, pid);
    }
    return live_child;
}

static void reap_all_available(void)
{
    int status;
    errno = 0;
    while (waitpid(-1, &status, WNOHANG) > 0) {}
    if (errno != 0 && errno != ECHILD && errno != EINTR) {
        perror("waitpid");
        exit(supervisor_failure);
    }
}

static bool drain_descendants(int signal_fd, double timeout_seconds, const char *label,
                              bool force_kill)
{
    struct pid_list children = {0};
    struct pid_list term_signaled = {0};
    struct pollfd descriptor = { .fd = signal_fd, .events = POLLIN };
    double deadline = monotonic_seconds() + timeout_seconds;
    bool reported = false;

    for (;;) {
        if (!read_children(&children)) {
            fprintf(stderr, "error: nix-overlayfs: cannot enumerate supervised descendants: %s\n",
                    strerror(errno));
            free(children.items);
            free(term_signaled.items);
            return false;
        }

        int signal_number = force_kill || monotonic_seconds() >= deadline ? SIGKILL : SIGTERM;
        bool live_child = signal_descendants(&children, &term_signaled, signal_number);
        if (live_child && !reported) {
            fprintf(stderr, "warning: nix-overlayfs: terminating remaining processes for %s\n", label);
            reported = true;
        }

        if (!live_child) {
            reap_all_available();
            term_signaled.count = 0;
            if (!read_children(&children)) {
                fprintf(stderr, "error: nix-overlayfs: cannot verify supervised descendants: %s\n",
                        strerror(errno));
                free(children.items);
                free(term_signaled.items);
                return false;
            }
            if (children.count == 0) break;
            continue;
        }

        int wait_ms = signal_number == SIGKILL ? 50 : remaining_milliseconds(deadline, 50);
        int result = poll(&descriptor, 1, wait_ms);
        if (result < 0 && errno != EINTR) {
            perror("poll");
            free(children.items);
            free(term_signaled.items);
            return false;
        }
        handle_drain_signal_events(signal_fd, &force_kill);
    }

    free(children.items);
    free(term_signaled.items);
    return true;
}

static int run_cleanup_command(char *const argv[])
{
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        sigprocmask(SIG_SETMASK, &original_signal_mask, NULL);
        execv(argv[0], argv);
        _exit(127);
    }

    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) continue;
        return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static int mountpoint_state(const char *mountpoint)
{
    char *const argv[] = { MOUNTPOINT_PATH, "-q", (char *)mountpoint, NULL };
    int status = run_cleanup_command(argv);
    if (status == 0) return 1;
    if (status == 32) return 0;
    fprintf(stderr, "warning: nix-overlayfs: cannot inspect mountpoint %s\n", mountpoint);
    return -1;
}

static bool unmount_attempt_succeeded(char *const argv[], const char *mountpoint)
{
    if (run_cleanup_command(argv) == 0) return true;
    return mountpoint_state(mountpoint) == 0;
}

static bool unmount_runtime(const char *mountpoint)
{
    if (!mountpoint) return true;
    int state = mountpoint_state(mountpoint);
    if (state <= 0) return state == 0;

    char *const normal[] = { FUSERMOUNT3_PATH, "-u", (char *)mountpoint, NULL };
    char *const lazy_fuse[] = { FUSERMOUNT3_PATH, "-uz", (char *)mountpoint, NULL };
    char *const lazy_umount[] = { UMOUNT_PATH, "-l", (char *)mountpoint, NULL };

    if (unmount_attempt_succeeded(normal, mountpoint)) return true;
    if (unmount_attempt_succeeded(lazy_fuse, mountpoint)) return true;
    if (unmount_attempt_succeeded(lazy_umount, mountpoint)) return true;
    return false;
}

/* Runs the session's command and waits for it, then ends what is left of the
   session (every descendant of this process) and unmounts MOUNTPOINT. */
static int supervise(const struct options *options, int signal_fd, const char *mountpoint)
{
    pid_t primary_pid = fork();
    if (primary_pid < 0) {
        perror("fork");
        return supervisor_failure;
    }
    if (primary_pid == 0) {
        sigprocmask(SIG_SETMASK, &original_signal_mask, NULL);
        execvp(options->command[0], options->command);
        fprintf(stderr, "error: nix-overlayfs: cannot execute %s: %s\n",
                options->command[0], strerror(errno));
        _exit(errno == ENOENT ? 127 : 126);
    }

    int primary_status = 0;
    bool force_kill = wait_for_primary(signal_fd, primary_pid, &primary_status);
    bool drained = drain_descendants(signal_fd, options->term_timeout_seconds, options->label,
                                     force_kill);
    bool unmounted = unmount_runtime(mountpoint);

    int result = decoded_wait_status(primary_status);
    if (!drained || !unmounted) {
        if (!unmounted) {
            fprintf(stderr, "error: nix-overlayfs: failed to unmount runtime at %s\n",
                    mountpoint);
        }
        if (result == 0) result = supervisor_failure;
    }
    return result;
}

static const char session_pid_variable[] = "NIX_OVERLAYFS_SESSION_PID";

/* In the new PID namespace, as its init: a mount namespace of its own with a
   /proc that shows the namespace's processes (Wine and the supervision below
   read /proc with the process ids they know). NIX_OVERLAYFS_SESSION_PID is
   set to this process's id outside the namespace, read before the new /proc
   hides it: the launcher records it, so other launchers can find the session
   from outside. */
static bool enter_pid_namespace(void)
{
    char self[64];
    ssize_t length = readlink("/proc/self", self, sizeof(self) - 1);
    if (length <= 0) {
        fprintf(stderr, "warning: nix-overlayfs: cannot read /proc/self: %s\n", strerror(errno));
        return false;
    }
    self[length] = '\0';

    if (unshare(CLONE_NEWNS) < 0
        || mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0
        || mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) < 0) {
        fprintf(stderr, "warning: nix-overlayfs: cannot mount /proc for a PID namespace: %s\n",
                strerror(errno));
        return false;
    }
    if (setenv(session_pid_variable, self, 1) < 0) return false;
    return true;
}

/* Runs the session as init of a new PID namespace. When that init exits, or
   is killed together with this process (it gets SIGKILL when this process
   dies), the kernel kills every process left in the namespace, so nothing of
   the session can outlive it, whatever it does to escape its parent.
   Returns false, before anything ran, when the namespace cannot be set up;
   the caller then supervises the session itself. */
static bool run_in_pid_namespace(const struct options *options, int signal_fd, int *result)
{
    int ready[2];
    if (pipe2(ready, O_CLOEXEC) < 0) {
        perror("pipe2");
        return false;
    }

    /* Like fork(), but the child is the first process of a new namespace. */
    pid_t init_pid = (pid_t)syscall(SYS_clone, CLONE_NEWPID | SIGCHLD, 0, 0, 0, 0);
    if (init_pid < 0) {
        fprintf(stderr, "warning: nix-overlayfs: cannot create a PID namespace: %s; "
                "supervising the session without one\n", strerror(errno));
        close(ready[0]);
        close(ready[1]);
        return false;
    }

    if (init_pid == 0) {
        close(ready[0]);
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || !enter_pid_namespace()) _exit(supervisor_failure);
        char byte = 1;
        if (write(ready[1], &byte, 1) != 1) _exit(supervisor_failure);
        close(ready[1]);
        /* The mount was made in the namespace's own mount namespace, which
           ends with it; the outer supervisor unmounts as well. */
        _exit(supervise(options, signal_fd, NULL));
    }

    close(ready[1]);
    char byte;
    ssize_t length;
    do {
        length = read(ready[0], &byte, 1);
    } while (length < 0 && errno == EINTR);
    close(ready[0]);

    int status = 0;
    if (length != 1) {
        while (waitpid(init_pid, &status, 0) < 0 && errno == EINTR) {}
        fprintf(stderr, "warning: nix-overlayfs: supervising the session without a PID namespace\n");
        return false;
    }

    /* Signals for the session go to its init, which passes them on. */
    wait_for_primary(signal_fd, init_pid, &status);
    reap_all_available();
    bool unmounted = unmount_runtime(options->mountpoint);
    *result = decoded_wait_status(status);
    if (!unmounted) {
        fprintf(stderr, "error: nix-overlayfs: failed to unmount runtime at %s\n",
                options->mountpoint);
        if (*result == 0) *result = supervisor_failure;
    }
    return true;
}

int main(int argc, char **argv)
{
    struct options options;
    sigset_t blocked_signals;

    if (!parse_options(argc, argv, &options)) {
        usage(stderr, argv[0]);
        return 2;
    }

    /* The launcher's lock on the writable layer: held for as long as this
       process lives, but not passed on to the session's processes. */
    if (options.state_lock_fd >= 0) {
        int flags = fcntl(options.state_lock_fd, F_GETFD);
        if (flags < 0 || fcntl(options.state_lock_fd, F_SETFD, flags | FD_CLOEXEC) < 0) {
            fprintf(stderr, "error: nix-overlayfs: invalid state lock descriptor %d: %s\n",
                    options.state_lock_fd, strerror(errno));
            return supervisor_failure;
        }
    }

    FILE *children_file = open_children_file();
    if (!children_file) {
        fprintf(stderr, "error: nix-overlayfs: Linux procfs child tracking is unavailable: %s\n",
                strerror(errno));
        return supervisor_failure;
    }
    fclose(children_file);

    pid_t original_parent = getppid();
    if (prctl(PR_SET_CHILD_SUBREAPER, 1) < 0 || prctl(PR_SET_PDEATHSIG, SIGTERM) < 0) {
        fprintf(stderr, "error: nix-overlayfs: cannot establish process supervision: %s\n",
                strerror(errno));
        return supervisor_failure;
    }

    sigemptyset(&blocked_signals);
    sigaddset(&blocked_signals, SIGCHLD);
    sigaddset(&blocked_signals, SIGHUP);
    sigaddset(&blocked_signals, SIGINT);
    sigaddset(&blocked_signals, SIGQUIT);
    sigaddset(&blocked_signals, SIGTERM);
    if (sigprocmask(SIG_BLOCK, &blocked_signals, &original_signal_mask) < 0) {
        perror("sigprocmask");
        return supervisor_failure;
    }
    if (getppid() != original_parent) raise(SIGTERM);

    int signal_fd = signalfd(-1, &blocked_signals, SFD_CLOEXEC | SFD_NONBLOCK);
    if (signal_fd < 0) {
        perror("signalfd");
        return supervisor_failure;
    }

    if (options.pid_namespace) {
        int result;
        if (run_in_pid_namespace(&options, signal_fd, &result)) {
            close(signal_fd);
            return result;
        }
    }

    unsetenv(session_pid_variable);
    int result = supervise(&options, signal_fd, options.mountpoint);
    close(signal_fd);
    return result;
}
