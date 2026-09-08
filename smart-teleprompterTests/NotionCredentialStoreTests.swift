import Foundation
import Testing
@testable import smart_teleprompter

struct NotionCredentialStoreTests {
    @Test func persistsAcrossInstancesAndCanBeReplacedAndDisconnected() throws {
        let service = "rxlab.smart-teleprompter.tests.\(UUID().uuidString)"
        let store = NotionCredentialStore(service: service)
        defer { try? store.delete() }
        #expect(try store.load() == nil)
        try store.save("first-test-token")
        let reopened = NotionCredentialStore(service: service)
        #expect(try reopened.load() == "first-test-token")
        try reopened.save("replacement-test-token")
        #expect(try store.load() == "replacement-test-token")
        try reopened.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }
}
