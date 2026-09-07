.. ContainerHub documentation master file, created by
   sphinx-quickstart on Thu Dec 11 16:37:46 2025.
   You can adapt this file completely to your liking, but it should at least
   contain the root `toctree` directive.

ContainerHub documentation
======================================

.. rst-class:: hero-section

Multi-stage Linux container images for GPU development stacks, a slim nginx webserver, and a Windows build image.

- Multi-stage Linux images for reproducible caching
- Windows toolchain container for CI and local builds
- Optional media and Android layers for specialized workloads

Choose the guide that matches the task you want to do — or start from the
documentation index, which maps every topic to the page that owns it.

.. grid:: 2
   :gutter: 2

   .. grid-item-card:: Documentation Index
      :link: INDEX
      :link-type: doc

      Topic to owning document, for this repo and every project that consumes it. **Start here.**

   .. grid-item-card:: Common Failure Modes
      :link: failure-modes
      :link-type: doc

      Symptom, cause and fix for every failure hit live on the Linux and Windows lanes.

   .. grid-item-card:: Adopting In A New Project
      :link: adopting-in-a-new-project
      :link-type: doc

      Wiring a new project to this repo: submodule, module resolver, container builds, CI actions.

   .. grid-item-card:: Project Overview
      :link: overview
      :link-type: doc

      Published images, repository image chain, and a feature snapshot.

   .. grid-item-card:: Linux Build Basics
      :link: linux-build-basics
      :link-type: doc

      Local runs, multi-arch builds, and sequential ``nerdctl`` builds.

   .. grid-item-card:: Linux Cross Builds
      :link: linux-cross-builds
      :link-type: doc

      Additive cross-compiler lane, SDK rootfs artifacts, runtime artifacts, and manifest publishing.

   .. grid-item-card:: Linux Accelerator Images
      :link: linux-accelerator-images
      :link-type: doc

      NVIDIA, AMD, and Torch variants on top of the standard Linux image chain.

   .. grid-item-card:: Linux Host Setup
      :link: linux-host-setup
      :link-type: doc

      GPU drivers, CUDA, container runtime config, performance mode, and boot recovery on the host.

   .. grid-item-card:: Windows Build Image
      :link: windows-builds
      :link-type: doc

      What is installed, the build commands, the patch policy, and the smoke gate.

   .. grid-item-card:: Windows Build Lanes
      :link: windows-build-lanes
      :link-type: doc

      BuildKit and nerdctl: which to use, isolation policy, preflight gates, and the removed classic docker lane.

   .. grid-item-card:: Windows Build Invariants
      :link: windows-build-invariants
      :link-type: doc

      47 load-bearing rules, each with the incident that produced it. Read before editing ``windows/``.

   .. grid-item-card:: Windows Host Setup
      :link: windows-host-setup
      :link-type: doc

      Ordered bring-up for a brand-new Windows host, host gates included.

   .. grid-item-card:: Runtime Services and Streaming
      :link: runtime-services
      :link-type: doc

      Webserver, display forwarding, Raspberry Pi camera notes, and WebRTC signalling and streaming.

   .. grid-item-card:: Project Information
      :link: project-info
      :link-type: doc

      Prerequisites, installation, tests, roadmap, troubleshooting, contribution, contact, and references.

   .. grid-item-card:: Third-Party Licences
      :link: third-party-licenses
      :link-type: doc

      Every bundled component, what its licence obliges this project to do, and the corresponding source for the copyleft ones.

Linux image flow
----------------

The Linux container stack is intentionally split into reusable stages so BuildKit can cache stable
layers and rebuild only the slice you changed.

For the full image chain, see :doc:`Project Overview <overview>`. For local and multi-arch build
commands, see :doc:`Linux Build Basics <linux-build-basics>`.

Common development targets:

.. code-block:: bash

   nerdctl build -f linux/Dockerfile.base -t local/kataglyphis:base .
   nerdctl build -f linux/Dockerfile.toolchain -t local/kataglyphis:compiler .
   nerdctl build -f linux/Dockerfile.sdk -t local/kataglyphis:sdk .
   nerdctl build -f linux/Dockerfile.media -t local/kataglyphis:media .
   nerdctl build -f linux/Dockerfile.android -t local/kataglyphis:android .
   nerdctl build -f linux/Dockerfile.torch -t local/kataglyphis:latest .


.. toctree::
   :maxdepth: 1
   :caption: Start here:

   INDEX
   failure-modes
   adopting-in-a-new-project
   overview

.. toctree::
   :maxdepth: 2
   :caption: Linux:

   linux-build-basics
   linux-cross-builds
   artifact-copy-completeness
   vulkan-foreign-arch-sdk
   consumer-image-contract
   gen1-riscv64-genai
   qnn-linux
   riscv64-venv-parity
   riscv64-rva23-baseline
   upstreamable-patches
   upstream/README
   iree-two-stage-build
   linux-accelerator-images
   linux-host-setup
   runtime-services
   rancher-desktop-linux-containers
   linux-reference

.. toctree::
   :maxdepth: 2
   :caption: Windows:

   windows-builds
   windows-build-lanes
   windows-build-invariants
   windows-build-resources
   windows-clang-cl-sanitizers
   windows-cross-builds
   windows-host-setup
   windows-stevedore-and-docker
   windows-container-build-performance
   windows-reference
   upstream-windows-patches

.. toctree::
   :maxdepth: 1
   :caption: Build, CI and tooling:

   build-cache-tiers
   build-parallelism-memory-tuning
   build-resource-monitoring
   build-secrets
   cross-build-verification
   code-quality-tooling
   code-quality-gates
   shared-script-libraries
   slang-shader-compilation
   python-ci
   ci-build-triggers
   github-cli-pipeline-monitoring
   mistral-vibe-glm-setup
   geniex-local-ai-setup
   llm-benchmark-roadmap
   llm-benchmark-review-2026-09-05
   agentic-loop-build-matrix
   windows-agentic-loop

.. toctree::
   :maxdepth: 1
   :caption: Project:

   project-info
   third-party-licenses
   sbom
   vulnerability-scanning
   upstream-libstdcxx-c++23-nostdinc++
   upstream/hcsshim-lost-shutdown-notification-issue
   upstream/windows-containers-lsm-session-event-hang

.. toctree::
   :maxdepth: 1
   :caption: Backlogs and archives:

   refactoring-backlog
   build-watch-list
   windows-refactor-backlog
   changelog-archive-2026-08-28
   changelog-archive-2026-08-13
   refactoring-backlog-archive-2026-08-10
   refactoring-backlog-archive-2026-08-27
   refactoring-backlog-archive-2026-08-30
   refactoring-backlog-archive-2026-08-31
   refactoring-backlog-archive-2026-09-02
   refactoring-backlog-archive-2026-09-03
   windows-backlog-archive-2026-08-11
   windows-backlog-archive-2026-08-17
   windows-backlog-archive-2026-08-21
   windows-backlog-archive-2026-08-26
   windows-backlog-archive-2026-08-31
