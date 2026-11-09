import AppKit
import CoreAudio
import Foundation

struct DiscoveredClient {
    let id: String
    let name: String
    let bundleID: String?
    let url: URL?
    var objects: [UInt32]
    var bundleIDs: Set<String>
    var running: Bool
    var devices: Set<UInt32>
    let reason: String?
}

/// Stateless read-only HAL discovery of outputs and audio clients.
@MainActor
enum CoreAudioDiscovery {
    static func outputs() throws -> [AudioOutputSnapshot] {
        let selected = try? AudioHAL.uint(AudioHAL.system, kAudioHardwarePropertyDefaultOutputDevice)
        return try AudioHAL.objects(AudioHAL.system, kAudioHardwarePropertyDevices).compactMap { device in
            guard !AudioHAL.isPrivateAggregate(device),
                  (try? AudioHAL.uint(device, kAudioDevicePropertyDeviceIsAlive)) == 1,
                  CoreAudioBackendLogic.isOfferedAsOutput(device, selected: selected,
                      canBeDefault: try? AudioHAL.uint(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput)),
                  let channels = try? AudioHAL.channels(device, scope: kAudioObjectPropertyScopeOutput),
                  channels.contains(where: { $0 > 0 }),
                  let uid = try? AudioHAL.string(device, kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(AudioHAL.internalDeviceUIDPrefix),
                  let name = try? AudioHAL.string(device, kAudioObjectPropertyName) else { return nil }
            let (volume, muted) = levels(device: device)
            let iconURL = (try? AudioHAL.cf(device, kAudioDevicePropertyIcon)) as? URL
            let streams = (try? AudioHAL.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)) ?? []
            let terminals = streams.compactMap { try? AudioHAL.uint($0, kAudioStreamPropertyTerminalType) }
            let identity = AudioOutputIdentity.resolve(name: name,
                modelUID: try? AudioHAL.string(device, kAudioDevicePropertyModelUID),
                modelName: try? AudioHAL.string(device, kAudioObjectPropertyModelName),
                manufacturer: try? AudioHAL.string(device, kAudioObjectPropertyManufacturer),
                transportType: (try? AudioHAL.uint(device, kAudioDevicePropertyTransportType)) ?? 0,
                outputTerminalTypes: terminals)
            return AudioOutputSnapshot(id: device, uid: uid, name: name, volume: volume, muted: muted,
                                       iconURL: iconURL?.isFileURL == true ? iconURL : nil, identity: identity)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func levels(device: UInt32) -> (volume: Double?, muted: Bool?) {
        let muted = AudioHAL.settable(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
            ? (try? AudioHAL.uint(device, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)).map { $0 != 0 } : nil
        return (OutputVolumeControl.discover(device: device)?.volume, muted)
    }

    static func clients(_ objects: [UInt32]) -> [DiscoveredClient] {
        var grouped: [String: DiscoveredClient] = [:]
        let ownID = Bundle.main.bundleIdentifier
        for object in objects {
            guard let pidValue = try? AudioHAL.uint(object, kAudioProcessPropertyPID), pidValue > 1,
                  pidValue <= UInt32(Int32.max), Int32(pidValue) != getpid() else { continue }
            let pid = Int32(pidValue)
            let bundleID = try? AudioHAL.string(object, kAudioProcessPropertyBundleID)
            let application = AudioApplicationIdentity.resolve(pid: pid, audioBundleID: bundleID)
            if let application, application.id == ownID { continue }
            let running = (try? AudioHAL.uint(object, kAudioProcessPropertyIsRunningOutput)) == 1
            let devices = Set((try? AudioHAL.objects(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)) ?? [])
            let id: String, name: String, reason: String?
            if let application {
                id = application.id; name = application.name; reason = nil
            } else {
                // No guessed parent, such as Terminal for a player started from it. Background
                // daemons outside an app don't get a row.
                guard running, getuid() == processUID(pid),
                      let path = AudioApplicationIdentity.executablePath(pid: pid) else { continue }
                let executable = URL(fileURLWithPath: path)
                if AudioApplicationIdentity.isWebKitGPUProcess(executable: executable, audioBundleID: bundleID) {
                    id = "unattributed:webkit-gpu"
                    name = "Web content (Safari, Mail…)"
                    reason = "Web audio plays through a shared system process, so it can’t be adjusted yet. Its sound is unchanged."
                } else {
                    guard !AudioApplicationIdentity.isSystemServiceExecutable(executable) else { continue }
                    id = "unattributed:\(pid)"
                    name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? executable.lastPathComponent
                    reason = "Can’t adjust this app. Its sound is unchanged."
                }
            }
            if var existing = grouped[id] {
                existing.objects.append(object); existing.running = existing.running || running
                existing.devices.formUnion(devices)
                if let bundleID, !bundleID.isEmpty { existing.bundleIDs.insert(bundleID) }
                grouped[id] = existing
            } else {
                grouped[id] = DiscoveredClient(id: id, name: name, bundleID: application?.id, url: application?.url,
                    objects: [object], bundleIDs: Set([bundleID].compactMap { $0 }.filter { !$0.isEmpty }),
                    running: running, devices: devices, reason: reason)
            }
        }
        return grouped.values.map { value in
            var result = value; result.objects.sort(); return result
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func processUID(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return info.pbi_uid
    }
}
