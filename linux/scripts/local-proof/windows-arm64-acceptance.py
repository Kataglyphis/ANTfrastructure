#!/usr/bin/env python3
"""Upload, accept and promote the Windows ARM64 bundle image by exact digest; see docs/windows-cross-builds.md § Accept an ARM64 image before moving its tag."""

import argparse
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import urllib.request
import uuid
import zipfile
from pathlib import Path
from types import ModuleType
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
GITHUB_REPOSITORY = 'Kataglyphis/ANTfrastructure'
REPOSITORY = 'kataglyphis/kataglyphis_beschleuniger'
IMAGE = 'ghcr.io/' + REPOSITORY
TAG = 'winarm64'
WORKFLOW = '.github/workflows/windows-arm64.yml'
DIGEST = re.compile(r'sha256:[0-9a-f]{64}')
COMMIT = re.compile(r'[0-9a-f]{40}')
# Conservative: any change under these prefixes can alter a Windows image, so the build must be redone.
CLOSURE_PREFIXES = ('windows/', 'linux/scripts/01-core/', 'linux/scripts/02-toolchain/python/',
                    'linux/scripts/03-media/', 'shared/upstream/', 'cmake/', '.dockerignore')


def transport() -> ModuleType:
    spec = importlib.util.spec_from_file_location('windows_arm64_registry', ROOT / 'linux/scripts/image-acceptance.py')
    if spec is None or spec.loader is None:
        raise ValueError('image-acceptance.py is missing')
    module: Any = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    # Windows final tags are single manifests, while the shared client asks for indexes by default.
    module.MEDIA += ',' + ','.join(sorted(module.MANIFEST_MEDIA))
    return module


def check_reference(reference: str) -> str:
    if reference != TAG and not DIGEST.fullmatch(reference):
        raise ValueError(f'only :{TAG} or an exact sha256 candidate digest is supported')
    return reference


def read(reference: str, registry: Any) -> tuple[dict[str, Any], bytes, str]:
    raw, media_type, digest = registry.manifest(check_reference(reference))
    config_digest = json.loads(raw)['config']['digest']
    request = urllib.request.Request(f'https://ghcr.io/v2/{REPOSITORY}/blobs/{config_digest}',
                                     headers={'Authorization': 'Bearer ' + registry.token})
    with urllib.request.urlopen(request, timeout=60) as response:
        config_raw = response.read()
    if 'sha256:' + hashlib.sha256(config_raw).hexdigest() != config_digest:
        raise ValueError('registry config bytes differ from their digest')
    config = json.loads(config_raw)
    return ({'Reference': reference, 'ManifestDigest': digest, 'ConfigDigest': config_digest, 'MediaType': media_type,
             'Os': config['os'], 'Architecture': config['architecture'], 'OsVersion': config.get('os.version'),
             'Variant': config.get('variant'),
             'ImageRevision': config['config']['Labels']['org.opencontainers.image.revision']}, raw, media_type)


