// Real child supervision with injected clock failures proves neither HIP nor packaged helper delivery.
#define _GNU_SOURCE
#include "../isolated_helper.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct clock_observation {
  unsigned int calls;
  pid_t worker;
  int reaped;
};

static volatile struct clock_observation *observation;
static unsigned int fail_call;
static int fail_errno;

int __real_clock_gettime(clockid_t clock_id, struct timespec *value);
pid_t __real_waitpid(pid_t child, int *status, int options);

int __wrap_clock_gettime(clockid_t clock_id, struct timespec *value) {
  if (clock_id == CLOCK_MONOTONIC && ++observation->calls == fail_call) {
    errno = fail_errno;
    return -1;
  }
  return __real_clock_gettime(clock_id, value);
}

pid_t __wrap_waitpid(pid_t child, int *status, int options) {
  const pid_t result = __real_waitpid(child, status, options);
  if (options == WNOHANG) {
    observation->worker = child;
  }
  if (child == observation->worker && result == child) {
    observation->reaped = 1;
  }
  return result;
}

static int child_gone(pid_t child) {
  errno = 0;
  return kill(child, 0) == -1 && errno == ESRCH;
}

static int no_children(void) {
  int status;
  errno = 0;
  return __real_waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD;
}

static int error_case(unsigned int call, int injected_errno, int expected) {
  *observation = (struct clock_observation){0};
  fail_call = call;
  fail_errno = injected_errno;
  char *arguments[] = {"sleep", "10", NULL};
  struct ant_helper_outcome outcome = {.worker = -77};
  const int actual = ant_run_isolated_helper("/bin/sleep", arguments, 50, &outcome);
  const int lifecycle = call == 1
                            ? observation->worker == 0
                            : observation->worker > 0 && observation->reaped &&
                                  child_gone(observation->worker);
  if (actual != expected || observation->calls != call || !lifecycle ||
      outcome.worker != -77 || !no_children()) {
    fprintf(stderr, "clock error call=%u errno=%d: actual=%d expected=%d calls=%u "
                    "worker=%d reaped=%d lifecycle=%d\n",
            call, injected_errno, actual, expected, observation->calls,
            observation->worker, observation->reaped, lifecycle);
    return 1;
  }
  printf("clock error call=%u errno=%d preserved=%d cleanup=passed\n", call,
         injected_errno, expected);
  return 0;
}

static int timeout_case(void) {
  *observation = (struct clock_observation){0};
  fail_call = 0;
  char *arguments[] = {"sleep", "10", NULL};
  struct ant_helper_outcome outcome = {0};
  const int actual = ant_run_isolated_helper("/bin/sleep", arguments, 25, &outcome);
  if (actual != 0 || !outcome.timed_out || !WIFSIGNALED(outcome.status) ||
      WTERMSIG(outcome.status) != SIGKILL || outcome.worker <= 0 ||
      !observation->reaped || !child_gone(outcome.worker) || !no_children()) {
    fprintf(stderr, "clock timeout: actual=%d timeout=%d status=%d worker=%d\n",
            actual, outcome.timed_out, outcome.status, outcome.worker);
    return 1;
  }
  puts("clock timeout killed-and-reaped=passed");
  return 0;
}

int main(void) {
  observation = mmap(NULL, sizeof(*observation), PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (observation == MAP_FAILED) {
    perror("clock fixture mmap");
    return 1;
  }
  int failures = 0;
  failures += error_case(1, 0, EIO);
  failures += error_case(1, EACCES, EACCES);
  failures += error_case(2, 0, EIO);
  failures += error_case(2, ERANGE, ERANGE);
  failures += timeout_case();
  if (munmap((void *)observation, sizeof(*observation)) != 0) {
    perror("clock fixture munmap");
    return 1;
  }
  return failures == 0 ? 0 : 1;
}
