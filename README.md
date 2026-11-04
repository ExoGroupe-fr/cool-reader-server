# Cool Reader Server

A small home server for comics, manga and ebooks, in the spirit of Plex: point it at your folders, drop files
in them, and it recognises the series, finds their posters and synopses, and lets the people you invite read
the libraries you choose — in [Cool Reader](https://apps.apple.com/app/cool-reader/id6829489019) on iPhone and
iPad, in any OPDS reader, or in a browser.

Free and open source (MIT). No account to create anywhere, no relay, nothing to pay: your books stay on your
machine and only reach the devices you pair.

> **Status: 0.1, young.** Everything below works and is tested, but it's new: keep backups of your config folder
> and report what breaks. Cool Reader connects to the server from its next version; until then, read in the
> browser or in an OPDS reader.

## What it does

- **Libraries** are folders on the server: `Mangas`, `BD`, `Romans`… It only reads them, unless you let admins
  delete books, which then go to the Trash.
- **Formats**: CBZ/ZIP, CBR/RAR (RAR 4 and 5, solid archives included), CB7/7z, CBT/TAR, EPUB, PDF — read by
  its own Swift decoders, the same as Cool Reader's.
- **Series, recognised like in the app**: a folder is a series ("Dragon Ball/Dragon Ball T03.cbz"), loose files
  are grouped by name, ComicInfo.xml and `.nfo` files come first. Manga are matched on AniList then MangaDex,
  books and BD on Apple Books then Open Library, each album by its title or its number: poster, banner, synopsis,
  authors, genres, volume covers. A series' own synopsis comes from Wikipedia in your language, and comics from
  Comic Vine with a free key of your own. Only series titles are sent to those catalogues.
- **Your hand on it**: an admin fixes a series' match from a search of the catalogues, or writes its title and
  synopsis; the matcher never redoes it.
- **Members** see the libraries you tick for them and keep their own reading progress, synced across their
  devices. A member can do without a password: an invitation is enough for Cool Reader.
- **Invitations**: a QR code to scan with the iPhone's camera, or a link to send by message. Cool Reader opens,
  connects and shows the libraries. Devices on the home network can also pair with a six-digit code.
- **HTTPS everywhere**, with a certificate the server makes itself and Cool Reader pins: no account, no
  certificate authority, no relay.
- **Remote access without a relay**: the server opens its port on your router (UPnP or NAT-PMP) and puts its
  public address in invitations; a free DuckDNS name follows an address that changes. A VPN such as Tailscale
  works too, and is never required.
- **Bonjour**: Cool Reader finds the server on the home network by itself.
- **In the browser**, in the spirit of Plex: a sidebar that goes from one library to the next, a home page that opens
  on what you're reading and shows each library with its covers, « À suivre » (the next volume of each series begun),
  what's new, search by title, author or genre, filters, and a reader for comics, manga and PDFs: two pages side by
  side on a wide screen, a vertical strip for webtoons, zoom, manga right to left, your page in step with Cool Reader.
- **Admin from Cool Reader**, as from Plex's apps: libraries, members, invitations, devices and settings, through
  the API in [docs/API.md](docs/API.md).
- **OPDS 1.2** with page streaming: Panels, Chunky, KOReader or any OPDS reader can browse, download and read
  page by page.

## Install

### Mac

Like Plex Media Server, a menu bar app runs the server on a Mac (macOS 14 or later). Download
**Cool Reader Server.app** from the [releases](https://github.com/ExoGroupe-fr/cool-reader-server/releases), put it in
Applications and open it: books appear in the menu bar, and the app in the Dock, where a click opens the site
(« Afficher dans le Dock » takes it out). The menu shows the setup code at the first start, the libraries and the
address to give your devices, and opens the admin pages. At its first start it offers to open with the Mac, and it
looks once a day for a new version, which its menu installs: signed by ExoGroupe and notarized by Apple, or not at
all. « Ajouter un dossier… » (or a folder dropped on
the app's icon) adds a library, and « Ouvrir au démarrage du Mac » keeps it running. Data goes in
`~/Library/Application Support/Cool Reader Server`, the log in `~/Library/Logs/Cool Reader Server.log`.

To build it yourself, with Xcode or its command line tools: `Scripts/build-mac-app.sh` writes
`build/Cool Reader Server.app` and a zip for a release. It signs ad hoc, for the Mac that built it; with
`DEVELOPER_ID` it signs with a Developer ID, and with `NOTARY_PROFILE` (a `notarytool` keychain profile) or an App
Store Connect API key (`NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER`) it has Apple notarize the app, so it opens on
any Mac.

### Docker (NAS, Linux, Raspberry Pi)

[`deploy/compose.yaml`](deploy/compose.yaml):

```yaml
services:
  cool-reader-server:
    image: ghcr.io/exogroupe-fr/cool-reader-server:latest
    network_mode: host                         # Bonjour and remote access need the host's network
    volumes:
      - ./config:/config                       # database, cache, certificate, setup code
      - /volume1/Mangas:/libraries/Mangas:ro   # read only
      - /volume1/BD:/libraries/BD:ro
    environment:
      COOLREADER_METADATA_LANGUAGE: fr         # language of synopses and editions
      COOLREADER_METADATA_COUNTRY: fr          # Apple Books store
    restart: unless-stopped
```

With Docker's own network instead of the host's, publish `7272:7272` and set `COOLREADER_ADDRESSES` to the
host's address (`192.168.1.10:7272`) so invitations carry it; Cool Reader then won't find the server by itself,
and remote access needs a port forwarded by hand. Unraid: [`deploy/unraid.xml`](deploy/unraid.xml).

### From the source (macOS or Linux)

```bash
swift run -c release cool-reader-server --config ~/CoolReaderServer --library Mangas=/Users/you/Mangas
```

## First start

1. The server prints a six-digit **setup code** in its logs (`docker logs cool-reader-server`), shows it in the
   Mac app and writes it to `config/setup-code.txt`.
2. Open `http://<server>:7272`, type the code and create the admin account.
3. Add libraries (in Docker, the folders you mounted under `/libraries`).
4. **Your iPhone or iPad**: Devices › « Afficher le code QR », and scan it with the camera.
5. **Someone else**: Members › add them with the libraries they may read, and send the invitation that appears
   (« Partager… » or « Copier le lien »). It works once, for two days.
6. OPDS readers: add `http://<server>:7272/opds` with a member's name and password.

## Reading away from home

On the Server page, turn on **remote access**: the server asks your router to forward its port, and shows the
public address it got. Invitations made afterwards carry that address, so Cool Reader reaches the server
anywhere, over HTTPS.

- **Your router doesn't answer** (UPnP off): turn on UPnP in its settings, or forward TCP port 7272 to the
  server yourself and type your public address or domain on the Server page.
- **Your address changes**: create a free name at [DuckDNS](https://www.duckdns.org) and give its sub-domain and
  token on the Server page; the server keeps it pointed at your home.
- **Your provider shares one address between customers** (CGNAT, common on 4G/5G boxes and some fibre offers):
  nothing can reach you directly. Ask your provider for a dedicated IPv4 address (often free), or use a VPN such
  as Tailscale on the server and your devices.
- **OPDS readers away from home** must use `https://`, and most refuse a certificate no authority signed. Use a
  VPN for them, or put the server behind a reverse proxy with a real certificate (Caddy, Traefik, Synology's).

## Settings

| Environment | Command line | Default |
| --- | --- | --- |
| `COOLREADER_CONFIG` | `--config` | `./config` (`/config` in Docker) |
| `COOLREADER_PORT` | `--port` | `7272` |
| `COOLREADER_HOST` | `--host` | `0.0.0.0` |
| `COOLREADER_NAME` | `--name` | `Cool Reader Server` |
| `COOLREADER_ADDRESSES` (comma-separated) | `--address host:port` (repeatable) | found by the server |
| `COOLREADER_METADATA_LANGUAGE` | `--metadata-language` | `en` |
| `COOLREADER_METADATA_COUNTRY` | `--metadata-country` | `us` |
| `COOLREADER_ONLINE_METADATA=0` | `--offline` | on |
| `COOLREADER_SCAN_INTERVAL` (minutes) | | `30` |
| | `--library Name=/path` (repeatable) | |

`cool-reader-server invite <member>` prints an invitation link, for servers without a browser at hand
(`docker exec cool-reader-server cool-reader-server invite Lea`).

## Security

HTTPS with a pinned certificate, plain HTTP refused from outside the home network, PBKDF2 passwords, one
revocable token per device, single-use invitations, read-only libraries. The details, and how to report a
vulnerability: [SECURITY.md](SECURITY.md).

## API

Cool Reader's calls are documented in [docs/API.md](docs/API.md), for anyone who wants to write another client.

## Roadmap

- Cool Reader also reads other OPDS catalogues (Komga, Kavita, Calibre-Web…).
- The shared core — formats, names, catalogues — becomes a Swift package that Cool Reader uses too.
- A Synology package, and a native Windows build if people ask for it.

## Building and testing

```bash
swift build
swift test
```

Swift 6.2 or later; SwiftNIO, swift-nio-ssl, swift-crypto and swift-certificates (Apple); SQLite. `Sources/CoolReaderKit/Core` holds the books, formats, names
and catalogues and only uses Foundation; `Sources/CoolReaderKit/Server` holds the server.

On Linux, libjpeg-turbo, libpng and libwebp shrink covers and pages, and Poppler draws PDF covers and pages; on
Ubuntu or Debian:

```bash
apt install libsqlite3-dev libturbojpeg0-dev libpng-dev libwebp-dev poppler-utils
```

On a Mac, `COOLREADER_SYSTEM_IMAGE_LIBS=1 swift test` builds and tests that Linux code too, with Homebrew's
`jpeg-turbo`, `libpng`, `webp` and `poppler`.

## En français

Cool Reader Server est un petit serveur maison façon Plex pour les mangas, BD, comics et livres : on lui indique
des dossiers, il reconnaît les séries, trouve affiches et résumés, et chaque membre lit les bibliothèques
qu'on lui ouvre, dans Cool Reader, un lecteur OPDS ou un navigateur. On invite quelqu'un avec un code QR ou un
lien, et on lit aussi hors de chez soi : le serveur ouvre lui-même le port de la box, en HTTPS. Gratuit, open
source, sans compte ni relais : vos livres restent chez vous. Sur Mac, une appli dans le Dock et la barre des menus ; ailleurs,
Docker.

## License

MIT — see [LICENSE](LICENSE).
