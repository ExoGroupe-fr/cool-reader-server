import Foundation

/// The server's few words, in French or English, by the language the browser or reader asks for.
nonisolated struct Strings: Sendable {
    let language: String

    init(_ language: String) { self.language = language == "fr" ? "fr" : "en" }

    private static let table: [String: (fr: String, en: String)] = [
        "home": ("Accueil", "Home"),
        "libraries": ("Bibliothèques", "Libraries"),
        "members": ("Membres", "Members"),
        "devices": ("Appareils", "Devices"),
        "signOut": ("Se déconnecter", "Sign out"),
        "signIn": ("Se connecter", "Sign in"),
        "name": ("Nom", "Name"),
        "password": ("Mot de passe", "Password"),
        "passwordAgain": ("Encore le mot de passe", "Password again"),
        "setupTitle": ("Bienvenue", "Welcome"),
        "setupIntro": ("Créez le compte admin. Le code à six chiffres est dans les journaux du serveur (docker logs) ou dans l'appli Mac.",
                       "Create the admin account. The six-digit code is in the server's logs (docker logs) or in the Mac app."),
        "setupCode": ("Code d'installation", "Setup code"),
        "createAdmin": ("Créer le compte admin", "Create the admin account"),
        "wrongSetupCode": ("Ce n'est pas le code affiché par le serveur.", "That isn't the code the server shows."),
        "passwordsDiffer": ("Les deux mots de passe sont différents.", "The two passwords differ."),
        "passwordTooShort": ("Le mot de passe doit faire au moins 8 caractères.", "The password needs at least 8 characters."),
        "nameTaken": ("Ce nom est déjà pris.", "That name is taken."),
        "nameMissing": ("Il manque le nom.", "The name is missing."),
        "addLibrary": ("Ajouter une bibliothèque", "Add a library"),
        "libraryHint": ("Un dossier du serveur : /libraries/Mangas dans Docker, ou /Users/vous/Mangas sur un Mac. Il est lu, jamais modifié.",
                        "A folder on the server: /libraries/Mangas in Docker, or /Users/you/Mangas on a Mac. It is read, never changed."),
        "folder": ("Dossier", "Folder"),
        "add": ("Ajouter", "Add"),
        "remove": ("Retirer", "Remove"),
        "scanNow": ("Scanner maintenant", "Scan now"),
        "scanning": ("Scan en cours…", "Scanning…"),
        "lastScan": ("Dernier scan", "Last scan"),
        "never": ("jamais", "never"),
        "unreachable": ("Dossier injoignable : ses livres sont gardés.", "Folder unreachable: its books are kept."),
        "folderMissing": ("Ce dossier n'existe pas sur le serveur.", "That folder doesn't exist on the server."),
        "noLibraries": ("Aucune bibliothèque pour l'instant.", "No library yet."),
        "noSeries": ("Rien ici pour l'instant : le scan trouve les livres en quelques secondes.", "Nothing here yet: a scan finds the books in seconds."),
        "addMember": ("Ajouter un membre", "Add a member"),
        "admin": ("admin", "admin"),
        "member": ("membre", "member"),
        "allLibraries": ("Toutes, y compris les prochaines", "All, the next ones too"),
        "save": ("Enregistrer", "Save"),
        "newPassword": ("Nouveau mot de passe", "New password"),
        "change": ("Changer", "Change"),
        "delete": ("Supprimer", "Delete"),
        "pairDevice": ("Jumeler un appareil", "Pair a device"),
        "pairIntro": ("Pour un membre sans mot de passe : dans Cool Reader, « Se connecter avec un code » affiche six chiffres. Tapez-les ici et choisissez le membre.",
                      "For a member without a password: in Cool Reader, “Sign in with a code” shows six digits. Type them here and pick the member."),
        "code": ("Code", "Code"),
        "for": ("Pour", "For"),
        "approve": ("Jumeler", "Pair"),
        "unknownCode": ("Aucun appareil n'attend ce code. Il expire au bout de 10 minutes.", "No device waits with that code. It expires after 10 minutes."),
        "device": ("Appareil", "Device"),
        "lastSeen": ("Vu", "Seen"),
        "revoke": ("Révoquer", "Revoke"),
        "noDevices": ("Aucun appareil jumelé.", "No paired device."),
        "recent": ("Ajouts récents", "Recently added"),
        "download": ("Télécharger", "Download"),
        "pages": ("pages", "pages"),
        "matching": ("Recherche des affiches et résumés…", "Looking up posters and synopses…"),
        "unmatched": ("Pas trouvée dans les catalogues", "Not found in the catalogues"),
        "saved": ("Enregistré.", "Saved."),
        "opdsHint": ("Lecteurs OPDS (Panels, Chunky, KOReader…) : ajoutez", "OPDS readers (Panels, Chunky, KOReader…): add"),
        "opdsHint2": ("avec votre nom et votre mot de passe.", "with your name and password."),
        "unreadable": ("illisible", "unreadable"),
        "finished": ("Terminé", "Finished"),
        "ongoing": ("En cours", "Ongoing"),
        "upcoming": ("À paraître", "Upcoming"),
        "cancelled": ("Annulé", "Cancelled"),
        "hiatus": ("En pause", "On hiatus"),
        "server": ("Serveur", "Server"),
        "serverName": ("Nom du serveur", "Server name"),
        "serverNameHint": ("Le nom que Cool Reader affiche.", "The name Cool Reader shows."),
        "homeAddresses": ("Adresses à la maison", "Home addresses"),
        "noAddress": ("Adresse inconnue : ouvrez cette page avec l'adresse du serveur sur le réseau, pas localhost.",
                      "Address unknown: open this page with the server's address on the network, not localhost."),
        "certificate": ("Certificat", "Certificate"),
        "certificateHint": ("Cool Reader chiffre ses connexions avec ce certificat, créé par le serveur. L'appli retient son empreinte et refuse de se connecter si elle change.",
                            "Cool Reader encrypts its connections with this certificate, which the server made. The app remembers its fingerprint and refuses to connect if it changes."),
        "invitation": ("Invitation", "Invitation"),
        "inviteStep1": ("Installez Cool Reader sur l'iPhone ou l'iPad :", "Install Cool Reader on the iPhone or iPad:"),
        "inviteStep2": ("Visez ce code avec l'appareil photo, ou ouvrez le lien sur l'appareil.", "Point the camera at this code, or open the link on the device."),
        "inviteStep3": ("Cool Reader s'ouvre et se connecte au serveur.", "Cool Reader opens and connects to the server."),
        "link": ("Lien", "Link"),
        "copyLink": ("Copier le lien", "Copy the link"),
        "share": ("Partager…", "Share…"),
        "done": ("Terminé", "Done"),
        "inviteOnce": ("Ce lien ne sera plus affiché : envoyez-le maintenant, par Messages ou e-mail.",
                       "This link won't be shown again: send it now, by Messages or email."),
        "inviteAddresses": ("Adresses dans le lien :", "Addresses in the link:"),
        "inviteDevice": ("Inviter un appareil", "Invite a device"),
        "openInvitations": ("Invitations en attente", "Waiting invitations"),
        "expires": ("expire", "expires"),
        "cancel": ("Annuler", "Cancel"),
        "addAndInvite": ("Ajouter", "Add"),
        "passwordOptional": ("Mot de passe", "Password"),
        "passwordOptionalHint": ("Avec son nom et ce mot de passe, le membre se connecte dans Cool Reader, sur ce site et dans les lecteurs OPDS. Sans mot de passe, il n'entre que par le lien d'invitation qui s'affiche ensuite.",
                                 "With their name and this password, the member signs in in Cool Reader, on this site and in OPDS readers. Without a password, they only get in through the invitation link shown next."),
        "inviteWithPassword": ("Ou plus simple : dans Cool Reader, Ajouter › Serveur Cool Reader…, ce serveur, puis son nom et son mot de passe.",
                               "Or simpler: in Cool Reader, Add › Cool Reader Server…, this server, then their name and password."),
        "inviteOwnPassword": ("Ou plus simple : dans Cool Reader, Ajouter › Serveur Cool Reader…, ce serveur, puis votre nom et votre mot de passe.",
                              "Or simpler: in Cool Reader, Add › Cool Reader Server…, this server, then your name and password."),
        "addMyDevice": ("Ajouter un de mes appareils", "Add one of my devices"),
        "addMyDeviceIntro": ("Un code QR à viser avec l'iPhone ou l'iPad, valable une demi-heure.",
                             "A QR code to scan with the iPhone or iPad, valid for half an hour."),
        "showQRCode": ("Afficher le code QR", "Show the QR code"),
        "appOnly": ("appli seulement", "app only"),
        "continueReading": ("Reprendre la lecture", "Continue reading"),
        "seeAll": ("Tout voir", "See all"),
        "yourLibraries": ("Vos bibliothèques", "Your libraries"),
        "upNext": ("À suivre", "Up next"),
        "markSeriesRead": ("Marquer la série comme lue", "Mark the series as read"),
        "markSeriesUnread": ("Marquer la série comme non lue", "Mark the series as unread"),
        "filterAll": ("Toutes", "All"),
        "filterUnread": ("Pas commencées", "Not started"),
        "filterReading": ("En cours", "In progress"),
        "filterFinished": ("Lues", "Read"),
        "allGenres": ("Tous les genres", "All genres"),
        "fixMatch": ("Corriger l'appariement…", "Fix the match…"),
        "editSeries": ("Modifier le titre et le résumé", "Edit the title and synopsis"),
        "rematch": ("Relancer l'appariement automatique", "Match automatically again"),
        "unmatch": ("Ne garder aucune métadonnée", "Keep no metadata"),
        "searchCatalogues": ("Chercher dans les catalogues", "Search the catalogues"),
        "noCandidates": ("Aucun résultat dans les catalogues.", "No result in the catalogues."),
        "customTitle": ("Titre", "Title"),
        "customSummary": ("Résumé", "Synopsis"),
        "customHint": ("Laissez un champ vide pour reprendre celui des catalogues.", "Leave a field empty to take the catalogues' back."),
        "manualMatch": ("Choisie à la main", "Chosen by hand"),
        "ignoredMatch": ("Aucune métadonnée, par votre choix.", "No metadata, as you chose."),
        "notMatched": ("Aucun catalogue n'a reconnu cette série.", "No catalogue recognised this series."),
        "matchedOn": ("Reconnue sur", "Recognised on"),
        "choose": ("Choisir", "Choose"),
        "chosen": ("Choisie", "Chosen"),
        "justAdded": ("Ajouté récemment", "Just added"),
        "seeSeries": ("Voir la série", "See the series"),
        "summaryFrom": ("Résumé :", "Synopsis:"),
        "catalogues": ("Catalogues", "Catalogues"),
        "comicVineIntro": ("Pour les comics : une clé Comic Vine gratuite (comicvine.gamespot.com/api) donne leur résumé et la couverture de chaque numéro. Sans clé, Comic Vine n'est jamais interrogé.",
                           "For comics: a free Comic Vine key (comicvine.gamespot.com/api) brings their synopsis and each issue's cover. Without a key, Comic Vine is never asked."),
        "comicVineKey": ("Clé Comic Vine", "Comic Vine key"),
        "comicVineKeyKept": ("Une clé est enregistrée : laissez le champ vide pour la garder.", "A key is saved: leave the field empty to keep it."),
        "comicVineRemove": ("Retirer la clé", "Remove the key"),
        "administration": ("Administration", "Administration"),
        "manageLibraries": ("Gérer les bibliothèques", "Manage libraries"),
        "read": ("Lire", "Read"),
        "resume": ("Reprendre", "Resume"),
        "readAgain": ("Relire depuis le début", "Read again"),
        "readBadge": ("Lu", "Read"),
        "markRead": ("Marquer comme lu", "Mark as read"),
        "markUnread": ("Marquer comme non lu", "Mark as unread"),
        "search": ("Rechercher", "Search"),
        "searchPlaceholder": ("Rechercher une série", "Search for a series"),
        "noResults": ("Aucune série ne correspond.", "No series matches."),
        "sortTitle": ("Titre", "Title"),
        "textBooksHint": ("Les romans se lisent dans Cool Reader, ou après les avoir téléchargés.",
                          "Novels are read in Cool Reader, or after downloading them."),
        "endOfBook": ("Fin du tome.", "The end of this book."),
        "nextBook": ("À suivre", "Next"),
        "backToSeries": ("Retour à la série", "Back to the series"),
        "previousPage": ("Page précédente", "Previous page"),
        "nextPage": ("Page suivante", "Next page"),
        "menu": ("Afficher ou masquer les commandes", "Show or hide the controls"),
        "fullScreen": ("Plein écran", "Full screen"),
        "remoteAccess": ("Accès à distance", "Remote access"),
        "remoteIntro": ("Pour lire hors de chez vous sans VPN : le serveur demande à votre box d'ouvrir son port (UPnP ou NAT-PMP) et met son adresse publique dans les invitations. Tout reste chiffré en HTTPS, rien ne passe par un service tiers.",
                        "To read away from home without a VPN: the server asks your router to open its port (UPnP or NAT-PMP) and puts its public address in invitations. Everything stays encrypted over HTTPS, and nothing goes through a third party."),
        "remoteEnable": ("Ouvrir le port sur la box automatiquement", "Open the port on the router automatically"),
        "remotePort": ("Port sur la box (facultatif)", "Port on the router (optional)"),
        "remoteHost": ("Adresse ou nom public, si vous avez ouvert le port vous-même", "Public address or name, if you opened the port yourself"),
        "duckDNSDomain": ("Nom DuckDNS, si l'adresse de la box change (gratuit sur duckdns.org)", "DuckDNS name, if the router's address changes (free at duckdns.org)"),
        "duckDNSToken": ("Jeton DuckDNS", "DuckDNS token"),
        "duckDNSTokenKept": ("Laissez le jeton vide pour garder celui qui est enregistré.", "Leave the token empty to keep the saved one."),
        "remoteInvitationsHint": ("Les appareils déjà connectés apprennent l'adresse publique à leur prochaine connexion à la maison.",
                                  "Devices already connected learn the public address the next time they connect at home."),
        "badPort": ("Le port doit être un nombre de 1 à 65535.", "The port must be a number from 1 to 65535."),
        "badDuckDNS": ("Ce n'est pas un nom DuckDNS : juste « monserveur » ou « monserveur.duckdns.org ».",
                       "That isn't a DuckDNS name: just “myserver” or “myserver.duckdns.org”."),
        "duckDNSTokenMissing": ("Il manque le jeton DuckDNS : il est en haut de la page de votre compte sur duckdns.org.",
                                "The DuckDNS token is missing: it's at the top of your account page on duckdns.org."),
    ]

    subscript(_ key: String) -> String {
        guard let entry = Self.table[key] else { return key }
        return language == "fr" ? entry.fr : entry.en
    }

    /// Genres are stored in English, as AniList and Open Library give them.
    func genre(_ genre: String) -> String {
        guard language == "fr" else { return genre }
        let french = ["Adventure": "Aventure", "Comedy": "Comédie", "Drama": "Drame", "Horror": "Horreur", "Mahou Shoujo": "Magical girl",
                      "Music": "Musique", "Mystery": "Mystère", "Psychological": "Psychologique", "Sci-Fi": "Science-fiction",
                      "Science fiction": "Science-fiction", "Slice of Life": "Tranche de vie", "Sports": "Sport",
                      "Supernatural": "Surnaturel", "Comics": "BD", "Children": "Jeunesse", "Humor": "Humour", "History": "Histoire",
                      "Philosophy": "Philosophie", "Psychology": "Psychologie", "Biography": "Biographie", "Education": "Éducation",
                      "Science": "Sciences"]
        return french[genre] ?? genre
    }

    func seriesCount(_ count: Int) -> String {
        language == "fr" ? (count == 1 ? "1 série" : "\(count) séries") : (count == 1 ? "1 series" : "\(count) series")
    }

    func bookCount(_ count: Int, kind: UnitKind) -> String {
        let words: (String, String) = switch (language, kind) {
        case ("fr", .volume): ("tome", "tomes")
        case ("fr", .chapter): ("chapitre", "chapitres")
        case ("fr", .issue): ("numéro", "numéros")
        case ("fr", .book): ("livre", "livres")
        case (_, .volume): ("volume", "volumes")
        case (_, .chapter): ("chapter", "chapters")
        case (_, .issue): ("issue", "issues")
        case (_, .book): ("book", "books")
        }
        return "\(count) " + (count == 1 ? words.0 : words.1)
    }

    /// "Tome 3 · Le titre", "Volume 3", or the book's own name.
    func bookTitle(_ book: BookRecord, kind: UnitKind) -> String {
        guard let number = book.number, kind != .book else { return book.extraTitle ?? book.plainName }
        let label: String = switch (language, kind) {
        case ("fr", .chapter): "Chapitre"
        case ("fr", .issue): "Numéro"
        case ("fr", _): "Tome"
        case (_, .chapter): "Chapter"
        case (_, .issue): "Issue"
        default: "Volume"
        }
        let base = "\(label) \(FileNameParser.formatNumber(number))"
        if let extra = book.extraTitle, !extra.isEmpty { return "\(base) · \(extra)" }
        return base
    }

    func date(_ date: Date?) -> String {
        guard let date else { return self["never"] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == "fr" ? "fr_FR" : "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func searchTitle(_ text: String) -> String {
        language == "fr" ? "Résultats pour « \(text) »" : "Results for \u{201C}\(text)\u{201D}"
    }

    func matchPageTitle(_ series: String) -> String {
        language == "fr" ? "Métadonnées de « \(series) »" : "Metadata of \u{201C}\(series)\u{201D}"
    }

    func pageOf(_ page: Int, _ count: Int) -> String {
        language == "fr" ? "page \(page) sur \(count)" : "page \(page) of \(count)"
    }

    func unreadCount(_ count: Int) -> String {
        language == "fr" ? (count == 1 ? "1 non lu" : "\(count) non lus") : "\(count) unread"
    }

    func invitationTitle(_ member: String?) -> String {
        guard let member else { return language == "fr" ? "Ajouter un appareil" : "Add a device" }
        return language == "fr" ? "Invitation pour \(member)" : "Invitation for \(member)"
    }

    func invitationValidity(_ until: Date) -> String {
        language == "fr" ? "Valable jusqu'au \(date(until)), pour un seul appareil." : "Valid until \(date(until)), for one device."
    }

    /// What the admin sends a member: where to get the app, then the link.
    func invitationMessage(server: String, appStore: String, link: String) -> String {
        language == "fr"
            ? "Voici une invitation pour lire les livres de « \(server) » avec Cool Reader.\n1. Installe Cool Reader : \(appStore)\n2. Ouvre ce lien sur ton iPhone ou iPad : \(link)"
            : "Here's an invitation to read the books on \u{201C}\(server)\u{201D} with Cool Reader.\n1. Install Cool Reader: \(appStore)\n2. Open this link on your iPhone or iPad: \(link)"
    }

    /// Where remote access stands, in a sentence for the admin.
    func remoteStatus(_ status: RemoteAccessStatus, port: Int) -> String {
        let fr = language == "fr"
        let external = status.externalPort ?? port
        let local = status.localAddress.map { "\($0):\(port)" } ?? (fr ? "ce serveur" : "this server")
        let address = status.publicHost ?? status.publicAddress ?? "?"
        var sentence: String
        switch (status.state, status.problem) {
        case (.off, _):
            sentence = fr ? "Fermé : le serveur n'est joignable qu'à la maison, ou par un VPN." : "Off: the server is only reachable at home, or through a VPN."
        case (.working, _):
            sentence = fr ? "Ouverture du port sur la box…" : "Opening the port on the router…"
        case (.open, _):
            let method = status.method ?? "UPnP"
            sentence = fr ? "Ouvert : la box envoie le port \(external) vers \(local) (\(method)). Adresse publique : \(address)."
                          : "Open: the router forwards port \(external) to \(local) (\(method)). Public address: \(address)."
        case (.manual, _):
            sentence = fr ? "Adresse publique : \(address). Le port \(external) doit être ouvert sur la box vers \(local)."
                          : "Public address: \(address). Port \(external) must be forwarded on the router to \(local)."
        case (.failed, .noGateway):
            sentence = fr ? "Box introuvable : ce serveur ne voit pas de routeur sur son réseau. Avec Docker, il faut le réseau « host »."
                          : "No router found: this server sees no gateway on its network. With Docker, use the host network."
        case (.failed, .sharedAddress):
            let shared = status.publicAddress.map { " (\($0))" } ?? ""
            sentence = fr ? "Votre box n'a pas d'adresse publique à elle\(shared) : votre opérateur la partage (CGNAT), ou une autre box est devant. L'accès direct est impossible : demandez une adresse IPv4 dédiée à votre opérateur (c'est souvent gratuit), ou utilisez un VPN comme Tailscale."
                          : "Your router has no public address of its own\(shared): your provider shares it (CGNAT), or another router sits in front. Direct access is impossible: ask your provider for a dedicated IPv4 address (often free), or use a VPN such as Tailscale."
        case (.failed, .portTaken):
            sentence = fr ? "Le port \(external) est déjà ouvert vers un autre appareil sur la box : choisissez un autre port ci-dessous."
                          : "Port \(external) is already forwarded to another device on the router: choose another port below."
        case (.failed, .routerRefused):
            sentence = fr ? "La box a refusé d'ouvrir le port. Ouvrez vous-même le port \(external) (TCP) vers \(local), puis indiquez votre adresse publique ci-dessous."
                          : "The router refused to open the port. Forward port \(external) (TCP) to \(local) yourself, then give your public address below."
        case (.failed, _):
            sentence = fr ? "La box ne répond ni en UPnP ni en NAT-PMP. Activez l'UPnP dans ses réglages, ou ouvrez vous-même le port \(external) (TCP) vers \(local) et indiquez votre adresse publique ci-dessous."
                          : "The router answers neither UPnP nor NAT-PMP. Turn on UPnP in its settings, or forward port \(external) (TCP) to \(local) yourself and give your public address below."
        }
        if status.problem == .duckDNSFailed {
            sentence += fr ? " DuckDNS a refusé la mise à jour : vérifiez le nom et le jeton." : " DuckDNS refused the update: check the name and the token."
        }
        return sentence
    }

    func size(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        let formatted = megabytes >= 100 ? String(format: "%.0f", megabytes) : String(format: "%.1f", megabytes)
        return (language == "fr" ? formatted.replacingOccurrences(of: ".", with: ",") + " Mo" : formatted + " MB")
    }
}
