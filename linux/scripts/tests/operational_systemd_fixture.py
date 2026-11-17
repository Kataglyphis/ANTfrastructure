#!/usr/bin/env python3
"""Return explicit fixture unit states without contacting or changing a real service manager."""

import json
import os
import sys
from pathlib import Path

name = Path(sys.argv[0]).name
if name == 'git' and os.environ.get('OPERATIONAL_GIT_REVISION'):
    if sys.argv[-1] == 'HEAD':
        print(os.environ['OPERATIONAL_GIT_REVISION'])
    else:
        assert 'status' in sys.argv, sys.argv
elif name == 'nerdctl' and os.environ.get('OPERATIONAL_PS_FIXTURE'):
    assert sys.argv[1:] == ['ps','-a','--format','{{json .}}'], sys.argv
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
