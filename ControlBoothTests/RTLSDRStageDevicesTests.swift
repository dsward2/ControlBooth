import Testing
@testable import ControlBooth

/// `PipelineRunner.rtlsdrDevices(in:)` decides which RTL-SDRs the start-time
/// preflight checks, so it must find every `-d` a librtlsdr tool will open —
/// and skip stages that don't open a local dongle.
@MainActor
struct RTLSDRStageDevicesTests {

    private func devices(_ stages: [PipelineStage]) -> [String] {
        PipelineRunner.rtlsdrDevices(in: stages)
    }

    @Test func rtlFmDeviceArgument() {
        #expect(devices([PipelineStage(path: "rtl_fm_localradio",
                                       arguments: ["-M", "fm", "-d", "00000360", "-f", "89100000"])])
                == ["00000360"])
    }

    @Test func missingDeviceMeansIndexZero() {
        #expect(devices([PipelineStage(path: "/opt/local/bin/rtl_fm", arguments: ["-f", "162400000"])]) == ["0"])
    }

    @Test func attachedGetoptForm() {
        #expect(devices([PipelineStage(path: "rtl_sdr", arguments: ["-d1", "-f", "100000000", "-"])]) == ["1"])
    }

    @Test func nonRTLStagesAreIgnored() {
        #expect(devices([PipelineStage(path: "sox", arguments: ["-d", "x"]),
                         PipelineStage(path: "PCMJitterBuffer", arguments: [])]).isEmpty)
    }

    @Test func rtl433SerialAndSoapyForms() {
        #expect(devices([PipelineStage(path: "rtl_433", arguments: ["-d", ":00000090"])]) == ["00000090"])
        #expect(devices([PipelineStage(path: "rtl_433", arguments: ["-d", "driver=hackrf"])]).isEmpty)
    }

    @Test func nrsc5FromNetworkOrFileOpensNoDongle() {
        #expect(devices([PipelineStage(path: "/opt/local/bin/nrsc5", arguments: ["-d", "1", "97.1", "0"])]) == ["1"])
        #expect(devices([PipelineStage(path: "nrsc5", arguments: ["-H", "127.0.0.1", "97.1", "0"])]).isEmpty)
        #expect(devices([PipelineStage(path: "nrsc5", arguments: ["-r", "capture.iq", "0"])]).isEmpty)
    }

    @Test func duplicatesCollapseInOrder() {
        #expect(devices([PipelineStage(path: "rtl_fm", arguments: ["-d", "2"]),
                         PipelineStage(path: "rtl_power", arguments: ["-d", "0"]),
                         PipelineStage(path: "rtl_fm", arguments: ["-d", "2"])]) == ["2", "0"])
    }
}
