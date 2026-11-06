import Foundation
import XCTest
@testable import TopologyCore

@MainActor
final class SettingsPersistenceTests: XCTestCase {
    private func withStore(
        _ body: (SettingsStore, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("od-settings-writer-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(SettingsStore(directory: directory), directory)
    }

    func testCheckpointFollowsQueuedSnapshotsAndCannotBeOverwrittenByThem() async throws {
        try await withStore { store, _ in
            let writer = SettingsPersistence(store: store)
            writer.enqueue(OpenDisplaySettings(confirmationCountdownSeconds: 11))
            writer.enqueue(OpenDisplaySettings(confirmationCountdownSeconds: 22))

            let saved = await writer.saveAndWait(OpenDisplaySettings(confirmationCountdownSeconds: 33))
            XCTAssertTrue(saved)
            await writer.flush()
            XCTAssertEqual(store.load().confirmationCountdownSeconds, 33)
        }
    }

    func testSynchronousSaveFollowsQueuedSnapshotsAndCannotBeOverwrittenByThem() async throws {
        try await withStore { store, _ in
            let writer = SettingsPersistence(store: store)
            writer.enqueue(OpenDisplaySettings(confirmationCountdownSeconds: 11))
            writer.enqueue(OpenDisplaySettings(confirmationCountdownSeconds: 22))
            XCTAssertTrue(writer.saveSynchronously(OpenDisplaySettings(confirmationCountdownSeconds: 33)))
            XCTAssertEqual(store.load().confirmationCountdownSeconds, 33)
            await writer.flush()
            XCTAssertEqual(store.load().confirmationCountdownSeconds, 33)
        }
    }

    func testSynchronousSaveReportsFailureWhenDirectoryIsARegularFile() async throws {
        try await withStore { store, directory in
            try Data("occupied".utf8).write(to: directory)
            let writer = SettingsPersistence(store: store)
            XCTAssertFalse(writer.saveSynchronously(OpenDisplaySettings(confirmationCountdownSeconds: 47)))
            XCTAssertEqual(try Data(contentsOf: directory), Data("occupied".utf8))
        }
    }

    func testFlushPersistsLastQueuedSnapshot() async throws {
        try await withStore { store, _ in
            let writer = SettingsPersistence(store: store)
            for value in 1...20 {
                writer.enqueue(OpenDisplaySettings(confirmationCountdownSeconds: value))
            }
            await writer.flush()
            XCTAssertEqual(store.load().confirmationCountdownSeconds, 20)
        }
    }

    func testCheckpointIsOnDiskBeforeCallerContinues() async throws {
        try await withStore { store, _ in
            let writer = SettingsPersistence(store: store)
            let saved = await writer.saveAndWait(OpenDisplaySettings(confirmationCountdownSeconds: 47))
            XCTAssertTrue(saved)
            XCTAssertEqual(store.load().confirmationCountdownSeconds, 47)
        }
    }

    func testCheckpointReportsFailureWhenDirectoryIsARegularFile() async throws {
        try await withStore { store, directory in
            try Data("occupied".utf8).write(to: directory)
            let writer = SettingsPersistence(store: store)
            let saved = await writer.saveAndWait(OpenDisplaySettings(confirmationCountdownSeconds: 47))
            XCTAssertFalse(saved)
            await writer.flush()
            XCTAssertEqual(try Data(contentsOf: directory), Data("occupied".utf8))
        }
    }
}
