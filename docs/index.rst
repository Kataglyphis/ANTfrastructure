.. Kataglyphis-ContainerHub documentation master file, created by
   sphinx-quickstart on Thu Dec 11 16:37:46 2025.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

Kataglyphis-ContainerHub documentation
======================================

.. rst-class:: hero-section

Docker templates for Linux GPU development stacks, a slim nginx webserver, and a Windows build image.

- Multi-stage Linux images for reproducible caching
- Windows toolchain container for CI and local builds
- Optional media and Android layers for specialized workloads

.. grid:: 2
   :gutter: 2

   .. grid-item-card:: Linux Dockerfiles

      Multi-stage Linux images: ``os-deps`` → ``toolchain`` → ``media`` → ``android`` → ``final``.

   .. grid-item-card:: Windows Dockerfile

      Build image with MSVC, LLVM/Clang, Vulkan SDK, Rust, Flutter and WiX.

   .. grid-item-card:: Build Commands

      Ready-to-use examples for ``docker buildx`` and ``nerdctl`` workflows.

   .. grid-item-card:: CI-Friendly Docs

      Documentation site designed for readability in light and dark mode.

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

