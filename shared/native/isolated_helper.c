// Ordinary fork repairs libc locks before control-only supervision.
#define _GNU_SOURCE
#include "isolated_helper.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

struct helper_packet {
  uint32_t magic;
  uint32_t version;
  int32_t worker;
  int32_t status;
  int32_t exec_error;
  int32_t timed_out;
  int32_t supervisor_error;
};

_Static_assert(sizeof(struct helper_packet) == 28,
               "private worker packet layout");

static int make_pipe(int descriptors[2]) {
  if (pipe2(descriptors, O_CLOEXEC) != 0) {
    return errno;
  }
  for (int index = 0; index < 2; ++index) {
    if (descriptors[index] >= 3) {
      continue;
    }
    const int moved = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3);
    if (moved < 0) {
      const int error = errno;
      close(descriptors[0]);
      close(descriptors[1]);
      return error;
    }
    close(descriptors[index]);
    descriptors[index] = moved;
  }
  return 0;
}

static int close_except(int first, int second) {
  const unsigned int low = (unsigned int)(first < second ? first : second);
  const unsigned int high = (unsigned int)(first > second ? first : second);
  if (low > 3 && close_range(3, low - 1, 0) != 0) {
    return errno;
  }
  if (high > low + 1 && close_range(low + 1, high - 1, 0) != 0) {
    return errno;
  }
  if (close_range(high + 1, UINT_MAX, 0) != 0) {
    return errno;
  }
  return 0;
}

static int write_all(int descriptor, const void *data, size_t length) {
  const unsigned char *cursor = data;
  while (length > 0) {
    const ssize_t count = write(descriptor, cursor, length);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      return count < 0 ? errno : EIO;
    }
    cursor += (size_t)count;
    length -= (size_t)count;
  }
  return 0;
}

static int read_packet(int descriptor, struct helper_packet *packet) {
  unsigned char *cursor = (unsigned char *)packet;
  size_t length = sizeof(*packet);
  while (length > 0) {
    const ssize_t count = read(descriptor, cursor, length);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count <= 0) {
      return count < 0 ? errno : EPROTO;
    }
    cursor += (size_t)count;
    length -= (size_t)count;
  }
  unsigned char trailing;
  ssize_t count;
  do {
    count = read(descriptor, &trailing, 1);
  } while (count < 0 && errno == EINTR);
  if (count != 0) {
    return count < 0 ? errno : EPROTO;
  }
  return packet->magic == 0x414e5448 && packet->version == 1 ? 0 : EPROTO;
}

static int parent_guard(pid_t parent) {
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0) {
    return errno;
  }
  return getppid() == parent ? 0 : ECHILD;
}

static int reset_worker_signals(void) {
  struct sigaction action = {0};
  action.sa_handler = SIG_DFL;
  if (sigemptyset(&action.sa_mask) != 0) {
    return errno;
  }
  for (int signal = 1; signal < NSIG; ++signal) {
    if (signal == SIGKILL || signal == SIGSTOP) {
      continue;
    }
    if (sigaction(signal, &action, NULL) != 0 && errno != EINVAL) {
      return errno;
    }
  }
  sigset_t empty;
  if (sigemptyset(&empty) != 0 || sigprocmask(SIG_SETMASK, &empty, NULL) != 0) {
    return errno;
  }
  return 0;
}

static void execute_worker(const char *path, char *const arguments[],
                           int error_fd, pid_t parent) {
  int error = parent_guard(parent);
  if (error == 0 && close_range(3, UINT_MAX, CLOSE_RANGE_CLOEXEC) != 0) {
    error = errno;
  }
  if (error == 0) {
    error = reset_worker_signals();
  }
  if (error == 0) {
    execve(path, arguments, environ);
    error = errno;
  }
  write_all(error_fd, &error, sizeof(error));
  _exit(127);
}

static int reap_worker(pid_t worker, int *status) {
  pid_t result;
  do {
    result = waitpid(worker, status, 0);
  } while (result < 0 && errno == EINTR);
  return result == worker ? 0 : errno;
}

static int elapsed_ms(const struct timespec *started, int64_t *elapsed) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return errno;
  }
  *elapsed = (int64_t)(now.tv_sec - started->tv_sec) * 1000 +
             (now.tv_nsec - started->tv_nsec) / 1000000;
  return 0;
}

static int supervise_worker(pid_t worker, int control_fd, uint32_t timeout_ms,
                            struct helper_packet *packet,
                            const struct timespec *started) {
  for (;;) {
    const pid_t found = waitpid(worker, &packet->status, WNOHANG);
    if (found == worker) {
      return 0;
    }
    if (found < 0 && errno == EINTR) {
      continue;
    }
    if (found < 0) {
      return errno;
    }
    int64_t elapsed;
    int error = elapsed_ms(started, &elapsed);
    struct pollfd control = {.fd = control_fd, .events = POLLIN | POLLHUP};
    int cancelled = 0;
    if (error == 0) {
      const int ready = poll(&control, 1, 5);
      if (ready < 0 && errno == EINTR) {
        continue;
      }
      if (ready < 0) {
        error = errno;
      }
      cancelled = ready > 0;
    }
    if (error == 0 && !cancelled && elapsed < timeout_ms) {
      continue;
    }
    packet->timed_out = error == 0 && !cancelled;
    if (kill(worker, SIGKILL) != 0 && errno != ESRCH && error == 0) {
      error = errno;
    }
    const int waited = reap_worker(worker, &packet->status);
    if (error != 0) {
      return error;
    }
    return waited != 0 ? waited : (cancelled ? ECANCELED : 0);
  }
}