def git(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.run(['git', '-C', str(cwd), *args], capture_output=True, text=True, check=True, timeout=120).stdout


def closure_changes(image_source: str, later: str, cwd: Path = ROOT) -> list[str]:
    """Return the changed paths that bind the image to its own source; empty when a later commit reuses it."""
    for commit in (image_source, later):
        if not COMMIT.fullmatch(commit):
            raise ValueError(f'expected a full commit, got {commit!r}')
    if subprocess.run(['git', '-C', str(cwd), 'merge-base', '--is-ancestor', image_source, later],
                      capture_output=True, check=False, timeout=120).returncode != 0:
        raise ValueError(f'{later} does not descend from the image source {image_source}')
    changed = git('diff', '--name-only', image_source, later, cwd=cwd).splitlines()
    return [path for path in changed if path.startswith(CLOSURE_PREFIXES)]


def require_reuse(image_source: str, later: str, cwd: Path = ROOT) -> None:
    blocked = closure_changes(image_source, later, cwd)
    if blocked:
        raise ValueError(f'{later} changes the Windows build closure since {image_source}: ' + ', '.join(blocked))


def graded_identity(final_log: str) -> tuple[str, str]:
    manifests = re.findall(r'exporting manifest (sha256:[0-9a-f]{64})', final_log)
    configs = re.findall(r'exporting config (sha256:[0-9a-f]{64})', final_log)
    if len(manifests) != 1 or len(configs) != 1:
        raise ValueError('the final stage log must name exactly one manifest and one config')
    return manifests[0], configs[0]


def require_graded(driver_log: str) -> None:
    if 'TARGET ARCH: arm64' not in driver_log:
        raise ValueError('the driver log is not an arm64 run')
    if '[bk:smoke-gate] SKIPPED' in driver_log or not re.search(r'Failed:\s+0\b', driver_log):
        raise ValueError('the driver log lacks a passed smoke gate')
    if '[bk:publish-gate] OK' not in driver_log or not re.search(r'\[bk\] Done in ', driver_log):
        raise ValueError('the driver log lacks a passed publish gate and a completed run')


def device_verdict(log: str, steps: int) -> None:
    verdicts = re.findall(r'(\d+) passed, (\d+) failed \(floor (\d+)\)', log)
    if len(verdicts) != 1 or tuple(map(int, verdicts[0])) != (steps, 0, steps):
        raise ValueError(f'the device log must prove all {steps} steps with the original floor')


def check_receipt(receipt: dict[str, Any], gate_source: str, run_id: int, attempt: int) -> dict[str, Any]:
    export = receipt['Export']
    if export['SchemaVersion'] != 1 or export['HubCommit'] != gate_source or export['RunId'] != str(run_id) \
            or export['RunAttempt'] != str(attempt):
        raise ValueError('the receipt belongs to another CI source, run or attempt')
    if receipt['DeviceArchitecture'] != 'ARM64' or type(receipt['GateExitCode']) is not int \
            or type(receipt['Passed']) is not bool:
        raise ValueError('invalid device verdict types or architecture')
    if receipt['Passed'] != (receipt['GateExitCode'] == 0):
        raise ValueError('the receipt masks a failing device status')
    if not re.fullmatch(re.escape(IMAGE) + r'@sha256:[0-9a-f]{64}', export['Image']):
        raise ValueError('the receipt names another repository or a mutable image')
    if not DIGEST.fullmatch(export['ImageConfig']) or not re.fullmatch('[0-9a-f]{64}', export['BundleSha256']):
        raise ValueError('the receipt lacks exact config and ZIP digests')
    return export


def require_platform(candidate: dict[str, Any], before: dict[str, Any]) -> None:
    if candidate['Os'] != 'windows' or candidate['Architecture'] != 'amd64':
        raise ValueError('the ARM64 bundle must stay a windows/amd64 image')
    if any(before[key] != candidate[key] for key in ('Os', 'Architecture', 'Variant', 'OsVersion')):
        raise ValueError(f'the approved :{TAG} tag would change its runtime platform')


def require_revision(revision: str, image_source: str) -> None:
    if not re.fullmatch('[0-9a-f]{7,40}', revision) or not image_source.startswith(revision):
        raise ValueError('the candidate revision is not the graded image source')


def github(path: str) -> Any:
    result = subprocess.run(['gh', 'api', f'repos/{GITHUB_REPOSITORY}/{path}'], capture_output=True, check=True, timeout=60)
    return json.loads(result.stdout)


def complete_page(value: dict[str, Any], key: str) -> list[dict[str, Any]]:
    if value['total_count'] != len(value[key]):
        raise ValueError('an incomplete GitHub listing cannot prove the producer identity')
    return value[key]


def new_evidence(root: Path, name: str) -> Path:
    path = root / f'{name}-{uuid.uuid4().hex}'
    path.mkdir(parents=True)
    return path


def write_json(path: Path, value: Any) -> None:
    with path.open('x', encoding='utf-8') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')


def buildctl_export(buildctl: str, context: Path, output: str, metadata: Path, log: Path) -> dict[str, Any]:
    common = ['build', '--frontend', 'dockerfile.v0', '--local', f'context={context}', '--local', f'dockerfile={context}',
              '--opt', 'filename=Dockerfile', '--opt', 'image-resolve-mode=local', '--progress', 'plain']
    with log.open('xb') as stream:
        status = subprocess.run([buildctl, *common, '--output', output, '--metadata-file', str(metadata)],
                                stdout=stream, stderr=subprocess.STDOUT, check=False, timeout=3600).returncode
    if status != 0:
        raise ValueError(f'buildctl exited {status}; see {log}')
    return json.loads(metadata.read_text(encoding='utf-8'))


def require_exported(metadata: dict[str, Any], manifest: str, config: str, what: str) -> None:
    if metadata.get('containerimage.digest') != manifest or metadata.get('containerimage.config.digest') != config:
        raise ValueError(f'{what} differs from the graded image')


def require_quiet_host(minimum_free_gib: int) -> None:
    busy = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq buildctl.exe'], capture_output=True, text=True, check=False,
                          timeout=30).stdout if sys.platform == 'win32' else ''
    if 'buildctl.exe' in busy:
        raise ValueError('another buildctl is active')
    if shutil.disk_usage(ROOT).free < minimum_free_gib * 2**30:
        raise ValueError(f'less than {minimum_free_gib} GiB free')


