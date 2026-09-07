import Foundation
import AVFoundation
import Speech

// Standalone macOS 26+ file transcription probe; no microphone access.
@main
struct AppleTranscribe {
    static func main() async {
        do {
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ja-JP")) else {
                throw ProbeError.message("SpeechTranscriber Japanese is unavailable")
            }
            let transcriber = SpeechTranscriber(locale: locale,
                transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            if CommandLine.arguments.dropFirst().first == "--status" {
                let ready = await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier })
                let data = try JSONSerialization.data(withJSONObject: ["ready": ready, "locale": locale.identifier])
                FileHandle.standardOutput.write(data)
                return
            }
            if CommandLine.arguments.dropFirst().first == "--install" {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                print("Japanese speech assets ready")
                return
            }
            guard CommandLine.arguments.count == 2 else {
                throw ProbeError.message("usage: apple_transcribe <audio-file> | --install | --status")
            }
            guard await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier }) else {
                throw ProbeError.message("Install Japanese assets with --install before benchmarking")
            }
            let started = ProcessInfo.processInfo.systemUptime
            let audio: AVAudioFile
            do {
                // SpeechAnalyzer's file API consumes AVAudioFile directly. Do
                // not first materialize a whole audiobook as a second PCM file.
                audio = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
            } catch {
                // The adapter may retry with ffmpeg only for an input-opening
                // failure. Asset, model, and analysis failures must stay errors.
                FileHandle.standardError.write(Data("FUSHI_AUDIO_INPUT_UNSUPPORTED \(error)\n".utf8))
                exit(65)
            }
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            // stdout stays one JSON document for existing benchmark clients.
            // Tagged stderr lines report finalized audio progress to the UI.
            func progress(_ seconds: Double) {
                guard duration.isFinite, duration > 0, seconds.isFinite else { return }
                let data: [String: Any] = [
                    "processedMs": Int(max(0, min(seconds, duration)) * 1000),
                    "totalMs": Int(duration * 1000)
                ]
                if let json = try? JSONSerialization.data(withJSONObject: data),
                   let line = String(data: json, encoding: .utf8) {
                    FileHandle.standardError.write(Data(("FUSHI_PROGRESS " + line + "\n").utf8))
                }
            }
            progress(0)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let resultsTask = Task { () throws -> [[String: Any]] in
                var segments: [[String: Any]] = []
                for try await result in transcriber.results {
                    segments.append([
                        "start": CMTimeGetSeconds(result.range.start),
                        "end": CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)),
                        "text": String(result.text.characters)
                    ])
                    progress(CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)))
                }
                return segments
            }
            do {
                try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
                let segments = try await resultsTask.value
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                guard !segments.isEmpty else { throw ProbeError.message("No transcription results") }
                let output: [String: Any] = [
                    "engine": "apple-speechtranscriber", "locale": locale.identifier,
                    "audio_seconds": duration, "pipeline_seconds": elapsed,
                    "segments": segments
                ]
                let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
                FileHandle.standardOutput.write(json)
                print("")
            } catch {
                resultsTask.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
    enum ProbeError: Error { case message(String) }
}
