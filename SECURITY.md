# Security

Please report vulnerabilities privately through GitHub: **Security › Report a vulnerability** on this
repository. Don't open a public issue for them.

Say what an attacker can do, from where (the local network, the internet, a member's account), and how to
reproduce it. You'll get an answer within a week.

## How the server protects your books

- **Encryption.** The server makes its own certificate at its first start and answers HTTPS. No authority vouches
  for it; Cool Reader pins its fingerprint instead:
  - An **invitation** (link or QR code) carries the fingerprint, so the app trusts the right server from its very
    first connection, at home or away.
  - A device that **pairs with a code** on the home network trusts the certificate it sees the first time, as SSH
    does. Someone already in the middle of your home network at that moment could pass for the server.
    Invitations don't have this weakness.
  - After that, a server with another certificate is refused.
- **Plain HTTP stays at home.** From any address outside the home network, pages move to HTTPS and every other
  request is refused, so passwords and tokens never cross the internet in clear. "Home" means private, link-local
  and 100.64/10 addresses (Tailscale). A reverse proxy on the same machine or network counts as home: make it
  speak HTTPS to the outside.
- **Accounts and devices.**
  - The first account needs the setup code shown on the server.
  - Passwords are hashed with PBKDF2-HMAC-SHA256 (600,000 rounds). Wrong ones are throttled per address, so nobody
    can lock a member out from elsewhere.
  - Each device gets its own token. Only its SHA-256 is stored, and the admin revokes it in one click.
  - An invitation works once, for one device, within two days (half an hour for an admin's own device). Only its
    SHA-256 is stored.
- **Access.** Every request checks that the member may see the library. Files are served by id, never by path.
  Library folders are only read.
- **Web pages.** Forms from other sites are refused, the session cookie is HttpOnly and SameSite=Strict, and a
  strict content security policy applies.
- **Remote access is off until you turn it on.** It opens one port on your router, the server's.
