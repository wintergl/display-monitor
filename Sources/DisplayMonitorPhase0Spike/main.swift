import ApplicationServices
import DisplayMonitorCore
import Foundation

@main
struct DisplayMonitorPhase0Spike {
    static func main() {
        let arguments = Set(CommandLine.arguments.dropFirst())

        if arguments.contains("--status-item-lifecycle") {
            print("STATUS_ITEM_PROBE=UNAVAILABLE run the signed App bundle with --run-phase0-status-item")
            return
        }

        if arguments.contains("--accessibility-preflight") {
            print("AX_PREFLIGHT=\(AXIsProcessTrusted())")
            return
        }

        print("DisplayMonitorPhase0Spike")
        print("fixtureVersion=\(Phase0SpikeContract.fixtureVersion)")
        print("optionChordWindowMs=\(Phase0SpikeContract.optionChordWindowMilliseconds)")
        print("inputIterations=\(Phase0SpikeContract.minimumInputIterations)")
        print("scope=deterministic-contract-only; third-party-moves=false")
        print("statusItemProbe=use --run-phase0-status-item on the signed app bundle")
    }
}