static int worker_exec_error(int descriptor, int *error) {
  unsigned char *cursor = (unsigned char *)error;
  size_t length = sizeof(*error);
  while (length > 0) {
    const ssize_t count = read(descriptor, cursor, length);
    if (count < 0 && errno == EINTR) {
      continue;
    }
    if (count < 0) {
      return errno;
    }
    if (count == 0) {
      return length == sizeof(*error) ? 0 : EPROTO;
    }
    cursor += (size_t)count;
    length -= (size_t)count;
  }
  return 0;
}

static void supervise(const char *path, char *const arguments[],
                      uint32_t timeout_ms, int control_fd, int result_fd,
                      pid_t parent) {
  struct helper_packet packet = {.magic = 0x414e5448, .version = 1};
  int error = parent_guard(parent);
  if (error == 0) {
    error = close_except(control_fd, result_fd);
  }
  struct sigaction action = {0};
  action.sa_handler = SIG_DFL;
  if (error == 0 && sigaction(SIGCHLD, &action, NULL) != 0) {
    error = errno;
  }
  struct timespec started;
  if (error == 0 && clock_gettime(CLOCK_MONOTONIC, &started) != 0) {
    error = errno;
  }
  int execution[2] = {-1, -1};
  if (error == 0) {
    error = make_pipe(execution);
  }
  if (error == 0) {
    const pid_t owner = getpid();
    const pid_t worker = _Fork();
    if (worker == 0) {
      execute_worker(path, arguments, execution[1], owner);
    }
    if (worker < 0) {
      error = errno;
    }
    close(execution[1]);
    if (worker > 0) {
      packet.worker = worker;
      error =
          supervise_worker(worker, control_fd, timeout_ms, &packet, &started);
      const int transport = worker_exec_error(execution[0], &packet.exec_error);
      if (error == 0) {
        error = transport;
      }
    }
    close(execution[0]);
  }
  packet.supervisor_error = error;
  write_all(result_fd, &packet, sizeof(packet));
  // The control-only child must not run inherited application callbacks.
  _exit(error == 0 ? 0 : 125);
}

static int join_supervisor(pid_t supervisor, int *externally_reaped) {
  int status;
  pid_t result;
  do {
    result = waitpid(supervisor, &status, 0);
  } while (result < 0 && errno == EINTR);
  if (result < 0) {
    *externally_reaped = errno == ECHILD;
    return errno == ECHILD ? 0 : errno;
  }
  return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : EPROTO;
}

int ant_run_isolated_helper(const char *path, char *const arguments[],
                            uint32_t timeout_ms,
                            struct ant_helper_outcome *outcome) {
  if (path == NULL || arguments == NULL || outcome == NULL || path[0] != '/' ||
      timeout_ms == 0) {
    return EINVAL;
  }
  int results[2];
  int control[2];
  int error = make_pipe(results);
  if (error != 0) {
    return error;
  }
  error = make_pipe(control);
  if (error != 0) {
    close(results[0]);
    close(results[1]);
    return error;
  }
  sigset_t blocked;
  sigset_t previous;
  sigfillset(&blocked);
  error = pthread_sigmask(SIG_SETMASK, &blocked, &previous);
  pid_t supervisor = -1;
  if (error == 0) {
    const pid_t owner = getpid();
    supervisor = fork();
    if (supervisor == 0) {
      supervise(path, arguments, timeout_ms, control[0], results[1], owner);
    }
    const int fork_error = supervisor < 0 ? errno : 0;
    error = pthread_sigmask(SIG_SETMASK, &previous, NULL);
    if (error == 0) {
      error = fork_error;
    }
  }
  close(results[1]);
  close(control[0]);
  struct helper_packet packet;
  if (error == 0) {
    error = read_packet(results[0], &packet);
  }
  if (error == 0) {
    error = packet.supervisor_error;
  }
  if (error == 0) {
    error = packet.exec_error;
  }
  close(control[1]);
  close(results[0]);
  int externally_reaped = 0;
  if (supervisor > 0) {
    const int joined = join_supervisor(supervisor, &externally_reaped);
    if (error == 0) {
      error = joined;
    }
  }
  if (error != 0) {
    return error;
  }
  if (packet.worker <= 0 || (packet.timed_out != 0 && packet.timed_out != 1)) {
    return EPROTO;
  }
  outcome->worker = packet.worker;
  outcome->status = packet.status;
  outcome->timed_out = packet.timed_out;
  outcome->externally_reaped = externally_reaped;
  return 0;
}
