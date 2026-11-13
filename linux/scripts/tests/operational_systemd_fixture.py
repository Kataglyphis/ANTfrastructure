#!/usr/bin/env python3
"""Return explicit fixture unit states without contacting or changing a real service manager."""

import json
import os
import sys
from pathlib import Path

if Path(sys.argv[0]).name == 'systemctl' and os.environ.get('OPERATIONAL_UNIT_FIXTURE'):
    units = json.loads(Path(os.environ['OPERATIONAL_UNIT_FIXTURE']).read_text())
    print('\n'.join(key + '=' + str(value) for key, value in units[sys.argv[3]].items()))
else:
    print('not-found')
