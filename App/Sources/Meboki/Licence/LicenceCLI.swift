#if DEBUG
import Foundation
import MebokiCore

/// DEBUG command-line helpers (`main.swift`): no window, no Accessibility, nothing written.
enum LicenceCLI {
    static func run(_ args: [String]) {
        if args.contains("--licence-status") {
            let e = LicenceManager.peek()
            print("entitlement: \(LicenceManager.describe(e))")
            if case .free(let reason) = e { print("reason: \(reason.message)") }
            if case .licensed(let i) = e {
                print("email: \(i.email)\nseats: \(i.seats)\nkid: \(i.kid)")
            }
        } else if let i = args.firstIndex(of: "--verify-licence") {
            let text = args.indices.contains(i + 1) ? args[i + 1] : ""
            switch LicenceKey.verify(text) {
            case .success(let info):
                print("valid\nemail: \(info.email)\ntype: \(info.type.rawValue)\nseats: \(info.seats)\nkid: \(info.kid)"
                    + "\nissued: \(info.issued)" + (info.expires.map { "\nexpires: \($0)" } ?? ""))
            case .failure(let error):
                print("invalid: \(error.message)")
            }
        }
        fflush(stdout)
    }
}
#endif
