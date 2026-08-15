// crispctl — command-line DDC control for external displays.
//
// Shares the exact DDC stack the Crisp app uses (DDCService + DDCServiceMatcher):
// IOKit-only DDC/CI over the DCPAVServiceProxy I2C bus. No private frameworks.
//
//   crispctl list                 enumerate external displays + their DDC values
//   crispctl get <feature> [id]   read one feature (brightness|contrast|volume|input|power)
//   crispctl set <feature> <v> [id] [--force]  write one feature (monitor units, usually 0-100)
//   crispctl capabilities [id]    read the monitor's capabilities string (VCP 0xF3)
//   crispctl watch [id]           poll brightness every 2s until interrupted
//
// Display IDs are the 1-based indices from `crispctl list`; omit to target the
// only external display (fails if there is more than one).
//
// `set` is the only command that changes anything, and the codes `DDCFeatureRegistry`
// marks destructive (0x60, 0xD6, 0x04, 0x0C, 0x14, 0x8D, 0xCA) need `--force` or an
// answered prompt — see `confirmDestructive`.

import Foundation
import CoreGraphics
import IOKit

@main
struct CrispCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first ?? "help" {
            case "list": try list()
            case "get": try get(args)
            case "set": try set(args)
            case "capabilities", "caps": try capabilities(args)
            case "watch": try watch(args)
            case "help", "-h", "--help": help()
            default:
                print("unknown command: \(args[0])")
                help()
                exit(2)
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    // MARK: - Helpers

    struct ExtDisplay {
        let index: Int
        let displayID: CGDirectDisplayID
        let vendor: UInt32
        let product: UInt32
        let serial: UInt32
    }

