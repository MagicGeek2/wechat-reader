#!/usr/bin/env swift

import Foundation
import Vision
import ImageIO

private let maxImageBytes = 20 * 1024 * 1024
private let requestTimeout: TimeInterval = 45

struct OCRLine: Encodable {
    let text: String
    let confidence: Float
}

struct OCRSuccess: Encodable {
    let input: String
    let ok: Bool
    let text: String
    let lines: [OCRLine]
    let bytes: Int
    let elapsed_ms: Int
}

struct OCError: Encodable {
    let type: String
    let message: String
}

struct OCRFailure: Encodable {
    let input: String
    let ok: Bool
    let error: OCError
}

struct InputError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class SecureHTTPClient: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func fetch(_ url: URL) throws -> Data {
        guard url.scheme?.lowercased() == "https" else {
            throw InputError(message: "only https URLs are allowed; refusing insecure scheme")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("codex-vision-ocr/1.0", forHTTPHeaderField: "User-Agent")

        var received: Result<Data, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                received = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                received = .failure(InputError(message: "response was not HTTP"))
                return
            }
            guard (200...299).contains(http.statusCode) else {
                received = .failure(InputError(message: "HTTP status \(http.statusCode)"))
                return
            }
            guard let data else {
                received = .failure(InputError(message: "empty response body"))
                return
            }
            guard data.count <= maxImageBytes else {
                received = .failure(InputError(message: "image exceeds \(maxImageBytes) byte limit"))
                return
            }
            received = .success(data)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + requestTimeout + 5) == .timedOut {
            task.cancel()
            throw InputError(message: "request timed out")
        }
        switch received {
        case .success(let data): return data
        case .failure(let error): throw error
        case .none: throw InputError(message: "request ended without a result")
        }
    }
}

func loadInput(_ input: String, client: SecureHTTPClient) throws -> Data {
    if let url = URL(string: input), let scheme = url.scheme?.lowercased() {
        if scheme == "https" {
            return try client.fetch(url)
        }
        if scheme == "http" {
            throw InputError(message: "HTTP is disabled; use an https URL")
        }
        if scheme == "file" {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maxImageBytes else {
                throw InputError(message: "local image exceeds \(maxImageBytes) byte limit")
            }
            return data
        }
        throw InputError(message: "unsupported URL scheme: \(scheme)")
    }

    // A local path is useful for repeatable offline runs; network inputs remain HTTPS-only.
    let data = try Data(contentsOf: URL(fileURLWithPath: input), options: [.mappedIfSafe])
    guard data.count <= maxImageBytes else {
        throw InputError(message: "local image exceeds \(maxImageBytes) byte limit")
    }
    return data
}

func recognize(_ data: Data) throws -> [OCRLine] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw InputError(message: "data is not a supported image")
    }

    var requestError: Error?
    let request = VNRecognizeTextRequest { _, error in
        if let error { requestError = error }
    }
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    request.usesLanguageCorrection = true

    var orientation: CGImagePropertyOrientation = .up
    if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let raw = properties[kCGImagePropertyOrientation] as? NSNumber,
       let value = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
        orientation = value
    }

    let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
    do {
        try handler.perform([request])
    } catch {
        if let requestError { throw requestError }
        throw error
    }
    let observations = request.results ?? []
    return observations.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        return OCRLine(text: candidate.string, confidence: candidate.confidence)
    }
}

func parseInputs(_ raw: String) throws -> [String] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    if let first = trimmed.first, first == "[" || first == "{" {
        let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [])
        if let values = object as? [String] { return values }
        if let dictionary = object as? [String: Any] {
            for key in ["urls", "images", "items", "inputs"] {
                if let values = dictionary[key] as? [String] { return values }
                if let values = dictionary[key] as? [[String: Any]] {
                    return values.compactMap { $0["url"] as? String ?? $0["input"] as? String }
                }
            }
            if let value = dictionary["url"] as? String { return [value] }
        }
        if let values = object as? [[String: Any]] {
            return values.compactMap { $0["url"] as? String ?? $0["input"] as? String }
        }
        throw InputError(message: "JSON must be an array of URLs or an object containing urls/images/items/inputs")
    }
    return trimmed.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init).filter { !$0.isEmpty }
}

func emit<T: Encodable>(_ value: T, encoder: JSONEncoder) {
    do {
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
        fputs("failed to encode output: \(error)\n", stderr)
    }
}

var inputPath: String?
var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    if argument == "--input" {
        guard let value = arguments.first else {
            fputs("--input requires a path\n", stderr)
            exit(2)
        }
        inputPath = value
        arguments.removeFirst()
    } else if argument == "--help" || argument == "-h" {
        print("Usage: vision_ocr.swift [--input FILE] < urls-or-json")
        print("Input: JSON array/object or one HTTPS URL (or local image path) per line.")
        exit(0)
    } else {
        fputs("unknown argument: \(argument)\n", stderr)
        exit(2)
    }
}

let rawInput: String
do {
    if let inputPath {
        rawInput = try String(contentsOfFile: inputPath, encoding: .utf8)
    } else {
        rawInput = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
} catch {
    fputs("cannot read input: \(error)\n", stderr)
    exit(2)
}

let inputs: [String]
do {
    inputs = try parseInputs(rawInput)
} catch {
    fputs("cannot parse input: \(error)\n", stderr)
    exit(2)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let client = SecureHTTPClient()
for input in inputs {
    let started = Date()
    do {
        let data = try loadInput(input, client: client)
        let lines = try recognize(data)
        let text = lines.map(\.text).joined(separator: "\n")
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        emit(OCRSuccess(input: input, ok: true, text: text, lines: lines, bytes: data.count, elapsed_ms: elapsed), encoder: encoder)
    } catch {
        let message: String
        if let inputError = error as? InputError {
            message = inputError.message
        } else {
            let nsError = error as NSError
            message = "\(nsError.domain) [\(nsError.code)]: \(nsError.localizedDescription)"
        }
        emit(OCRFailure(input: input, ok: false, error: OCError(type: String(describing: type(of: error)), message: message)), encoder: encoder)
    }
}
