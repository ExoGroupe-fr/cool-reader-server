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
        "pairIntro": ("Dans Cool Reader, choisissez ce serveur : l'app affiche six chiffres. Tapez-les ici et choisissez le membre.",
                      "In Cool Reader, pick this server: the app shows six digits. Type them here and pick the member."),
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

    func size(_ bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        let formatted = megabytes >= 100 ? String(format: "%.0f", megabytes) : String(format: "%.1f", megabytes)
        return (language == "fr" ? formatted.replacingOccurrences(of: ".", with: ",") + " Mo" : formatted + " MB")
    }
}
