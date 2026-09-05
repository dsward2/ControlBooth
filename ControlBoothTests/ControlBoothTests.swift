//
//  ControlBoothTests.swift
//  ControlBoothTests
//
//  Created by Douglas Ward on 7/4/26.
//

import Testing
@testable import ControlBooth

struct ControlBoothTests {

    @Test func controlPortDiscoversStageByBareName() async throws {
        let stages = [
            PipelineStage(path: "rtl_fm_localradio", arguments: ["-f", "101100000"]),
            PipelineStage(path: "PCMBinauralPanner", arguments: ["--rate", "48000", "--control-port", "7001"]),
            PipelineStage(path: "PCMUDPSender", arguments: ["--port", "6019"])
        ]
        #expect(stages.controlPort(forTool: "PCMBinauralPanner") == 7001)
        #expect(stages.controlPort(forTool: "PCMDistanceGain") == nil)
    }

    @Test func controlPortDiscoversStageByAbsolutePath() async throws {
        // A pipeline author can point a stage at an absolute path (ControlBooth
        // is unsandboxed, so this is a normal thing to do) rather than a bare
        // name resolved against Contents/Helpers — the lookup should still
        // match by the executable's last path component either way.
        let stages = [
            PipelineStage(path: "/opt/local/bin/nrsc5", arguments: []),
            PipelineStage(path: "/Applications/ControlBooth.app/Contents/Helpers/PCMDistanceGain",
                          arguments: ["--distance", "1.0", "--control-port", "7002"])
        ]
        #expect(stages.controlPort(forTool: "PCMDistanceGain") == 7002)
    }

    @Test func controlPortIsNilWithoutControlPortArgument() async throws {
        let stages = [PipelineStage(path: "PCMBinauralPanner", arguments: ["--azimuth", "90"])]
        #expect(stages.controlPort(forTool: "PCMBinauralPanner") == nil)
    }

    @Test func controlPortIgnoresDanglingFlagWithNoValue() async throws {
        // "--control-port" as the very last argument, with nothing after it —
        // shouldn't crash or read out of bounds.
        let stages = [PipelineStage(path: "PCMBinauralPanner", arguments: ["--control-port"])]
        #expect(stages.controlPort(forTool: "PCMBinauralPanner") == nil)
    }

    @Test func controlPortIgnoresNonNumericValue() async throws {
        let stages = [PipelineStage(path: "PCMBinauralPanner", arguments: ["--control-port", "not-a-port"])]
        #expect(stages.controlPort(forTool: "PCMBinauralPanner") == nil)
    }
}
