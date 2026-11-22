#!/usr/bin/env python3
"""Return explicit service and command fixtures without running real tools."""

import json
import os
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
if name in {'git', 'bash'} and os.environ.get('OPERATIONAL_SOURCE_TRACE'):
    trace = Path(os.environ['OPERATIONAL_SOURCE_TRACE'])
    calls = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
    row = {'program':name, 'args':sys.argv[1:]}
    with trace.open('a') as stream:
        stream.write(json.dumps(row) + '\n')
    mode = os.environ.get('OPERATIONAL_SOURCE_MODE', '')
    if name == 'bash':
        if Path(sys.argv[1]).name == os.environ.get('OPERATIONAL_FAIL_SCRIPT'):
            raise SystemExit(47)
    elif sys.argv[1:3] == ['diff', '--name-only']:
        if mode == 'git-failure':
            raise SystemExit(47)
        print('changed-source' if mode == 'dirty' else '', end='')
    elif row in calls and ((sys.argv[1] == 'diff' and mode == 'patch') or (sys.argv[1] == 'ls-files' and mode == 'index')):
        print('changed-source')
elif name == 'git' and os.environ.get('OPERATIONAL_GIT_REVISION'):
    if sys.argv[-1] == 'HEAD':
        print(os.environ['OPERATIONAL_GIT_REVISION'])
    else:
        assert 'status' in sys.argv, sys.argv
elif name == 'nerdctl' and os.environ.get('OPERATIONAL_PS_FIXTURE'):
    listing = sys.argv[1:] == ['ps','-a','--format','{{json .}}']
    filtered = len(sys.argv) == 7 and sys.argv[1:6] == ['ps','-a','-q','--no-trunc','--filter']
    assert listing or (filtered and sys.argv[6].startswith(('id=', 'label='))), sys.argv
    print(Path(os.environ['OPERATIONAL_PS_FIXTURE']).read_text())
elif name == 'nerdctl' and os.environ.get('OPERATIONAL_IMAGE_FIXTURE'):
    assert sys.argv[1:3] == ['image','inspect'], sys.argv
    assert sys.argv[-1] == os.environ['OPERATIONAL_EXPECTED_IMAGE'], sys.argv
    print(Path(os.environ['OPERATIONAL_IMAGE_FIXTURE']).read_text())
elif name == 'systemctl' and os.environ.get('OPERATIONAL_UNIT_FIXTURE'):
    units = json.loads(Path(os.environ['OPERATIONAL_UNIT_FIXTURE']).read_text())
    print('\n'.join(key + '=' + str(value) for key, value in units[sys.argv[3]].items()))
else:
    print('not-found')
