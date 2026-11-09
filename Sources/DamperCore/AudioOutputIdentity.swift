import CoreAudio
import Foundation

/// Presentation hints from public Core Audio metadata, independent of the device's display name.
public enum AudioOutputIdentity: Equatable, Sendable, CaseIterable {
    case airPods, airPodsPro, airPodsMax
    case headphones, builtInSpeakers, usbAudio, display, airPlay, speakers, unknown

    public var symbolName: String {
        switch self {
        case .airPods: "airpods"
        case .airPodsPro: "airpodspro"
        case .airPodsMax: "airpodsmax"
        case .headphones: "headphones"
        case .builtInSpeakers: "speaker.wave.2"
        case .usbAudio: "cable.connector"
        case .display: "display"
        case .airPlay: "airplayaudio"
        case .speakers, .unknown: "hifispeaker"
        }
    }

    /// Product/headphone metadata is more useful than a driver's generic speaker icon.
    /// Other classes can keep a device-supplied image, using symbolName as their fallback.
    public var prefersSymbol: Bool {
        switch self {
        case .airPods, .airPodsPro, .airPodsMax, .headphones: true
        default: false
        }
    }

    static func resolve(name: String, modelUID: String? = nil,
                        modelName: String? = nil, manufacturer: String? = nil,
                        transportType: UInt32 = kAudioDeviceTransportTypeUnknown,
                        outputTerminalTypes: [UInt32] = []) -> AudioOutputIdentity {
        let bluetooth = transportType == kAudioDeviceTransportTypeBluetooth ||
            transportType == kAudioDeviceTransportTypeBluetoothLE
        let personalAudioTransport = bluetooth || transportType == kAudioDeviceTransportTypeUSB

        // ModelName survives renaming, and ModelUID may hold a readable product name. The SDK says
        // a device UID is opaque, so it isn't read for hints here.
        if personalAudioTransport {
            for model in [modelName, modelUID].compactMap({ $0 }) {
                if let product = airPodsProduct(in: model) { return product }
            }
        }

        // A precise product hint outranks the generic headphone terminal. AirPods
        // currently expose an opaque numeric ModelUID and this generic terminal.
        // A known non-Apple manufacturer prevents an AirPods name from overriding it.
        if bluetooth {
            let maker = tokens(manufacturer ?? "")
            if maker.isEmpty || maker.first == "apple", let product = airPodsProduct(in: name) { return product }
        }

        // Terminal types describe hardware function without relying on a translated name.
        if outputTerminalTypes.contains(kAudioStreamTerminalTypeHeadphones) { return .headphones }
        if transportType == kAudioDeviceTransportTypeHDMI || transportType == kAudioDeviceTransportTypeDisplayPort ||
            outputTerminalTypes.contains(kAudioStreamTerminalTypeHDMI) ||
            outputTerminalTypes.contains(kAudioStreamTerminalTypeDisplayPort) { return .display }
        if transportType == kAudioDeviceTransportTypeAirPlay { return .airPlay }

        // Some Bluetooth drivers expose only a generic model. Name hints are a last
        // resort on that transport and cannot identify a completely renamed accessory.
        if bluetooth {
            let words = tokens(name)
            if words.contains("headphones") || words.contains("headset") || words.contains("earbuds") { return .headphones }
        }

        if transportType == kAudioDeviceTransportTypeBuiltIn { return .builtInSpeakers }
        if outputTerminalTypes.contains(kAudioStreamTerminalTypeSpeaker) ||
            outputTerminalTypes.contains(kAudioStreamTerminalTypeLFESpeaker) { return .speakers }
        if transportType == kAudioDeviceTransportTypeUSB || transportType == kAudioDeviceTransportTypeThunderbolt ||
            transportType == kAudioDeviceTransportTypeFireWire { return .usbAudio }
        return .unknown
    }

    private static func airPodsProduct(in text: String) -> AudioOutputIdentity? {
        let words = tokens(text)
        for (index, word) in words.enumerated() {
            if matchesIdentifier(word, prefix: "airpodspro") { return .airPodsPro }
            if matchesIdentifier(word, prefix: "airpodsmax") { return .airPodsMax }
            if matchesIdentifier(word, prefix: "airpods") {
                let next = words.dropFirst(index + 1).first
                if next == "pro" { return .airPodsPro }
                if next == "max" { return .airPodsMax }
                return .airPods
            }
        }
        return nil
    }

    private static func matchesIdentifier(_ word: String, prefix: String) -> Bool {
        guard word.hasPrefix(prefix) else { return false }
        return word.dropFirst(prefix.count).allSatisfy(\.isNumber)
    }

    /// Besides punctuation and spaces, a word also ends where ASCII and non-ASCII letters meet,
    /// because CJK possessives have no space before the product name: 太郎のAirPods.
    private static func tokens(_ value: String) -> [String] {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var words: [String] = [], word = ""
        for character in folded {
            guard character.isLetter || character.isNumber else {
                if !word.isEmpty { words.append(word); word = "" }
                continue
            }
            if let last = word.last, last.isLetter, character.isLetter, last.isASCII != character.isASCII {
                words.append(word); word = ""
            }
            word.append(character)
        }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
