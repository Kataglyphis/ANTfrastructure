<h1 align="center">
  <br>
  <a href="https://jonasheinle.de"><img src="images/logo.png" alt="logo" width="200"></a>
  <br>
  Cataglyphis template
  <br>
</h1>

<!-- <h1 align="center">
  <br>
  <a href="https://jonasheinle.de"><img src="images/vulkan-logo.png" alt="VulkanEngine" width="200"></a>
  <a href="https://jonasheinle.de"><img src="images/Engine_logo.png" alt="VulkanEngine" width="200"></a>
  <a href="https://jonasheinle.de"><img src="images/glm_logo.png" alt="VulkanEngine" width="200"></a>
</h1> -->

<h4 align="center">A template <a href="https://jonasheinle.de" target="_blank"></a>.</h4>

> **Important** add current user to docker group
> sudo usermod -aG docker $USER
> You can only docker push to ghcr.io without sudo docker

<!-- [![Linux build](https://github.com/Kataglyphis/GraphicsEngineVulkan/actions/workflows/Linux.yml/badge.svg)](https://github.com/Kataglyphis/GraphicsEngineVulkan/actions/workflows/Linux.yml)
[![Windows build](https://github.com/Kataglyphis/GraphicsEngineVulkan/actions/workflows/Windows.yml/badge.svg)](https://github.com/Kataglyphis/GraphicsEngineVulkan/actions/workflows/Windows.yml)
[![TopLang](https://img.shields.io/github/languages/top/Kataglyphis/GraphicsEngineVulkan)]() -->
[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/paypalme/JonasHeinle)
[![Twitter](https://img.shields.io/twitter/follow/Cataglyphis_?style=social)](https://twitter.com/Cataglyphis_)

<p align="center">
  <a href="#about-the-project">About The Project</a> •
  <a href="#getting-started">Getting Started</a> •
  <a href="#license">License</a> •
  <a href="#literature">Literature</a>
</p>

<!-- TABLE OF CONTENTS -->
<details open="open">
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#key-features">Key Features</a></li>
      </ul>
      <ul>
        <li><a href="#dependencies">Dependencies</a></li>
      </ul>
      <ul>
        <li><a href="#useful-tools">Useful tools</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
      </ul>
    </li>
    <li><a href="#tests">Tests</a></li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgements">Acknowledgements</a></li>
    <li><a href="#literature">Literature</a></li>
  </ol>
</details>

<!-- ABOUT THE PROJECT -->
## About The Project

<!-- <h1 align="center">
  <br>
  <a href="https://jonasheinle.de"><img src="images/Screenshot1.png" alt="VulkanEngine" width="400"></a>
  <a href="https://jonasheinle.de"><img src="images/Screenshot2.png" alt="VulkanEngine" width="400"></a>
  <a href="https://jonasheinle.de"><img src="images/Screenshot3.png" alt="VulkanEngine" width="700"></a>
</h1> -->

<!-- [![Kataglyphis Engine][product-screenshot1]](https://jonasheinle.de)
[![Kataglyphis Engine][product-screenshot2]](https://jonasheinle.de)
[![Kataglyphis Engine][product-screenshot3]](https://jonasheinle.de) -->

This project is a template. 

### Key Features


- Features are to be adjusted to your own project needs.


<div align="center">


|            Category           |           Feature                             |  Implement Status  |
|-------------------------------|-----------------------------------------------|:------------------:|
|  **Packaging agnostic**       | Binary only deployment                        |         ✔️         |
|                               | Lore ipsum                                    |         ✔️         |
|  **Lore ipsum agnostic**      |                                               |                    |
|                               | LORE IPSUM                                    |         ✔️         |
|                               |                                               |                    |
|                               | Advanced unit testing                         |         🔶         |
|                               | Advanced performance testing                  |         🔶         |
|                               | Advanced fuzz testing                         |         🔶         |

</div>

**Legend:**
- ✔️ - completed  
- 🔶 - in progress  
- ❌ - not started

### Dependencies
This enumeration also includes submodules.
<!-- * [Vulkan 1.3](https://www.vulkan.org/) -->

### Useful tools

<!-- * [cppcheck](https://cppcheck.sourceforge.io/) -->

<!-- GETTING STARTED -->
## Getting Started

### Linux

#### Build

```bash
docker build -t kataglyphis/kataglyphis_beschleuniger_test:latest -f linux/Dockerfile  .
# on windows u must expose ports one by one
docker run -it --rm -p 8443:8443 kataglyphis/kataglyphis_beschleuniger_test:latest
```

#### Multi Arch Build

##### Setup
Always build with --platform=
```bash
docker buildx imagetools create --tag ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest_multiarch   ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest   ghcr.io/kataglyphis/kataglyphis_beschleuniger:amd64
```

```bash
cat > /tmp/buildkitd.toml <<'TOML'
# limit BuildKit worker parallelism to 2 (set to 1 on very small machines)
[worker.oci]
  max-parallelism = 2
TOML
```

```bash
nerdctl build --platform=arm64 --output type=image,name=ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest,push=true -f linux/Dockerfile .
```

```bash
docker buildx rm mybuilder 2>/dev/null || true
docker buildx create --name mybuilder --driver docker-container --buildkitd-config /tmp/buildkitd.toml --use --
```

```bash
nerdctl run --rm --privileged tonistiigi/binfmt --install all
nerdctl build --platform linux/amd64,linux/arm64 -t ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest -f linux/Dockerfile .
```

### Prerequisites

### Installation

1. Clone the repo
   ```sh
   git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-DockerHub.git
   ```

## Tests

<!-- ROADMAP -->
## Roadmap
Upcoming :)
<!-- See the [open issues](https://github.com/othneildrew/Best-README-Template/issues) for a list of proposed features (and known issues). -->



<!-- CONTRIBUTING -->
## Contributing

Contributions are what make the open source community such an amazing place to be learn, inspire, and create. Any contributions you make are **greatly appreciated**.

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request


<!-- LICENSE -->
## License

<!-- CONTACT -->
## Contact

Jonas Heinle - [@Cataglyphis_](https://twitter.com/Cataglyphis_) - jonasheinle@googlemail.com

Project Link: [https://github.com/Kataglyphis/...](https://github.com/Kataglyphis/...)


<!-- ACKNOWLEDGEMENTS -->
## Acknowledgements

<!-- Thanks for free 3D Models: 
* [Morgan McGuire, Computer Graphics Archive, July 2017 (https://casual-effects.com/data)](http://casual-effects.com/data/)
* [Viking room](https://sketchfab.com/3d-models/viking-room-a49f1b8e4f5c4ecf9e1fe7d81915ad38) -->

## Literature 

Some very helpful literature, tutorials, etc. 

* [Rancher Desktop](https://rancherdesktop.io/)
* [containerd](https://github.com/containerd/containerd)

## Troubleshooting
1.