def publish_candidate(args: argparse.Namespace) -> dict[str, Any]:
    worktree = Path(args.worktree)
    if git('rev-parse', 'HEAD', cwd=worktree).strip() != args.source or git('status', '--porcelain', cwd=worktree):
        raise ValueError('the image source must be the clean checked-out commit of the build worktree')
    driver = Path(args.driver_log).read_text(encoding='utf-8-sig', errors='replace')
    require_graded(driver)
    manifest, config = graded_identity(Path(args.final_log).read_text(encoding='utf-8-sig', errors='replace'))
    require_quiet_host(args.min_free_gib)
    module = transport()
    reader = module.Registry(REPOSITORY)
    evidence = new_evidence(Path(args.output_root), f'arm64-candidate-{args.source[:8]}')
    before, _, _ = read(TAG, reader)
    (evidence / 'Dockerfile').write_text(f'FROM {args.local_image}@{manifest}\n', encoding='utf-8')
    dry = buildctl_export(args.buildctl, evidence, f'type=image,name=local/kataglyphis:arm64-acceptance-{args.source[:8]},'
                          'unpack=false', evidence / 'dry-metadata.json', evidence / 'dry-export.log')
    require_exported(dry, manifest, config, 'a pure FROM export')
    pushed = buildctl_export(args.buildctl, evidence, f'type=image,name={IMAGE},push=true,push-by-digest=true,unpack=false',
                             evidence / 'push-metadata.json', evidence / 'digest-export.log')
    require_exported(pushed, manifest, config, 'the digest export')
    candidate, _, _ = read(manifest, reader)
    after, _, _ = read(TAG, reader)
    if after['ManifestDigest'] != before['ManifestDigest']:
        raise ValueError(f'the public :{TAG} tag moved during the candidate export')
    if candidate['ConfigDigest'] != config:
        raise ValueError('the remote candidate config differs from the graded image')
    require_revision(candidate['ImageRevision'], args.source)
    require_platform(candidate, before)
    receipt = {'SourceCommit': args.source, 'ManifestDigest': manifest, 'ConfigDigest': config,
               'Candidate': f'{IMAGE}@{manifest}', 'CandidatePublishedByDigest': True, 'PublicTagChanged': False,
               'DriverLog': args.driver_log, 'FinalLog': args.final_log, 'Before': before, 'CandidateIdentity': candidate}
    write_json(evidence / 'receipt.json', receipt)
    return dict(receipt, Evidence=str(evidence))


def require_device_jobs(run_id: int) -> tuple[dict[str, Any], dict[str, Any]]:
    jobs = complete_page(github(f'actions/runs/{run_id}/jobs?per_page=100'), 'jobs')
    exports = [job for job in jobs if job['name'] == 'export the bundle (windows-2025)']
    devices = [job for job in jobs if job['name'] == 'bundle device gate (windows-11-arm)']
    if len(exports) != 1 or len(devices) != 1 or exports[0]['conclusion'] != 'success':
        raise ValueError('no unique successful export and device job')
    return exports[0], devices[0]


def download_receipt(artifact: dict[str, Any], evidence: Path) -> bytes:
    archive = evidence / 'receipt.zip'
    with archive.open('xb') as stream:
        subprocess.run(['gh', 'api', f'repos/{GITHUB_REPOSITORY}/actions/artifacts/{artifact["id"]}/zip'], stdout=stream,
                       check=True, timeout=120)
    with archive.open('rb') as stream:
        digest = 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()
    if digest != artifact['digest'] or archive.stat().st_size != artifact['size_in_bytes']:
        raise ValueError('the receipt upload bytes differ from the GitHub artifact metadata')
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        if len(entries) != 1 or entries[0].filename != 'device-acceptance.json' \
                or ((entries[0].external_attr >> 16) & 0xF000) == 0xA000:
            raise ValueError('unexpected receipt archive members')
        return zipped.read(entries[0])


