# Cool Reader Server

A small home server for comics, manga and ebooks, in the spirit of Plex: point it at your folders, drop files
in them, and it recognises the series, finds their posters and synopses, and lets the people you invite read
the libraries you choose — in [Cool Reader](https://apps.apple.com/app/cool-reader/id6829489019) on iPhone and
iPad, in any OPDS reader, or in a browser.

Free and open source (MIT). No account to create anywhere, no relay, nothing to pay: your books stay on your
machine and only reach the devices you pair.

> **Status: early.** The server scans, matches, serves the API and OPDS, and manages members. The Mac menu bar
> app, pairing from Cool Reader, HTTPS and access from outside the home are next (see [Roadmap](#roadmap)).

## What it does

- **Libraries** are folders on the server: `Mangas`, `BD`, `Romans`… It reads them and never changes them.
- **Formats**: CBZ/ZIP, CBR/RAR (RAR 4 and 5, solid archives included), CB7/7z, CBT/TAR, EPUB, PDF — read by
  its own Swift decoders, the same as Cool Reader's.
- **Series, recognised like in the app**: a folder is a series ("Dragon Ball/Dragon Ball T03.cbz"), loose files
  are grouped by name, ComicInfo.xml and `.nfo` files come first. Manga are matched on AniList then MangaDex,
  books and BD on Apple Books then Open Library: poster, banner, synopsis, authors, genres, volume covers.
  Only series titles are sent to those catalogues.
- **Members** with their own password, the libraries you tick for them, and their own reading progress.
- **Devices** pair with a six-digit code, like Jellyfin's Quick Connect: no password stored on the phone, and a
  lost device is revoked in one click.
- **OPDS 1.2** with page streaming: Panels, Chunky, KOReader or any OPDS reader can browse, download and read
  page by page.

## Install

### Docker (NAS, Linux, Raspberry Pi)

```yaml
services:
  coolreader:
    image: ghcr.io/pookee/cool-reader-server:latest
    ports:
      - "7272:7272"
    volumes:
      - ./config:/config                       # database, cache, setup code
      - /volume1/Mangas:/libraries/Mangas:ro   # read only
      - /volume1/BD:/libraries/BD:ro
    environment:
      COOLREADER_METADATA_LANGUAGE: fr         # language of synopses and editions
      COOLREADER_METADATA_COUNTRY: fr          # Apple Books store
    restart: unless-stopped
```

The image is published from version 0.1. Until then, build it from this repository: `docker build -t cool-reader-server .`

### macOS, from the source

```bash
swift run -c release cool-reader-server --config ~/CoolReaderServer --library Mangas=/Users/you/Mangas
```

## First start

1. The server prints a six-digit **setup code** in its logs (`docker logs coolreader`) and writes it to
   `config/setup-code.txt`.
2. Open `http://<server>:7272`, type the code and create the admin account.
3. Add libraries (in Docker, the folders you mounted under `/libraries`), then members.
4. OPDS readers: add `http://<server>:7272/opds` with a member's name and password.

## Settings

| Environment | Command line | Default |
| --- | --- | --- |
| `COOLREADER_CONFIG` | `--config` | `./config` (`/config` in Docker) |
| `COOLREADER_PORT` | `--port` | `7272` |
| `COOLREADER_HOST` | `--host` | `0.0.0.0` |
| `COOLREADER_METADATA_LANGUAGE` | `--metadata-language` | `en` |
| `COOLREADER_METADATA_COUNTRY` | `--metadata-country` | `us` |
| `COOLREADER_ONLINE_METADATA=0` | `--offline` | on |
| `COOLREADER_SCAN_INTERVAL` (minutes) | | `30` |
| | `--library Name=/path` (repeatable) | |

## Security

- The first account can only be created with the setup code shown on the server.
- Passwords are hashed with PBKDF2-HMAC-SHA256 (600,000 rounds); repeated wrong passwords are throttled.
- Devices get their own revocable token; only its SHA-256 is stored.
- Every request checks that the member may see the library; files are served by id, never by path.
- Library folders are read only. The server writes only in its config folder.
- The web pages refuse forms posted from other sites and set a strict content security policy.
- Nothing is reachable from the internet unless you open it; see the roadmap for remote access.

Report vulnerabilities privately: see [SECURITY.md](SECURITY.md).

## Roadmap

1. Cool Reader reads OPDS catalogues (this server, Komga, Kavita, Calibre-Web…).
2. The shared core — formats, names, catalogues — becomes a Swift package that Cool Reader uses too.
3. A Mac menu bar app; Bonjour discovery and pairing from Cool Reader; HTTPS with a certificate the app pins.
4. Access from outside the home without a relay: a port opened on the router (UPnP / NAT-PMP), a free DuckDNS
   name if the address changes; a VPN such as Tailscale stays possible, never required.
5. Thumbnails and PDF covers on Linux; Unraid and Synology templates; a native Windows build if asked for.

## Building and testing

```bash
swift build
swift test
```

Swift 6, SwiftNIO and swift-crypto (Apple), SQLite. `Sources/CoolReaderKit/Core` holds the books, formats, names
and catalogues and only uses Foundation; `Sources/CoolReaderKit/Server` holds the server.

## En français

Cool Reader Server est un petit serveur maison façon Plex pour les mangas, BD, comics et livres : on lui indique
des dossiers, il reconnaît les séries, trouve affiches et résumés, et chaque membre lit les bibliothèques
qu'on lui ouvre, dans Cool Reader, un lecteur OPDS ou un navigateur. Gratuit, open source, sans compte ni
relais : vos livres restent chez vous.

## License

MIT — see [LICENSE](LICENSE).
