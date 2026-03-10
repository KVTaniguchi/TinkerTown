import Foundation
import Testing
import TinkerTownCore

@Suite("RemediationEngine")
struct RemediationEngineTests {

    @Test("Disk error maps to storage remediation")
    func diskError() {
        let engine = RemediationEngine()
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Not enough disk space"])
        let r = engine.remediate(error: error)
        #expect(r.reason.contains("disk") || r.action.contains("Storage") || r.action.contains("space"))
    }

    @Test("Network error maps to retry")
    func networkError() {
        let engine = RemediationEngine()
        let error = NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Network connection lost"])
        let r = engine.remediate(error: error)
        #expect(r.action.contains("internet") || r.action.contains("Resume") || r.actionLabel == "Retry")
    }

    @Test("Checksum error maps to retry download")
    func checksumError() {
        let engine = RemediationEngine()
        let error = NSError(domain: "Test", code: 3, userInfo: [NSLocalizedDescriptionKey: "Checksum verification failed"])
        let r = engine.remediate(error: error)
        #expect(r.reason.contains("verification") || r.action.contains("download"))
    }

    @Test("Unknown error returns generic remediation")
    func unknownError() {
        let engine = RemediationEngine()
        let error = NSError(domain: "Test", code: 99, userInfo: [NSLocalizedDescriptionKey: "Something went wrong"])
        let r = engine.remediate(error: error)
        #expect(!r.reason.isEmpty)
        #expect(!r.action.isEmpty)
    }
}
