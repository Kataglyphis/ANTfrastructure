.. Kataglyphis-ContainerHub documentation master file, created by
   sphinx-quickstart on Thu Dec 11 16:37:46 2025.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

Kataglyphis-ContainerHub documentation
======================================

This repository provides Docker templates for Linux (GPU-friendly dev stack), a slim nginx webserver,
and a Windows build image.

Linux: multi-stage Dockerfile
-----------------------------

The Linux image at ``linux/Dockerfile`` is split into logical stages to improve BuildKit caching and
avoid rebuilding the whole world when only scripts change.

Stages:

- ``os-deps``: Ubuntu base + stable apt dependencies (no project scripts copied).
- ``toolchain``: GCC/LLVM/Vulkan toolchain setup via scripts.
- ``media``: ONNX Runtime + GStreamer + Libcamera builds.
- ``android``: Android SDK/NDK setup (x86_64 only).
- ``final``: runtime scripts + entrypoint (default build output).

Build only a specific stage (useful during development):

.. code-block:: bash

   docker buildx build -f linux/Dockerfile --target os-deps -t local/kataglyphis:os-deps .
   docker buildx build -f linux/Dockerfile --target toolchain -t local/kataglyphis:toolchain .
   docker buildx build -f linux/Dockerfile --target media -t local/kataglyphis:media .
   docker buildx build -f linux/Dockerfile --target final -t local/kataglyphis:latest .


.. toctree::
   :maxdepth: 2
   :caption: Contents:

