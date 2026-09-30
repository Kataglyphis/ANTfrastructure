# Test-BuildCopy.ps1 passes the chain's base digest, so the probe certifies the same base.
ARG BASE=mcr.microsoft.com/windows/servercore:ltsc2025
FROM ${BASE}
RUN echo probe > C:\probe.txt
COPY hello.txt C:\hello.txt
