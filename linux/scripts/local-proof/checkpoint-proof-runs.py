#!/usr/bin/env python3
"""Persist observed producer states; this cannot create source, image or GPU acceptance."""

import argparse
import datetime
import json
import subprocess
from pathlib import Path

FIELDS = 'Id,LoadState,ActiveState,SubState,MainPID,Result,ExecMainStatus'
START = '<!-- operational-runs-current:start -->\n'
END = '<!-- operational-runs-current:end -->\n'


def read(path: Path) -> dict:
    return json.loads(path.read_text())


def observe(directory: Path) -> dict:
    invocation = read(directory.with_name(directory.name + '-invocation.json'))
    record = read(directory / 'run.json')
    assert invocation['revision'] == record['source_revision']
    assert invocation['run_id'] == record['owner_run_id']
    result = subprocess.run(['systemctl', '--user', 'show', invocation['unit'], '--property=' + FIELDS],
                            check=True, capture_output=True, text=True, timeout=30)
    state = dict(line.split('=', 1) for line in result.stdout.splitlines())
    assert state['Id'] == invocation['unit'] and state['LoadState'] in {'loaded', 'not-found'}
    return {'directory': str(directory), 'source': invocation['source'], 'revision': invocation['revision'],
            'full_registry': invocation['full_registry'], 'unit': state, 'driver_status': record['status']}


def update_markdown(path: Path, block: str) -> None:
    original = path.read_text()
    assert original.count(START) == original.count(END) <= 1
    if START in original:
        before, rest = original.split(START)
        _, after = rest.split(END)
        text = before + block + after
    else:
        text = block + original
    path.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preflight', required=True, action='append', type=Path)
    parser.add_argument('--state', required=True, type=Path)
    parser.add_argument('--markdown', action='append', default=[], type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    assert not args.output.exists()
    observations = [observe(path.resolve(strict=True)) for path in args.preflight]
    assert len({row['unit']['Id'] for row in observations}) == len(observations)
    live = [row['unit'] for row in observations if row['unit']['LoadState'] == 'loaded'
            and row['unit']['ActiveState'] in {'active', 'activating'} and int(row['unit']['MainPID']) > 0]
    now = datetime.datetime.now(datetime.UTC).isoformat()
    receipt = {'observed_at': now, 'scope': __doc__, 'observations': observations,
               'live_units': live, 'producer_changed': False, 'acceptance_claimed': False}
    state = read(args.state)
    state.update(updated_at=now, operational_runs=receipt, live_units=live,
                 current_running_units={'observed_at': now, 'units': live, 'outlive_turn': bool(live)})
    block = START + f'Observed {now}; these states are observations only. Earlier checkpoints below are historical.\n\n'
    for row in observations:
        block += f"- `{row['unit']['Id']}`: {row['unit']['ActiveState']}/{row['unit']['SubState']}, revision `{row['revision']}`, registry {row['full_registry']}; driver {row['driver_status']}.\n"
    block += END + '\n'
    for path in args.markdown:
        text = path.read_text()
        assert text.count(START) == text.count(END) <= 1
    args.output.write_text(json.dumps(receipt, indent=2) + '\n')
    args.state.write_text(json.dumps(state, indent=2) + '\n')
    for path in args.markdown:
        update_markdown(path, block)
    print(json.dumps({'observed_units': len(observations), 'live_units': len(live), 'producer_changed': False}))


if __name__ == '__main__':
    main()
