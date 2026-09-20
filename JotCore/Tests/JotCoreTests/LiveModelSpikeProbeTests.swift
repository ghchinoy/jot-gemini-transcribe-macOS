// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import XCTest
@testable import JotCore

/// End-to-end live WebSocket probe for AI Studio (`generativelanguage.googleapis.com`)
/// exercising the shipping `LiveTranscriptionSession` + `WebSocketTransport` + `PCMRing`
/// pipeline.
///
/// Opt in explicitly:
///   JOT_LIVE_PROBE=1 GEMINI_API_KEY=... JOT_PROBE_PCM=/path/to/16k_mono.pcm ./scripts/test.sh --filter LiveModelSpikeProbeTests
final class LiveModelSpikeProbeTests: XCTestCase {

    private func requireEnv() throws -> (apiKey: String, pcmData: Data) {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["JOT_LIVE_PROBE"] == "1", "Set JOT_LIVE_PROBE=1")
        let key = try XCTUnwrap(env["GEMINI_API_KEY"], "GEMINI_API_KEY required")
        let pcmPath = try XCTUnwrap(env["JOT_PROBE_PCM"], "JOT_PROBE_PCM required")
        let pcm = try Data(contentsOf: URL(fileURLWithPath: pcmPath))
        return (key, pcm)
    }

    func testShippingSwiftLiveSessionEndToEnd() async throws {
        let (apiKey, pcm) = try requireEnv()

        for smart in [true, false] {
            let t0 = Date()
            let transport = WebSocketTransport(apiKey: { apiKey })
            let setup = LiveSetup(
                model: GeminiConfig().liveModel,
                smart: smart,
                customVocabulary: ["JotCore", "Chinoy"]
            )
            let session = LiveTranscriptionSession(transport: transport, setup: setup)

            var observedPartials: [String] = []
            let partialTask = Task {
                for await p in session.partials {
                    observedPartials.append(p)
                }
            }

            try await session.start(setupTimeout: 5.0)
            let handshakeMs = Int(Date().timeIntervalSince(t0) * 1000)

            // Stream sub-100ms HAL-sized chunks (800 bytes = 25ms) to exercise
            // 100ms (3,200-byte) PCMRing coalescing and tail flush on finish().
            let chunkSize = 800
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + chunkSize, pcm.count)
                session.enqueue(pcm.subdata(in: offset..<end))
                offset = end
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            let finishStart = Date()
            let outcome = await session.finish(deadline: 6.0)
            let finishMs = Int(Date().timeIntervalSince(finishStart) * 1000)
            partialTask.cancel()

            let accepted = await session.acceptedBytes
            XCTAssertEqual(accepted, Int64(pcm.count), "every PCM byte must be accepted and reconciled")
            print("""
            [AIStudio Live Probe] smart=\(smart):
              - Handshake: \(handshakeMs)ms
              - Post-audio finish latency: \(finishMs)ms
              - Accepted bytes: \(accepted) / \(pcm.count)
              - Partials count: \(observedPartials.count)
              - Outcome: \(outcome)
            """)
            if case .completed(let text) = outcome {
                XCTAssertFalse(text.isEmpty)
            } else {
                XCTFail("Expected .completed for smart=\(smart), got \(outcome)")
            }
        }
    }
}
