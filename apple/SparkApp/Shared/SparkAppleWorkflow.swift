import Foundation

enum SparkAppleWorkflow: String, CaseIterable, Identifiable {
    case notes, contacts, maps, safari, photos, files, music, home, focus, clock, health, calls,
        weather
    var id: String { rawValue }
    var title: String {
        switch self {
        case .notes: String(localized: "Notes")
        case .contacts: String(localized: "Contacts")
        case .maps: String(localized: "Maps")
        case .safari: String(localized: "Safari")
        case .photos: String(localized: "Photos & Camera")
        case .files: String(localized: "Files")
        case .music: String(localized: "Music & Podcasts")
        case .home: String(localized: "Home")
        case .focus: String(localized: "Focus")
        case .clock: String(localized: "Clock")
        case .health: String(localized: "Health & Fitness")
        case .calls: String(localized: "Phone & FaceTime")
        case .weather: String(localized: "Weather")
        }
    }
    var symbol: String {
        switch self {
        case .notes: "note.text"
        case .contacts: "person.crop.rectangle"
        case .maps: "map"
        case .safari: "safari"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        case .music: "music.note"
        case .home: "house"
        case .focus: "moon"
        case .clock: "clock"
        case .health: "heart"
        case .calls: "phone"
        case .weather: "cloud.sun"
        }
    }
    var purpose: String {
        switch self {
        case .notes:
            String(
                localized:
                    "Use a Shortcut to create a note, append Spark output to a note, or supply selected note text to Ask Spark."
            )
        case .contacts:
            String(
                localized:
                    "Use a Shortcut to choose a contact and pass only the contact fields you want a later action to use."
            )
        case .maps:
            String(
                localized:
                    "Use a Shortcut to find a place or open directions from text you reviewed."
            )
        case .safari:
            String(
                localized:
                    "Use a Shortcut to supply selected webpage text to Spark or open a URL you reviewed."
            )
        case .photos:
            String(
                localized:
                    "Use a Shortcut to select photos or use Camera actions with the permissions on this device."
            )
        case .files:
            String(
                localized:
                    "Use a Shortcut to select a document, analyse a text file with Spark, or save an answer to a chosen folder."
            )
        case .music:
            String(
                localized:
                    "Use a Shortcut to find or play music and podcasts using the apps and accounts on this device."
            )
        case .home:
            String(
                localized:
                    "Use a Shortcut to run a Home scene or accessory action that you configured."
            )
        case .focus:
            String(
                localized:
                    "Use a Shortcut to change Focus or include Spark actions in your own Focus automation."
            )
        case .clock:
            String(
                localized:
                    "Use a Shortcut to start a timer or manage alarms using the Clock actions on this device."
            )
        case .health:
            String(
                localized:
                    "Use a Shortcut to choose the Health or Fitness actions and data you want to use, with their own permissions."
            )
        case .calls:
            String(
                localized:
                    "Use a Shortcut to choose a recipient and start a Phone or FaceTime call after reviewing the workflow."
            )
        case .weather:
            String(
                localized:
                    "Use a Shortcut to get a forecast and pass the weather text to Ask Spark for a plan or summary."
            )
        }
    }
}