def fetch(run_id: int, gate_source: str, output_root: Path) -> dict[str, Any]:
    run = github(f'actions/runs/{run_id}')
    if run['repository']['full_name'] != GITHUB_REPOSITORY or run['head_sha'] != gate_source \
            or run['head_branch'] != 'develop' or run['path'] != WORKFLOW or run['actor']['login'] != 'Kataglyphis':
        raise ValueError('the producer repository, source, branch, workflow or actor differs')
    if run['status'] != 'completed':
        raise ValueError('the device workflow is not terminal')
    export_job, device = require_device_jobs(run_id)
    artifacts = complete_page(github(f'actions/runs/{run_id}/artifacts?per_page=100'), 'artifacts')
    receipts = [a for a in artifacts if a['name'] == 'winarm64-device-acceptance' and not a['expired']]
    bundles = [a for a in artifacts if a['name'] == 'winarm64-bundle' and not a['expired']]
    if len(receipts) != 1 or len(bundles) != 1:
        raise ValueError('expected one receipt and one bundle artifact')
    evidence = new_evidence(output_root, f'arm64-device-{run_id}')
    receipt_raw = download_receipt(receipts[0], evidence)
    receipt = json.loads(receipt_raw.decode('utf-8-sig'))
    check_receipt(receipt, gate_source, run_id, run['run_attempt'])
    log = subprocess.run(['gh', 'api', f'repos/{GITHUB_REPOSITORY}/actions/jobs/{device["id"]}/logs',
                          '--allow-escape-sequences'], capture_output=True, check=True, timeout=120).stdout
    log_text = log.decode('utf-8-sig', errors='replace')
    if str(bundles[0]['id']) not in log_text or \
            ('SHA256 digest of downloaded artifact is ' + bundles[0]['digest'].removeprefix('sha256:')) not in log_text:
        raise ValueError('the device log does not prove the bundle artifact identity and upload digest')
    (evidence / 'device-acceptance.json').write_bytes(receipt_raw)
    (evidence / 'device.log').write_bytes(log)
    proof = {'GateSource': gate_source, 'RunId': run_id, 'RunAttempt': run['run_attempt'], 'Event': run['event'],
             'RunConclusion': run['conclusion'], 'ExportJobId': export_job['id'], 'DeviceJobId': device['id'],
             'DeviceJobConclusion': device['conclusion'], 'ArtifactId': receipts[0]['id'],
             'ArtifactDigest': receipts[0]['digest'], 'BundleArtifactId': bundles[0]['id'],
             'BundleArtifactDigest': bundles[0]['digest'], 'ReceiptSha256': hashlib.sha256(receipt_raw).hexdigest(),
             'Receipt': receipt, 'Evidence': str(evidence),
             'Coverage': 'Trusted CI artifact, source, attempt and device-download binding; no GPU inference proof.'}
    write_json(evidence / 'proof.json', proof)
    return proof


def require_ci_runs(run_ids: list[int], image_source: str) -> list[dict[str, Any]]:
    runs = []
    for run_id in run_ids:
        run = github(f'actions/runs/{run_id}')
        if run['repository']['full_name'] != GITHUB_REPOSITORY or run['status'] != 'completed' \
                or run['conclusion'] != 'success':
            raise ValueError(f'required CI run {run_id} did not succeed')
        require_reuse(image_source, run['head_sha'])
        runs.append({'id': run_id, 'path': run['path'], 'head_sha': run['head_sha'], 'conclusion': run['conclusion']})
    return runs


