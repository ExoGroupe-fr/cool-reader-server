# Cool Reader Server API

What Cool Reader (and any other client) uses. Version 1: `apiVersion` in `/api/v1/server`.

## Connecting

- **One port, two protocols.** The server answers HTTP and HTTPS on the same port (7272 by default).
- **Plain HTTP is for the home network only.** That covers private, link-local and 100.64/10 addresses, the last
  for Tailscale and the like. From anywhere else:
  - GET and HEAD are redirected to HTTPS;
  - everything else gets 403.
- **The certificate is the server's own, made at its first start.**
  - No authority vouches for it: clients pin its **fingerprint**, the SHA-256 of the certificate in DER, in
    lowercase hex.
  - An invitation link carries the fingerprint.
  - A device that pairs with a code records it at its first connection.
  - A client must refuse a server whose certificate has another fingerprint.
- **Calls carry a device token**: `Authorization: Bearer <token>`.
  - OPDS readers send Basic credentials (member name and password).
  - The web pages use a cookie.
- **Bodies and dates.** Bodies are JSON in UTF-8. Dates are ISO 8601: the server writes them without fractions of a
  second, and accepts them with or without.
- **Errors** are `{"error": "A sentence."}` with the status:
  - 400: the JSON doesn't fit;
  - 401: no or wrong credentials;
  - 404: not found, or not visible to this member;
  - 410: an invitation that's used or expired;
  - 429: too many wrong attempts, so wait a quarter of an hour.

### Finding a server

- **Bonjour.** The server advertises `_coolreader._tcp` with TXT records:
  - `id`, the server's id, which stays the same when its address changes;
  - `v`, its version;
  - `api`, the API version.
- **Invitation link**, as a QR code in the web admin or sent by message:

  ```
  coolreader://connect?s=<server id>&n=<server name>&a=<host:port>,<host:port>&fp=<fingerprint>&i=<invitation secret>
  ```

  - `a` lists the addresses to try, best first: home network, then public.
  - IPv6 hosts are bracketed: `[fd00::2]:7272`.
- **By hand**: an address and port.

### Signing a device in

