import XCTest
@testable import MapQuestCore

final class DataArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("archive-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testHashesAndChecksums() {
        XCTAssertEqual(SHA256Digest.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Digest.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(SHA256Digest.hex(Data(repeating: 0x61, count: 1_000)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testZipRoundTrip() throws {
        let url = directory.appendingPathComponent("test.zip")
        let text = Data(String(repeating: "Brandenburger Tor ", count: 500).utf8)
        let binary = Data((0..<5_000).map { UInt8($0 % 251) })
        let writer = try ZipWriter(url: url)
        try writer.add("a/text.txt", data: text)
        try writer.add("b/binary.bin", data: binary, compress: false)
        try writer.add("empty.txt", data: Data())
        try writer.add("ümlaut/Straße.json", data: Data("{}".utf8))
        try writer.finish()

        let reader = try ZipReader(url: url)
        XCTAssertEqual(reader.entries.map(\.path), ["a/text.txt", "b/binary.bin", "empty.txt", "ümlaut/Straße.json"])
        XCTAssertEqual(try reader.data("a/text.txt"), text)
        XCTAssertEqual(try reader.data("b/binary.bin"), binary)
        XCTAssertEqual(try reader.data("empty.txt"), Data())
        XCTAssertEqual(try reader.data("ümlaut/Straße.json"), Data("{}".utf8))
        XCTAssertThrowsError(try reader.data("missing"))
        if Deflate.isAvailable {
            XCTAssertLessThan(reader.entries[0].compressedSize, text.count / 10, "text is deflated")
        }
        XCTAssertThrowsError(try ZipReader(url: directory.appendingPathComponent("nothing.zip")))
    }

    func testExportAndImportRestoreEverything() async throws {
        // A data source: key positions, a track over two days, captures with photos.
        let store = InMemoryDataStore()
        let start = Date(timeIntervalSince1970: 1_763_078_390.123_456)  // 2025-11-13, ten seconds before midnight UTC
        var samples: [LocationSample] = []
        for i in 0..<20 {
            let step = Double(i)
            let vertical: Double = i == 3 ? -1 : 3
            samples.append(LocationSample(
                latitude: 52.52 + step * 0.0003, longitude: 13.405 + step * 0.0002, altitude: 35.25,
                horizontalAccuracy: 4.5, verticalAccuracy: vertical, timestamp: start.addingTimeInterval(step * 7.3)
            ))
        }
        try await store.addSamples(samples)
        var points: [TrackPoint] = []
        for i in 0..<1_300 {
            let step = Double(i)
            let altitude: Double = -2.5 + Double(i % 7)
            let vertical: Double = i % 11 == 0 ? -1 : 4.2
            points.append(TrackPoint(
                timestamp: start.addingTimeInterval(step), latitude: 52.52 + step * 1e-5, longitude: 13.405 - step * 1e-5,
                altitude: altitude, horizontalAccuracy: Double(i % 30), verticalAccuracy: vertical
            ))
        }
        points[5].horizontalAccuracyDM = -1
        try await store.putTrackSegments(stride(from: 0, to: points.count, by: 600).map {
            TrackSegment(points: Array(points[$0..<min($0 + 600, points.count)]))
        })
        let photos = directory.appendingPathComponent("photos-in")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let jpeg = Data((0..<3_000).map { UInt8(($0 * 7) % 256) })
        try jpeg.write(to: photos.appendingPathComponent("dom-1.jpg"))
        try jpeg.write(to: photos.appendingPathComponent("dom-2.jpg"))          // the same picture twice
        try Data([1, 2, 3]).write(to: photos.appendingPathComponent("tor-1.jpg"))
        var log = CaptureLog()
        let date = Date(timeIntervalSince1970: 1_763_000_000)
        log.nearby["museum"] = date
        log.records["dom"] = CaptureRecord(sightID: "dom", capturedAt: date, recordedAt: date, celebrated: true)
        log.records["tor"] = CaptureRecord(sightID: "tor", capturedAt: date, recordedAt: date, celebrated: false)
        log.addPhoto(TakenPhoto(sightID: "dom", takenAt: date, latitude: 52.519, longitude: 13.401, fileName: "dom-1.jpg"))
        log.addPhoto(TakenPhoto(sightID: "dom", takenAt: date.addingTimeInterval(60), fileName: "dom-2.jpg"))
        log.addPhoto(TakenPhoto(sightID: "tor", takenAt: date, fileName: "tor-1.jpg"))
        log.addPhoto(TakenPhoto(sightID: "tor", takenAt: date.addingTimeInterval(5), fileName: "gone.jpg"))
        log.stations["alex-u"] = CaptureRecord(sightID: "alex-u", capturedAt: date, recordedAt: date, celebrated: true)
        log.readEntries = ["dom"]
        let settings = Data(#"{"radius":50}"#.utf8)

        let url = directory.appendingPathComponent("export.zip")
        var reported: [Double] = []
        let manifest = try DataArchive.write(
            DataArchive.Export(
                source: .init(id: "me", name: "My discoveries"), app: "MapQuest test",
                samples: try await store.samples(matching: .all), track: try await store.trackPoints(),
                captureLog: log, photoDirectory: photos, settings: settings,
                sightPackages: [SightPackage(id: "test.sights", version: "1.2", title: "Test",
                                             sights: [.init(id: "dom", name: "Dom", category: .church, latitude: 52.5, longitude: 13.4)])]
            ),
            to: url, progress: { reported.append($0) }
        )
        XCTAssertEqual(manifest.samples, 20)
        XCTAssertEqual(manifest.trackPoints, 1_300)
        XCTAssertEqual(manifest.trackDays, ["2025-11-13", "2025-11-14"])
        XCTAssertEqual(manifest.photos.count, 3)
        XCTAssertEqual(Set(manifest.photos.map(\.file)).count, 2, "the same picture is stored once")
        XCTAssertEqual(manifest.missingPhotos, 1)
        XCTAssertEqual(manifest.sightsNearby, 1)
        XCTAssertEqual(manifest.sightsCaptured, 2)
        XCTAssertEqual(reported.last, 1)
        XCTAssertEqual(manifest.sightPackages, ["test.sights 1.2"])

        // What a person finds in it.
        let archive = try ZipReader(url: url)
        let paths = Set(archive.entries.map(\.path))
        XCTAssertTrue(paths.isSuperset(of: ["manifest.json", "README.txt", "positions/samples.json", "positions/track/2025-11-13.json",
                                            "positions/track/2025-11-14.json", "captures/log.json", "settings.json"]))
        XCTAssertTrue(paths.contains("photos/\(SHA256Digest.hex(jpeg)).jpg"))
        let firstDay = String(decoding: try archive.data("positions/track/2025-11-13.json"), as: UTF8.self)
        XCTAssertTrue(firstDay.contains("[1763078390.1,52.520000,13.405000,-2.5,0.0,-1]"), firstDay.prefix(300).description)

        // Into another store and photo folder.
        let reader = try DataArchive.Reader(url: url)
        let restored = InMemoryDataStore()
        try await restored.addSamples([LocationSample(latitude: 1, longitude: 1, altitude: 0, timestamp: date)])  // replaced
        try await DataArchive.restorePositions(from: reader, into: restored)
        let restoredSamples = try await restored.samples(matching: .all).sorted { $0.timestamp < $1.timestamp }
        // Key positions with their IDs; times to the microsecond (seconds since 1970 as a JSON number).
        XCTAssertEqual(restoredSamples.count, samples.count)
        for (restored, original) in zip(restoredSamples, samples) {
            var same = restored
            XCTAssertEqual(restored.timestamp.timeIntervalSince1970, original.timestamp.timeIntervalSince1970, accuracy: 1e-6)
            same.timestamp = original.timestamp
            XCTAssertEqual(same, original)
        }
        let restoredTrack = try await restored.trackPoints()
        XCTAssertEqual(restoredTrack, points, "every track position exactly")
        XCTAssertEqual(try reader.captureLog(), log)
        XCTAssertEqual(try reader.settings(), settings)
        let packages = try SightPackageFile.decode(XCTUnwrap(reader.sightPackages()))
        XCTAssertEqual(packages.map(\.id), ["test.sights"], "the sights the captures are of")
        let photosOut = directory.appendingPathComponent("photos-out")
        XCTAssertEqual(try reader.restorePhotos(to: photosOut), 3)
        XCTAssertEqual(try Data(contentsOf: photosOut.appendingPathComponent("dom-2.jpg")), jpeg)
        XCTAssertEqual(try Data(contentsOf: photosOut.appendingPathComponent("tor-1.jpg")), Data([1, 2, 3]))
    }

    func testOnlyMapQuestExportsAreImported() throws {
        let other = directory.appendingPathComponent("other.zip")
        let writer = try ZipWriter(url: other)
        try writer.add("hello.txt", data: Data("hi".utf8))
        try writer.finish()
        XCTAssertThrowsError(try DataArchive.Reader(url: other)) { error in
            XCTAssertEqual(error as? DataArchive.ArchiveError, .notAMapQuestArchive)
        }
        let notZip = directory.appendingPathComponent("photo.jpg")
        try Data(repeating: 7, count: 100).write(to: notZip)
        XCTAssertThrowsError(try DataArchive.Reader(url: notZip))

        let newer = directory.appendingPathComponent("newer.zip")
        let manifest = #"{"format":"mapquest-data","version":99,"exportedAt":"2026-11-15T10:00:00Z","source":{"id":"me","name":"Me"},"samples":0,"trackPoints":0,"trackDays":[],"sightsNearby":0,"sightsDiscovered":0,"sightsCaptured":0,"stationsCollected":0,"photos":[],"missingPhotos":0,"hasCaptureLog":false,"hasSettings":false}"#
        let newerWriter = try ZipWriter(url: newer)
        try newerWriter.add("manifest.json", data: Data(manifest.utf8))
        try newerWriter.finish()
        XCTAssertThrowsError(try DataArchive.Reader(url: newer)) { error in
            XCTAssertEqual(error as? DataArchive.ArchiveError, .newerVersion(99))
        }
    }
}