def require_accepted(proof: dict[str, Any], local: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    receipt = proof['Receipt']
    if proof['Event'] != 'workflow_dispatch' or proof['RunConclusion'] != 'success' \
            or proof['DeviceJobConclusion'] != 'success':
        raise ValueError('only a successful manual candidate run can promote the ARM64 tag')
    if receipt['Passed'] is not True or receipt['GateExitCode'] != 0:
        raise ValueError('the device acceptance did not pass')
    export = receipt['Export']
    candidate_ref = f'{IMAGE}@{args.candidate}'
    if export['RequestedImage'] != candidate_ref or export['Image'] != candidate_ref:
        raise ValueError('the device did not accept the requested immutable candidate')
    device_verdict((Path(proof['Evidence']) / 'device.log').read_text(encoding='utf-8-sig', errors='replace'), args.steps)
    if local['SourceCommit'] != args.image_source or local['ManifestDigest'] != args.candidate \
            or local['ConfigDigest'] != export['ImageConfig']:
        raise ValueError('the graded local candidate differs from the accepted producer')
    if local['CandidatePublishedByDigest'] is not True or local['PublicTagChanged'] is not False:
        raise ValueError('the candidate upload lacks its unchanged-tag proof')
    return export


def publish_tag(raw: bytes, media: str, before: dict[str, Any], candidate: dict[str, Any], module: ModuleType) -> dict[str, Any]:
    writer = module.Registry(REPOSITORY, write=True)
    current, _, _ = read(TAG, writer)
    if current['ManifestDigest'] != before['ManifestDigest']:
        raise ValueError(f'the :{TAG} tag moved before publication')
    writer.publish(TAG, raw, media)
    after, _, _ = read(TAG, writer)
    if after['ManifestDigest'] != candidate['ManifestDigest'] or after['ConfigDigest'] != candidate['ConfigDigest']:
        raise ValueError('the published tag differs from the accepted manifest and config')
    return after


def promote(args: argparse.Namespace) -> dict[str, Any]:
    output_root = Path(args.output_root)
    require_reuse(args.image_source, args.gate_source)
    proof = fetch(args.run_id, args.gate_source, output_root)
    local = json.loads(Path(args.candidate_receipt).read_text(encoding='utf-8-sig'))
    export = require_accepted(proof, local, args)
    ci_runs = require_ci_runs(args.require_ci_run, args.image_source)
    require_reuse(args.image_source, github('git/ref/heads/develop')['object']['sha'])
    module = transport()
    reader = module.Registry(REPOSITORY)
    candidate, raw, media = read(args.candidate, reader)
    before, _, _ = read(TAG, reader)
    if candidate['ConfigDigest'] != export['ImageConfig'] or candidate['ImageRevision'] != export['ImageRevision']:
        raise ValueError('the remote image differs from the device receipt')
    require_revision(candidate['ImageRevision'], args.image_source)
    require_platform(candidate, before)
    result = {'ImageSource': args.image_source, 'GateSource': args.gate_source, 'Candidate': f'{IMAGE}@{args.candidate}',
              'Before': before, 'CandidateIdentity': candidate, 'DeviceProof': proof, 'RequiredCIRuns': ci_runs,
              'Applied': False, 'PublicTagChanged': False}
    if args.apply:
        after = publish_tag(raw, media, before, candidate, module)
        result.update(Applied=True, PublicTagChanged=after['ManifestDigest'] != before['ManifestDigest'], After=after)
    output = output_root / f'arm64-promotion-{args.image_source[:8]}-{uuid.uuid4().hex}.json'
    write_json(output, result)
    return {'Applied': result['Applied'], 'Candidate': result['Candidate'], 'Evidence': str(output)}


def full_commit(value: str) -> str:
    if not COMMIT.fullmatch(value):
        raise argparse.ArgumentTypeError('expected a full lowercase commit SHA')
    return value


def digest(value: str) -> str:
    if not DIGEST.fullmatch(value):
        raise argparse.ArgumentTypeError('expected an exact sha256 digest')
    return value


def parser() -> argparse.ArgumentParser:
    main = argparse.ArgumentParser(description=__doc__)
    sub = main.add_subparsers(dest='command', required=True)
    out = str(ROOT / 'logs/test-results/windows-goal')
    reader = sub.add_parser('read', help='read the tag or a candidate digest from the registry')
    reader.add_argument('--reference', required=True, type=check_reference)
    upload = sub.add_parser('publish-candidate', help='push the graded local image by digest only')
    upload.add_argument('--source', required=True, type=full_commit)
    upload.add_argument('--worktree', required=True)
    upload.add_argument('--driver-log', required=True)
    upload.add_argument('--final-log', required=True)
    upload.add_argument('--local-image', default='local/kataglyphis:bk-winarm64')
    upload.add_argument('--buildctl', default='buildctl')
    upload.add_argument('--min-free-gib', type=int, default=40)
    upload.add_argument('--output-root', default=out)
    fetcher = sub.add_parser('fetch', help='download and check a device run receipt')
    fetcher.add_argument('--run-id', required=True, type=int)
    fetcher.add_argument('--gate-source', required=True, type=full_commit)
    fetcher.add_argument('--output-root', default=out)
    promoter = sub.add_parser('promote', help='check a device run and, with --apply, move the tag')
    promoter.add_argument('--run-id', required=True, type=int)
    promoter.add_argument('--image-source', required=True, type=full_commit)
    promoter.add_argument('--gate-source', required=True, type=full_commit)
    promoter.add_argument('--candidate', required=True, type=digest)
    promoter.add_argument('--candidate-receipt', required=True)
    promoter.add_argument('--require-ci-run', type=int, action='append', required=True)
    promoter.add_argument('--steps', type=int, default=22)
    promoter.add_argument('--output-root', default=out)
    promoter.add_argument('--apply', action='store_true')
    return main


def main() -> int:
    args = parser().parse_args()
    if args.command == 'read':
        result: Any = read(args.reference, transport().Registry(REPOSITORY))[0]
    elif args.command == 'publish-candidate':
        result = publish_candidate(args)
    elif args.command == 'fetch':
        result = fetch(args.run_id, args.gate_source, Path(args.output_root))
    else:
        result = promote(args)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
