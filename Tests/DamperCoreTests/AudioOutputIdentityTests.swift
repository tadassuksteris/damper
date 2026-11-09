import AppKit
import CoreAudio
import Testing
@testable import DamperCore

@Test func outputIdentityUsesModelMetadataAfterAccessoryRename() {
    #expect(AudioOutputIdentity.resolve(name: "Alex’s listening buds", modelUID: "com.apple.audio.AirPodsPro2,1",
        manufacturer: "Apple Inc.", transportType: kAudioDeviceTransportTypeBluetooth) == .airPodsPro)
    #expect(AudioOutputIdentity.resolve(name: "Office headphones", modelName: "AirPods Max",
        transportType: kAudioDeviceTransportTypeUSB) == .airPodsMax)
    #expect(AudioOutputIdentity.resolve(name: "My buds", modelName: "AirPods 4",
        transportType: kAudioDeviceTransportTypeBluetoothLE) == .airPods)
    #expect(AudioOutputIdentity.resolve(name: "AirPods Max", modelName: "AirPods Pro",
        transportType: kAudioDeviceTransportTypeBluetooth) == .airPodsPro)
}

@Test func outputIdentityConservativelyFallsBackForGenericBluetoothModels() {
    #expect(AudioOutputIdentity.resolve(name: "AirPods Pro", modelUID: "2027 4c", modelName: "",
        manufacturer: "Apple Inc.", transportType: kAudioDeviceTransportTypeBluetooth,
        outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones]) == .airPodsPro)
    #expect(AudioOutputIdentity.resolve(name: "Alex’s AirPods Pro", modelUID: "Bluetooth Audio",
        manufacturer: "Apple Inc.", transportType: kAudioDeviceTransportTypeBluetooth) == .airPodsPro)
    #expect(AudioOutputIdentity.resolve(name: "AirPods Max", modelUID: "Bluetooth Audio",
        transportType: kAudioDeviceTransportTypeBluetooth) == .airPodsMax)
    #expect(AudioOutputIdentity.resolve(name: "JBL Charge", modelUID: "Bluetooth Audio",
        manufacturer: "JBL", transportType: kAudioDeviceTransportTypeBluetooth) == .unknown)
    #expect(AudioOutputIdentity.resolve(name: "My listening buds", modelUID: "Bluetooth Audio",
        outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones]) == .headphones)
    #expect(AudioOutputIdentity.resolve(name: "AirPods Pro", manufacturer: "JBL",
        transportType: kAudioDeviceTransportTypeBluetooth) == .unknown)
}

@Test func outputIdentityFindsAirPodsAfterACJKPossessiveWithNoSpace() {
    func identity(_ name: String) -> AudioOutputIdentity {
        AudioOutputIdentity.resolve(name: name, modelUID: "2027 4c", manufacturer: "Apple Inc.",
            transportType: kAudioDeviceTransportTypeBluetooth, outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones])
    }
    #expect(identity("太郎のAirPods Pro") == .airPodsPro)
    #expect(identity("太郎的AirPods Max") == .airPodsMax)
    #expect(identity("小明的AirPods") == .airPods)
    #expect(identity("태훈의 AirPods Pro") == .airPodsPro)
    #expect(identity("NotAirPodsPro") == .headphones)
    #expect(identity("1000xm5ヘッドホン") == .headphones)
}

@Test func outputIdentityDoesNotTreatArbitraryNamesAsProductIdentity() {
    #expect(AudioOutputIdentity.resolve(name: "AirPods Pro", transportType: kAudioDeviceTransportTypeVirtual) == .unknown)
    #expect(AudioOutputIdentity.resolve(name: "NotAirPodsPro", transportType: kAudioDeviceTransportTypeBluetooth) == .unknown)
    #expect(AudioOutputIdentity.resolve(name: "AirPodsProfessional", transportType: kAudioDeviceTransportTypeBluetooth) == .unknown)
}

@Test func outputIdentityUsesTerminalAndTransportMetadataForOtherOutputs() {
    #expect(AudioOutputIdentity.resolve(name: "External", transportType: kAudioDeviceTransportTypeUSB,
        outputTerminalTypes: [kAudioStreamTerminalTypeHeadphones]) == .headphones)
    #expect(AudioOutputIdentity.resolve(name: "Display Audio", transportType: kAudioDeviceTransportTypeHDMI) == .display)
    #expect(AudioOutputIdentity.resolve(name: "External", transportType: kAudioDeviceTransportTypeUSB) == .usbAudio)
    #expect(AudioOutputIdentity.resolve(name: "Living room", transportType: kAudioDeviceTransportTypeAirPlay) == .airPlay)
    #expect(AudioOutputIdentity.resolve(name: "Localized internal name", transportType: kAudioDeviceTransportTypeBuiltIn) == .builtInSpeakers)
    #expect(AudioOutputIdentity.resolve(name: "JBL Charge", transportType: kAudioDeviceTransportTypeBluetooth,
        outputTerminalTypes: [kAudioStreamTerminalTypeSpeaker]) == .speakers)
}

@MainActor @Test func outputIdentitySymbolsExistAndSpecificProductsOverrideGenericArtwork() {
    for identity in AudioOutputIdentity.allCases {
        #expect(NSImage(systemSymbolName: identity.symbolName, accessibilityDescription: nil) != nil)
    }
    #expect(AudioOutputIdentity.airPodsPro.prefersSymbol)
    #expect(AudioOutputIdentity.headphones.prefersSymbol)
    #expect(!AudioOutputIdentity.unknown.prefersSymbol)
}
