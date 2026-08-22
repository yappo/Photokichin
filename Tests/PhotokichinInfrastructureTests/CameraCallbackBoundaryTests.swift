import Foundation
import Testing
@testable import PhotokichinInfrastructure

@Suite("Camera callback boundaries")
struct CameraCallbackBoundaryTests {
    @Test("Download callback adapter is safe on an arbitrary queue")
    @MainActor
    func downloadCompletionHandlesQueueAndResultSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photokichin-camera-callback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let returnedURL = root.appendingPathComponent("returned.CR3")
        try Data("returned".utf8).write(to: returnedURL)
        let returnedResult = await downloadResult(
            directory: root,
            filename: "expected.CR3",
            expectedURL: root.appendingPathComponent("expected.CR3"),
            returnedFilename: "/camera/returned.CR3",
            outputURL: nil,
            error: nil
        )
        #expect(returnedResult.successURL == returnedURL.standardizedFileURL)

        let expectedURL = root.appendingPathComponent("expected-fallback.CR3")
        try Data("fallback".utf8).write(to: expectedURL)
        let fallbackResult = await downloadResult(
            directory: root,
            filename: expectedURL.lastPathComponent,
            expectedURL: expectedURL,
            returnedFilename: "/camera/not-reported-on-disk.CR3",
            outputURL: nil,
            error: nil
        )
        #expect(fallbackResult.successURL == expectedURL.standardizedFileURL)

        let reportedError = NSError(domain: "CameraCallbackTests", code: 17)
        let errorResult = await downloadResult(
            directory: root,
            filename: "error.CR3",
            expectedURL: root.appendingPathComponent("error.CR3"),
            returnedFilename: nil,
            outputURL: nil,
            error: reportedError
        )
        #expect(errorResult.error?.domain == reportedError.domain)
        #expect(errorResult.error?.code == reportedError.code)

        let missingResult = await downloadResult(
            directory: root,
            filename: "missing.CR3",
            expectedURL: root.appendingPathComponent("missing.CR3"),
            returnedFilename: nil,
            outputURL: nil,
            error: nil
        )
        #expect(missingResult.error?.domain == "Photokichin.Camera")
        #expect(missingResult.error?.code == 2)
    }

    @MainActor
    private func downloadResult(
        directory: URL,
        filename: String,
        expectedURL: URL,
        returnedFilename: String?,
        outputURL: URL?,
        error: Error?
    ) async -> (successURL: URL?, error: NSError?) {
        if let outputURL {
            try? Data("output".utf8).write(to: outputURL)
        }
        do {
            let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let callback = CameraCompletionAdapter.download(
                    directory: directory,
                    filename: filename,
                    expectedURL: expectedURL,
                    continuation: continuation
                )
                DispatchQueue.global(qos: .utility).async {
                    callback(returnedFilename, error)
                }
            }
            return (value.standardizedFileURL, nil)
        } catch let error as NSError {
            return (nil, error)
        } catch {
            return (nil, error as NSError)
        }
    }
}
