# BASE is build-arg-pinnable so the probe certifies the SAME digest the chain
# builds on (Test-BuildCopy.ps1 passes versions.env's WINDOWS_BASE_DIGEST;
# the tag default keeps the probe usable standalone). Backlog #26.
ARG BASE=mcr.microsoft.com/windows/servercore:ltsc2025
FROM ${BASE}
RUN echo probe > C:\probe.txt
COPY hello.txt C:\hello.txt
