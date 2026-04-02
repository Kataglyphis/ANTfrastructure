Kurz: Wiederverwendbares Packaging-Skript

Platz: ExternalLib/Kataglyphis-ContainerHub/linux/scripts/06-packaging/package_archive.sh

Usage (lokal):

```
bash ExternalLib/Kataglyphis-ContainerHub/linux/scripts/06-packaging/package_archive.sh --binary myapp --version 1.2.3
```

Beispiele für CI (Docker):

```
docker run --rm \
  -v $PWD:/workspace -w /workspace \
  ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest \
  bash -lc 'bash ExternalLib/Kataglyphis-ContainerHub/linux/scripts/06-packaging/package_archive.sh --binary myapp --version 1.2.3'
```

Der Skript erwartet eine Release-Binary unter `target/release/$BINARY_FILE` und legt Artefakte in `dist/` ab.

Weiteres:
- Das Skript nutzt helper in `../01-core/` (z.B. `logging.sh`).
- Für vollständige Wiederverwendbarkeit kann ein Docker-Image oder eine GitHub Action um diesen Ordner gebaut werden.
