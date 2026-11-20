#!/usr/bin/env python3
"""Supply archive/status doubles while retaining real tar extraction; no container engine or image is exercised."""

import os
import shutil
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
if name == 'nerdctl':
    assert sys.argv[1:] == ['save','fixture/sdk'], sys.argv
    with Path(os.environ['OCI_FIXTURE_ARCHIVE']).open('rb') as stream:
        shutil.copyfileobj(stream,sys.stdout.buffer)
    raise SystemExit(int(os.environ.get('OCI_FIXTURE_PRODUCER_STATUS','0')))
assert name == 'tar', name
if os.environ.get('OCI_FIXTURE_EXTRACTOR_STATUS'):
    with open(os.devnull,'wb') as sink:
        shutil.copyfileobj(sys.stdin.buffer,sink)
    raise SystemExit(int(os.environ['OCI_FIXTURE_EXTRACTOR_STATUS']))
os.execv(os.environ['OCI_REAL_TAR'],[os.environ['OCI_REAL_TAR'],*sys.argv[1:]])
