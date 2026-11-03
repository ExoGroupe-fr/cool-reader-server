import Foundation

/// The app's words, in French or English: the first of the Mac's preferred languages that is one of them, else
/// English.
enum Strings {
    static let isFrench: Bool = {
        for identifier in Locale.preferredLanguages {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "fr": return true
            case "en": return false
            default: continue
            }
        }
        return false
    }()

    private static let table: [String: (fr: String, en: String)] = [
        "starting": ("Démarrage…", "Starting…"),
        "stopped": ("Arrêté", "Stopped"),
        "retry": ("Réessayer", "Try Again"),
        "setupCode": ("Code d'installation", "Setup code"),
        "setupHint": ("Créez le compte admin dans le navigateur : la page demande ce code.",
                      "Create the admin account in your browser: the page asks for this code."),
        "createAdmin": ("Créer le compte admin…", "Create the Admin Account…"),
        "noLibrary": ("Aucune bibliothèque pour l'instant : ajoutez un dossier de mangas, BD ou livres.",
                      "No library yet: add a folder of manga, comics or books."),
        "scanning": ("Scan en cours…", "Scanning…"),
        "homeAddress": ("Adresse à la maison", "Home network address"),
        "copyAddress": ("Copier l'adresse", "Copy the address"),
        "copied": ("Copiée", "Copied"),
        "openAdmin": ("Ouvrir l'administration", "Open Administration"),
        "addFolder": ("Ajouter un dossier…", "Add a Folder…"),
        "openAtLogin": ("Ouvrir au démarrage du Mac", "Open at Login"),
        "showInDock": ("Afficher dans le Dock", "Show in Dock"),
        "openInBrowser": ("Ouvrir dans le navigateur", "Open in Browser"),
        "allowLogin": ("Autoriser dans Réglages Système…", "Allow in System Settings…"),
        "showLog": ("Afficher le journal", "Show Log"),
        "showData": ("Afficher le dossier des données", "Show Data Folder"),
        "quit": ("Quitter", "Quit"),
        "choosePrompt": ("Ajouter", "Add"),
        "chooseMessage": ("Choisissez un dossier de mangas, BD ou livres. Il est lu, jamais modifié.",
                          "Choose a folder of manga, comics or books. It is read, never changed."),
    ]

    static subscript(_ key: String) -> String {
        guard let entry = table[key] else { return key }
        return isFrench ? entry.fr : entry.en
    }

    static func running(port: Int) -> String {
        isFrench ? "En marche · port \(port)" : "Running · port \(port)"
    }

    static func portInUse(_ port: Int) -> String {
        isFrench ? "Le port \(port) est déjà utilisé, sans doute par un autre Cool Reader Server. Quittez-le, puis réessayez."
            : "Port \(port) is already in use, probably by another Cool Reader Server. Quit it, then try again."
    }

    static func startFailed(_ detail: String) -> String {
        isFrench ? "Le serveur n'a pas pu démarrer : \(detail)" : "The server couldn't start: \(detail)"
    }

    /// "2 bibliothèques · 14 séries · 230 livres": French counts 0 and 1 in the singular, English only 1.
    static func summary(libraries: Int, series: Int, books: Int) -> String {
        [count(libraries, fr: ("bibliothèque", "bibliothèques"), en: ("library", "libraries")),
         count(series, fr: ("série", "séries"), en: ("series", "series")),
         count(books, fr: ("livre", "livres"), en: ("book", "books"))].joined(separator: " · ")
    }

    private static func count(_ number: Int, fr: (String, String), en: (String, String)) -> String {
        let word = isFrench ? (number < 2 ? fr.0 : fr.1) : (number == 1 ? en.0 : en.1)
        return "\(number.formatted()) \(word)"
    }

    static func added(_ name: String) -> String {
        isFrench ? "Bibliothèque « \(name) » ajoutée." : "Library “\(name)” added."
    }

    static func alreadyAdded(_ name: String) -> String {
        isFrench ? "« \(name) » est déjà une bibliothèque." : "“\(name)” is already a library."
    }

    static func addFailed(_ name: String, _ detail: String) -> String {
        isFrench ? "« \(name) » n'a pas pu être ajoutée : \(detail)" : "“\(name)” couldn't be added: \(detail)"
    }

    static func loginItemFailed(_ detail: String) -> String {
        isFrench ? "L'ouverture au démarrage n'a pas pu changer : \(detail)" : "Open at Login couldn't change: \(detail)"
    }
}
