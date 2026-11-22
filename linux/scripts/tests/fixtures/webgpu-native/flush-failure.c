// SPDX-License-Identifier: MIT
// An actual failed flush must retain a failed probe status even after its success text was buffered.
#include <stdio.h>
int fflush(FILE *stream) { (void)stream; return EOF; }