    static func externalDisplays() -> [ExtDisplay] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        var result: [ExtDisplay] = []
        var idx = 1
        for id in ids where CGDisplayIsBuiltin(id) == 0 {
            result.append(ExtDisplay(
                index: idx, displayID: id,
                vendor: CGDisplayVendorNumber(id),
                product: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id)))
            idx += 1
        }
        return result
    }

    static func targetDisplay(_ args: [String], argPos: Int) throws -> ExtDisplay {
        let displays = externalDisplays()
        guard !displays.isEmpty else { throw CLIError("no external display connected") }
        if displays.count == 1, args.count <= argPos {
            return displays[0]
        }
        guard let pos = Int(args[argPos]), displays.indices.contains(pos - 1) else {
            throw CLIError("specify a display index (1-\(displays.count)) from `crispctl list`")
        }
        return displays[pos - 1]
    }

    struct CLIError: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { message = m }
        var description: String { message }
    }

    static func featureCode(_ name: String) throws -> UInt8 {
        switch name.lowercased() {
        case "brightness": return 0x10
        case "contrast": return 0x12
        case "volume": return 0x62
        case "input", "input-source": return 0x60
        case "power": return 0xD6
        case "red", "gain-red": return 0x6C
        case "green", "gain-green": return 0x6D
        case "blue", "gain-blue": return 0x6E
        default:
            if let v = UInt8(name.replacingOccurrences(of: "0x", with: ""), radix: 16) { return v }
            throw CLIError("unknown feature '\(name)' (brightness|contrast|volume|input|power|red|green|blue)")
        }
    }

    static func featureName(_ code: UInt8) -> String {
        switch code {
        case 0x10: return "brightness"
        case 0x12: return "contrast"
        case 0x60: return "input-source"
        case 0x62: return "volume"
        case 0xD6: return "power"
        default: return String(format: "0x%02X", code)
        }
    }

    /// Run a DDCService async call and block until its completion fires.
    static func runAsync<T>(_ start: (@escaping (T) -> Void) -> Void) -> T? {
        let sem = DispatchSemaphore(value: 0)
        var result: T?
        start { r in result = r; sem.signal() }
        sem.wait()
        return result
    }

    // MARK: - Commands

    static func list() throws {
        let displays = externalDisplays()
        guard !displays.isEmpty else {
            print("no external display connected")
            return
        }
        for d in displays {
            print("[\(d.index)] displayID=\(d.displayID) vendor=0x\(String(format: "%04X", d.vendor)) product=0x\(String(format: "%04X", d.product)) serial=\(d.serial)")
            for code in [UInt8(0x10), 0x12, 0x60, 0x62] {
                let name = featureName(code)
                if let r = runAsync({ cb in DDCService.shared.readAsync(displayID: d.displayID, command: code, completion: cb) }),
                   let v = r {
                    print("    \(name): \(v.current)/\(v.max)")
                } else {
                    print("    \(name): (unavailable)")
                }
            }
        }
    }

    static func get(_ args: [String]) throws {
        guard args.count >= 2 else { throw CLIError("usage: crispctl get <feature> [id]") }
        let code = try featureCode(args[1])
        let d = try targetDisplay(args, argPos: 2)
        guard let r = runAsync({ cb in DDCService.shared.readAsync(displayID: d.displayID, command: code, completion: cb) }),
              let v = r else {
            throw CLIError("read failed (display unplugged or feature unsupported)")
        }
        print("\(featureName(code)): \(v.current)/\(v.max)")
    }

    static func set(_ args: [String]) throws {
        var args = args
        // Flags are stripped before the positional parse so `--force` may sit
        // anywhere, including after the display index.
        let forced = args.contains("--force") || args.contains("-f")
        args.removeAll { $0 == "--force" || $0 == "-f" }

        guard args.count >= 3 else { throw CLIError("usage: crispctl set <feature> <value> [id] [--force]") }
        let code = try featureCode(args[1])
        guard let value = UInt16(args[2]) else { throw CLIError("invalid value '\(args[2])'") }
        let d = try targetDisplay(args, argPos: 3)
        try confirmDestructive(code: code, value: value, forced: forced)
        let ok = runAsync({ cb in DDCService.shared.writeAsync(displayID: d.displayID, command: code, value: value, completion: cb) })
        if ok == true {
            print("set \(featureName(code)) = \(value) on display [\(d.index)]")
        } else {
            throw CLIError("write failed (display unplugged?)")
        }
    }

    /// The CLI's half of the app's write gate: a destructive VCP code is not
    /// written until the person at the keyboard has seen what it does.
    ///
    /// `DDCFeatureRegistry` is linked into `crispctl` (see `project.yml`) and
    /// already carries `destructive` and `hazard` per code, so the CLI has no
    /// business writing 0xD6 value 5 — which powers the panel off at a stage many
    /// monitors cannot be woken from over DDC — as casually as it writes
    /// brightness. This is not the app's `DDCFeatureDiscovery` gate: there is no
    /// quirks database, no probe history and no confirmation dialog out here, and
    /// a CLI whose whole purpose is measuring uncharted monitors must not refuse
    /// unproven codes. What it owes the user is the hazard and a deliberate
    /// second step.
    ///
    /// Interactive shells get a y/N prompt; anything scripted (stdin not a TTY,
    /// which is also every CI job) has to say `--force`, because a prompt nobody
    /// can answer would otherwise hang or silently proceed.
    ///
    /// Read paths — `get`, `list`, `capabilities`, `watch` — never come here.
    static func confirmDestructive(code: UInt8, value: UInt16, forced: Bool) throws {
        guard let spec = DDCFeatureRegistry.feature(forVCP: code), spec.destructive else { return }
        if forced { return }

        let hazard = spec.hazard ?? "Writing this code can leave the monitor in a state the Mac cannot undo."
        FileHandle.standardError.write(Data("""
        \(spec.vcpText) \(spec.title) is a destructive write.
        \(hazard)
        about to write: \(featureName(code)) = \(value)

        """.utf8))

        guard isatty(FileHandle.standardInput.fileDescriptor) == 1 else {
            throw CLIError("refusing to write VCP \(spec.vcpText) without --force")
        }
        print("continue? [y/N] ", terminator: "")
        let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else {
            throw CLIError("cancelled; nothing was written")
        }
    }

    /// Reads the monitor's capabilities string (DDC/CI command 0xF3).
    ///
    /// Read-only: 0xF3 asks the monitor to describe itself and changes nothing.
    /// It prints the raw string verbatim before anything else, because the raw
    /// string is the evidence — every tolerance rule in `DDCCapabilities` came
    /// from someone posting one of these from a monitor that broke a parser, and
    /// a tool that only prints its own reading of the string cannot produce the
    /// next one of those.
    static func capabilities(_ args: [String]) throws {
        let d = try targetDisplay(args, argPos: 1)
        guard let caps = runAsync({ (cb: @escaping (DDCCapabilities?) -> Void) in
            DDCService.shared.readCapabilitiesAsync(displayID: d.displayID, completion: cb)
        }) ?? nil else {
            throw CLIError("the monitor did not answer the capabilities request (many implement VCP reads and not 0xF3)")
        }

        print("raw:")
        print(caps.raw)
        print("")
        print("validity: \(caps.validity.rawValue)")
        if let model = caps.model { print("model: \(model)") }
        if let type = caps.monitorType { print("type: \(type)") }
        if let mccs = caps.mccsVersion { print("mccs_ver: \(mccs)") }
        if !caps.commands.isEmpty {
            print("cmds: \(caps.commands.map { String(format: "0x%02X", $0) }.joined(separator: " "))")
        }
        print("vcp (\(caps.features.count) codes):")
        for feature in caps.features {
            // Codes Crisp has no registry entry for are the majority on a real
            // monitor (this BenQ advertises 50 and the registry knows 11 of
            // them), and saying so is more useful than repeating the number.
            let name = DDCFeatureRegistry.feature(forVCP: feature.code)?.title ?? "(not in Crisp's registry)"
            let values = feature.values.isEmpty
                ? ""
                : " values: " + feature.values.map(\.codeText).joined(separator: " ")
            print("    \(feature.codeText) \(name)\(values)")
        }
        for segment in caps.unknownSegments {
            print("unsupported field kept: \(segment.name)(\(segment.value))")
        }
        for note in caps.diagnostics {
            print("note: \(note)")
        }
    }

    static func watch(_ args: [String]) throws {
        let d = try targetDisplay(args, argPos: 1)
        print("watching brightness on display [\(d.index)] ... (ctrl-c to stop)")
        while true {
            if let r = runAsync({ cb in DDCService.shared.readAsync(displayID: d.displayID, command: 0x10, completion: cb) }),
               let v = r {
                let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                print("\(stamp) brightness: \(v.current)/\(v.max)")
            }
            Thread.sleep(forTimeInterval: 2.0)
        }
    }

    static func help() {
        print("""
        crispctl — DDC control for external displays

        usage:
          crispctl list                 enumerate external displays + DDC values
          crispctl get <feature> [id]   read a feature
          crispctl set <feature> <v> [id] [--force]  write a feature (monitor units, usually 0-100)
          crispctl capabilities [id]    read the capabilities string (VCP 0xF3, read-only)
          crispctl watch [id]           poll brightness until interrupted

        features: brightness | contrast | volume | input | power | red | green | blue
        ids are the 1-based indices from `crispctl list` (omit when only one display).

        --force  proceed with a write the registry marks destructive (0x60 input,
                 0xD6 power, 0x04 factory reset, 0x0C/0x14 colour, 0x8D blank,
                 0xCA OSD lock). Without it crispctl prints the hazard and asks
                 first — and refuses outright when stdin is not a terminal, so a
                 script can never lose the screen by accident.
        """)
    }
}