- **With an invitation** (two days, or half an hour for an admin's own device; one device):
  - `POST /api/v1/invitations/redeem` with `{"invitation": "<secret>", "device": "Léa's iPad"}`
  - → `200 {"token": "…", "user": {"id": 2, "name": "Léa", "isAdmin": false}}`
  - or 410 when the invitation is used or expired.
- **With a code**, approved in the web admin's Devices page:
  1. `POST /api/v1/pair` with `{"device": "Léa's iPad"}` → `{"id": "…", "code": "482715", "expiresIn": 600}`. The device
     shows the code.
  2. `GET /api/v1/pair/<id>`, every two seconds or so:
     - `{"status": "pending"}`, then once `{"status": "approved", "token": "…", "user": {…}}`;
     - 404 once the request has expired or the token was collected.
- **With a password**:
  - `POST /api/v1/login` with `{"name": "…", "password": "…", "device": "…"}` → `{"token": "…", "user": {…}}`.
  - Members invited without a password can't use this.
- **Signing out:** `POST /api/v1/logout` revokes the calling device's token. An admin can revoke any device from the
  web admin; the token then gets 401.

The token doesn't expire. Keep it in the Keychain.

## Server

| Call | Answer |
|---|---|
| `GET /api/v1/server` (no token) | `{"name", "id", "version", "apiVersion", "setupRequired", "fingerprint"}` |
| `GET /api/v1/server/addresses` | `{"addresses": ["192.168.1.10:7272", "example.duckdns.org:7272"]}`, home network first, then the public ones when remote access works |
| `GET /api/v1/me` | `{"id", "name", "isAdmin"}` |

## Libraries, series and books

A member sees the libraries the admin gave them; anything else answers 404.

| Call | Answer |
|---|---|
| `GET /api/v1/libraries` | `[LibraryInfo]` |
| `GET /api/v1/libraries/<id>/contents` | `{"library": LibraryInfo, "series": [SeriesInfo], "books": [BookInfo]}`, with an `ETag`: send it back in `If-None-Match` to get a bodiless 304 when nothing changed. The books come without progress. |
| `GET /api/v1/libraries/<id>/series` | `[SeriesInfo]` |
| `GET /api/v1/search?q=<text>` | `[SeriesInfo]` whose title, folder, authors or genres (in English or in the request's language) hold the text |
| `GET /api/v1/upnext` | `[{"book": BookInfo, "series": SeriesInfo}]`: in each series the member has finished a book of, the next one not begun, the series read last first |
| `GET /api/v1/series/<id>` | `{"series": SeriesInfo, "books": [BookInfo]}`, books with progress |
| `GET /api/v1/series/<id>/cover`, `/banner` | an image |
| `GET /api/v1/books/<id>` | `BookInfo` with progress |
| `GET /api/v1/books/<id>/file` | the file; `Range: bytes=<start>-` resumes a download (206) |
| `GET /api/v1/books/<id>/cover` | an image, a JPEG of at most 600 px where the server can shrink it |
| `GET /api/v1/books/<id>/pages/<index>?width=<px>` | one page of a comic or a PDF, as an image; `width` from 200 to 4000 |

**LibraryInfo:**

```json
{"id": 2, "name": "BD", "seriesCount": 14, "bookCount": 96}
```

**SeriesInfo:**

```json
{"id": 3, "libraryID": 2, "title": "Blacksad", "folderTitle": "Blacksad", "kind": "volume",
 "summary": "…", "summarySource": null, "summaryURL": null, "authors": ["Juan Díaz Canales"], "genres": ["Mystery"], "year": 2000, "status": "finished",
 "matchStatus": "matched", "source": "appleBooks", "anilistID": null, "bookCount": 6,
 "coverURL": "/api/v1/series/3/cover", "bannerURL": null, "addedAt": "2026-11-03T12:00:00Z"}
```

| Field | Values |
|---|---|
| `kind` | `volume`, `chapter`, `issue` or `book` |
| `status` | `finished`, `ongoing`, `upcoming`, `cancelled` or `hiatus` |
| `genres` | in English |
| `matchStatus` | `pending`, `matched`, `unmatched`, `manual` (chosen by the admin) or `ignored` |
| `source` | `anilist`, `mangadex`, `appleBooks`, `openLibrary`, `comicVine` or `wikipedia` |
| `summarySource`, `summaryURL` | `wikipedia` and the article's address when the synopsis comes from Wikipedia: show both, the text is under CC BY-SA |

**BookInfo:**

```json
{"id": 4, "seriesID": 3, "fileName": "Blacksad 01.cbz", "format": "cbz", "size": 52428800, "number": 1,
 "title": null, "pageCount": 52, "isText": false, "isRightToLeft": false,
 "coverURL": "/api/v1/books/4/cover", "fileURL": "/api/v1/books/4/file", "progress": ProgressInfo or null}
```

| Field | Values |
|---|---|
| `format` | `cbz`, `cbr`, `cb7`, `cbt`, `epub` or `pdf` |
| `isText` | true for a novel, an EPUB without page images |
| `title` | a volume's extra title, or the book's name when it has no number |

## Reading progress

Per member, for every device they use.

**`PUT /api/v1/books/<id>/progress`**

```json
{"page": 12, "finished": false, "position": "<the app's own position in a text book>", "fraction": 0.25,
 "updatedAt": "2026-11-03T10:00:00Z"}
```

- `page` is required; the rest is optional. For a comic or a PDF, `page` is the index of the page shown, from 0, and
  the server keeps it within the book. For a text book it's the client's own count, kept as it is.
- `updatedAt` is when it was read, and defaults to now. The server keeps the newer of what it has and what it gets,
  so a device that read offline can send its progress later.
- The answer is the stored `ProgressInfo`.

**`POST /api/v1/series/<id>/read`** with `{"read": true}` marks every book of the series read at its last page, or unread
with `false`, as of now; the answer is `{"series": SeriesInfo, "books": [BookInfo]}` with the new progress.

**`GET /api/v1/progress?since=<date>`**

- The member's progress changed after that date, oldest first.
- Without `since`, it returns all of it.

**ProgressInfo:**

```json
{"bookID": 4, "page": 12, "finished": false, "position": "…", "fraction": 0.25, "updatedAt": "2026-11-03T10:00:00Z"}
```

## Administration

For Cool Reader signed in as an admin, what the web admin does, as Plex's apps do. Every call needs an admin's
token; a member gets 403. Bodies left without a field keep what is there.

### Libraries

| Call | Answer |
|---|---|
| `GET /api/v1/admin/libraries` | `[AdminLibrary]` |
| `POST /api/v1/admin/libraries` with `{"name": "BD", "path": "/libraries/BD"}` | `AdminLibrary`, scanned at once; 400 when the folder isn't on the server or is a library already |
| `POST /api/v1/admin/libraries/<id>/scan` | `{"status": "scanning"}` |
| `DELETE /api/v1/admin/libraries/<id>` | `{"status": "removed"}`: the server forgets it, the folder stays as it is |

**AdminLibrary:** `{"id", "name", "path", "seriesCount", "bookCount", "lastScanAt", "lastError"}`, `lastError` being
`unreachable` when the folder couldn't be read (its books are kept).

### Members, invitations, devices

| Call | Answer |
|---|---|
| `GET /api/v1/admin/members` | `[Member]` |
| `POST /api/v1/admin/members` with `{"name", "password"?, "allLibraries"?, "libraryIDs"?}` | `{"member": Member, "invitation": Invitation}`; without a password the member only gets in with the invitation |
| `PATCH /api/v1/admin/members/<id>` with `{"allLibraries"?, "libraryIDs"?, "password"?}` | `Member`; an admin's libraries don't change |
| `DELETE /api/v1/admin/members/<id>` | `{"status": "removed"}`; 403 for the admin |
| `POST /api/v1/admin/members/<id>/invitations` | `Invitation`: two days for a member, half an hour for the admin's own device |
| `GET /api/v1/admin/invitations` | `[Invitation]` still open, without their link (only its hash is kept) |
| `DELETE /api/v1/admin/invitations/<id>` | `{"status": "removed"}` |
| `GET /api/v1/admin/devices` | `[{"id", "memberID", "memberName", "name", "kind", "createdAt", "lastSeenAt"}]` |
| `DELETE /api/v1/admin/devices/<id>` | `{"status": "revoked"}`: its token gets 401 |
| `POST /api/v1/admin/pairings/approve` with `{"code": "482715", "memberID": 2}` | `{"device": "Léa's iPad"}`, the device of `POST /api/v1/pair`; 404 for a code no device shows |

**Member:** `{"id", "name", "isAdmin", "allLibraries", "libraryIDs", "hasPassword"}`.
**Invitation:** `{"id", "memberID", "memberName", "link", "expiresAt"}`, `link` being the `coolreader://connect?…` link,
given once when it is made.

### Server

- `GET /api/v1/admin/server` → `{"name", "version", "addresses", "allowDeletion", "comicVineKeySet", "scanning",
  "pendingMatches", "remoteAccess": {"enabled", "port", "host", "duckDNSDomain", "duckDNSTokenSet"}, "remoteStatus"}`,
  `remoteStatus` being where remote access stands (`state`: `off`, `working`, `open`, `manual` or `failed`, with
  `problem`, `publicAddress`, `externalPort`…).
- `PATCH /api/v1/admin/server` with `{"name"?, "allowDeletion"?, "comicVineKey"?, "remoteAccess"?: {"enabled"?, "port"?,
  "host"?, "duckDNSDomain"?, "duckDNSToken"?}}` → the same. `comicVineKey: ""` removes the key; in `remoteAccess`,
  `port: 0` and empty strings clear a field, and the token is only ever sent. 400 with the problem when a setting is wrong.

### A series' metadata

| Call | Answer |
|---|---|
| `GET /api/v1/admin/series/<id>/candidates?q=<text>` | `[{"source", "id", "title", "detail", "year", "coverURL", "summary"}]` from AniList, Apple Books, Open Library, Comic Vine (with a key) and Wikipedia; `q` is the series' title when left out |
| `POST /api/v1/admin/series/<id>/match` with `{"source": "appleBooks", "id": "ab:631320051"}` | `{"series": SeriesInfo, "books": [BookInfo]}`, matched by hand (`matchStatus` `manual`), which the matcher never redoes |
| `POST /api/v1/admin/series/<id>/rematch` | the same, the matcher asked again (`pending`) |
| `POST /api/v1/admin/series/<id>/unmatch` | the same, without metadata (`ignored`) |
| `PATCH /api/v1/admin/series/<id>` with `{"title"?, "summary"?}` | the same; the admin's title and synopsis win over the catalogues' and stay through a new match, `""` gives theirs back |

### Deleting books

Off until the admin turns it on (`allowDeletion`); the server otherwise only reads the libraries.

| Call | Answer |
|---|---|
| `DELETE /api/v1/admin/books/<id>` | `{"status": "deleted"}`: the file goes to the Mac's Trash, or elsewhere to a hidden `.cool-reader-trash` folder at the top of its library, and leaves the library; 403 while deleting is off, 409 when the file can't be moved (a read-only Docker folder) |
| `DELETE /api/v1/admin/series/<id>` | the same for every book of the series |

## OPDS

- The catalogue is at `/opds`, OPDS 1.2 with Page Streaming (PSE), for readers such as Panels, Chunky and KOReader.
- It signs in with Basic credentials: a member's name and password.
