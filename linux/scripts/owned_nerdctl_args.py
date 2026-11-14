"""Keep invocation ownership on reviewed container creation forms; no command success, image or inference proof."""

from pathlib import Path

from owned_containers import OwnedContainers


def label_assignment(arguments: list[str], index: int) -> str:
    value = arguments[index]
    for prefix in ('--label=', '-l='):
        if value.startswith(prefix):
            return value.removeprefix(prefix)
    if value.startswith('-l') and value != '-l':
        return value[2:]
    if value in {'--label', '-l'} and index + 1 < len(arguments):
        return arguments[index + 1]
    return ''


def owned_engine_command(arguments: list[str], engine: str, label: str, run_id: str) -> list[str]:
    OwnedContainers(engine, label, run_id)
    assert Path(engine).is_absolute(), 'Runtime engine must be an absolute executable path'
    assert arguments, 'Pass one explicit nerdctl command'
    assert not arguments[0].startswith('-') or arguments in [['--help'], ['-h'], ['--version'], ['-v']], 'Unreviewed global nerdctl options'
    position = 2 if arguments[:2] in [['container', 'run'], ['container', 'create']] else 1
    container = arguments[:1] in [['run'], ['create']] or position == 2
    if container:
        assert not any(value == '--label-file' or value.startswith('--label-file=') for value in arguments[position:]), 'Label files cannot override runtime ownership'
        for index in range(position, len(arguments)):
            assigned = label_assignment(arguments, index)
            assert not assigned.startswith(label + '='), 'Caller cannot override runtime ownership'
        arguments = [*arguments[:position], '--label', label + '=' + run_id, *arguments[position:]]
    return [engine, *arguments]
