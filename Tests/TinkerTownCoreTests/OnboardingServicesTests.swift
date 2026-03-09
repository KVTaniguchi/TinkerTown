import Foundation
import Testing
import TinkerTownCore

@Suite("OnboardingServices")
struct OnboardingServicesTests {

    @Test("Bundled model catalog validates and loads")
    func bundledCatalogLoads() async throws {
        let service = ModelCatalogService()
        let models = try await service.fetchManifest()
        #expect(!models.isEmpty)
        #expect(models.count == 3)
        #expect(models.allSatisfy { ModelCatalogService.verifyModelSignature($0) })
    }

    @Test("Tampered model signature fails verification")
    func signatureTamperFails() {
        var model = ModelCatalogService.bundledManifest()[0]
        model.sha256 = "tampered"
        #expect(!ModelCatalogService.verifyModelSignature(model))
    }

    @Test("Health check warns when repository is not provided")
    @MainActor
    func healthCheckWarnsWithoutRepo() async {
        let runtime = ModelRuntimeAdapter(
            client: OllamaClient(baseURL: URL(string: "https://example.com")!, timeout: 0.1),
            installedModels: [:],
            localOnly: true
        )
        let runner = HealthCheckRunner(
            runtime: runtime,
            paths: AppContainerPaths(root: URL(fileURLWithPath: "/tmp/tinkertown-tests"))
        )

        let results = await runner.run(plannerModelId: nil, workerModelId: nil)
        let repo = results.first { $0.checkName == "Repo preflight" }
        let build = results.first { $0.checkName == "Build probe" }
        #expect(repo?.status == .warn)
        #expect(build?.status == .warn)
    }
}
