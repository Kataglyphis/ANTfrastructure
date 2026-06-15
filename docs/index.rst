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

Choose the guide that matches the task you want to do: inspect the image catalog, run a local Linux image,
build cross-architecture artifacts, enable GPU variants, use runtime services, or build the Windows image.

.. grid:: 2
   :gutter: 2

   .. grid-item-card:: Project Overview
      :link: overview
      :link-type: doc

      Published images, repository image chain, feature snapshot, dependencies, and useful tools.

   .. grid-item-card:: Linux Build Basics
      :link: linux-build-basics
      :link-type: doc

      Local runs, multi-arch builds, buildx workflows, and sequential ``nerdctl`` builds.

   .. grid-item-card:: Linux Cross Builds
      :link: linux-cross-builds
      :link-type: doc

      Additive cross-compiler lane, SDK rootfs artifacts, runtime artifacts, and manifest publishing.

   .. grid-item-card:: Linux Accelerator Images
      :link: linux-accelerator-images
      :link-type: doc

      NVIDIA, AMD, and Torch variants on top of the standard Linux image chain.

   .. grid-item-card:: Runtime Services and Streaming
      :link: runtime-services
      :link-type: doc

      Webserver, display forwarding, Raspberry Pi camera notes, and WebRTC signalling and streaming.

   .. grid-item-card:: Windows Build Image
      :link: windows-builds
      :link-type: doc

      Windows container build command, antivirus warning, and memory notes.

   .. grid-item-card:: Project Information
      :link: project-info
      :link-type: doc

      Prerequisites, installation, tests, roadmap, troubleshooting, contribution, contact, and references.

Linux image flow
----------------

The Linux container stack is intentionally split into reusable stages so BuildKit can cache stable
layers and rebuild only the slice you changed.

For the full image chain, see :doc:`Project Overview <overview>`. For local and multi-arch build
commands, see :doc:`Linux Build Basics <linux-build-basics>`.

Common development targets:

.. code-block:: bash

   docker buildx build -f linux/Dockerfile.base -t local/kataglyphis:base .
   docker buildx build -f linux/Dockerfile.toolchain -t local/kataglyphis:compiler .
   docker buildx build -f linux/Dockerfile.sdk -t local/kataglyphis:sdk .
   docker buildx build -f linux/Dockerfile.media -t local/kataglyphis:media .
   docker buildx build -f linux/Dockerfile.android -t local/kataglyphis:android .
   docker buildx build -f linux/Dockerfile.torch -t local/kataglyphis:latest .


.. toctree::
   :maxdepth: 2
   :caption: Contents:

   overview
   linux-build-basics
   linux-cross-builds
   linux-accelerator-images
   runtime-services
   windows-builds
   project-info
