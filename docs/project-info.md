# Project Information

## Prerequisites

- Docker with buildx/nerdctl support.
- GPU passthrough configured when building Vulkan-enabled images.

## Installation

1. Clone the repo:

   ```bash
   git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-ContainerHub.git
   ```

## Tests

Add test steps here as they become available.

## Roadmap

Upcoming :)

## Troubleshooting

### Caching is weird or files cannot be found

**Symptom:** caching is weird or files cannot be found.

**Solution:**

```bash
# change this line
RUSTC_WRAPPER= /usr/bin/sccache 
# to
RUSTC_WRAPPER="" 
```

### No space left on this device

**Symptom:** no space left on this device.

**Solution:**

Don't write to `tmp/` folder! This is stupid. Write to tmp2 f.e.

## Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are greatly appreciated.

1. Fork the project.
2. Create your feature branch (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a pull request.

## License

Add your license details here.

## Contact

Jonas Heinle - [@Cataglyphis_](https://twitter.com/Cataglyphis_) - jonasheinle@googlemail.com

Project Link: [https://github.com/Kataglyphis/...](https://github.com/Kataglyphis/...)

## Acknowledgements

Thanks for free 3D models:

- [Morgan McGuire, Computer Graphics Archive, July 2017](http://casual-effects.com/data)
- [Viking room](https://sketchfab.com/3d-models/viking-room-a49f1b8e4f5c4ecf9e1fe7d81915ad38)

## Literature

Some very helpful literature, tutorials, etc.

- [Rancher Desktop](https://rancherdesktop.io/)
- [containerd](https://github.com/containerd/containerd)