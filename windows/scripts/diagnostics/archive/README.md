# Archived probes

One-shot probes whose question is settled (each header names the incident and
the verdict's date). Kept for the record — the measurement methodology is
often the reusable part. Still runnable without restoration:

    run-diagnostic-probe.ps1 -ProbeScript archive/<name>.ps1 -BaseImage <tag>

Policy: a probe moves here when (a) its question has a recorded answer AND
(b) nothing lists it as a re-run trigger (upgrade re-tests like the
`test-*.ps1` family stay live no matter how rarely they run). Move it back
out if its subject reopens.
