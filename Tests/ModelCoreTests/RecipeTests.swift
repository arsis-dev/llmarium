import Foundation
import XCTest
@testable import ModelCore

final class RecipeTests: XCTestCase {
    private func model(_ name: String, store: StoreKind, path: String = "/x") -> LocalModel {
        var model = LocalModel(name: name, store: store, path: path)
        var spec = ModelSpec()
        spec.maxContext = 262_144
        model.spec = spec
        return model
    }

    func testMTPLXRecipeAddsEachOptionOnce() throws {
        var recipe = Recipe(engine: .mtplx, model: "Youssofal/Qwen3.5-4B", reasoning: "off",
                            sampling: Sampling(temperature: 0.7, topP: 0.8, topK: 20), flags: ["--profile", "turbo"])
        let plan = try LaunchPlan.make(model: model("Youssofal/Qwen3.5-4B", store: .mtplx), engine: .mtplx, port: 18_100, context: 32_768,
                                       installation: EngineInstallation(kind: .mtplx, version: nil, location: "/bin/mtplx"), recipe: recipe)
        XCTAssertEqual(plan.arguments.filter { $0 == "--reasoning" }.count, 1)
        XCTAssertEqual(plan.arguments.suffix(10), ["--reasoning", "off", "--default-temperature", "0.7", "--default-top-p", "0.8",
                                                   "--default-top-k", "20", "--profile", "turbo"])
        // A free flag naming the same option wins over the field.
        recipe.flags = ["--reasoning", "on"]
        let args = recipe.arguments(for: .mtplx, existing: [])
        XCTAssertEqual(args.filter { $0 == "--reasoning" }.count, 1)
        XCTAssertEqual(args.suffix(2), ["--reasoning", "on"])
        XCTAssertTrue(recipe.arguments(for: .mtplx, existing: ["--reasoning"]).allSatisfy { $0 != "--reasoning" },
                      "an option the command already carries is not repeated")
    }

    func testMLXServeUsesItsOwnSamplingOptionsAndOMLXNone() {
        let recipe = Recipe(engine: .mlxServe, model: "a/b", reasoning: "off", sampling: Sampling(temperature: 0.6, topK: 40))
        XCTAssertEqual(recipe.arguments(for: .mlxServe, existing: []), ["--temp", "0.6", "--top-k", "40"], "no reasoning option on mlx-serve")
        XCTAssertEqual(recipe.arguments(for: .omlx, existing: []), [])
    }

    func testDerivationReadsOnlyTheModelFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "recipe-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"temperature": 1.0, "top_k": 20, "top_p": 0.95, "do_sample": true}"#.utf8).write(to: folder.appending(path: "generation_config.json"))
        let derived = RecipeDeriver.derive(model: model("a/with-config", store: .omlx, path: folder.path), engine: .omlx)
        XCTAssertEqual(derived.sampling, Sampling(temperature: 1.0, topP: 0.95, topK: 20))
        XCTAssertEqual(derived.context, 65_536)
        XCTAssertEqual(derived.author, .auto)
        let bare = RecipeDeriver.derive(model: model("a/without", store: .mtplx), engine: .mtplx)
        XCTAssertTrue(bare.sampling.isEmpty, "no published values: nothing is invented")
        XCTAssertTrue(bare.sources.contains { $0.contains("Aucune valeur") })
        XCTAssertTrue(bare.notes.contains { $0.contains("--reasoning off") })
    }

    func testStoreKeepsOneRecipePerModelAndEngine() throws {
        let store = RecipeStore(file: FileManager.default.temporaryDirectory.appending(path: "recipes-\(UUID()).json"))
        try store.save(Recipe(engine: .mtplx, model: "a/b", reasoning: "off", author: .claude))
        try store.save(Recipe(engine: .mtplx, model: "a/b", reasoning: "on", author: .user))
        try store.save(Recipe(engine: .mlxServe, model: "a/b"))
        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.recipe(engine: .mtplx, model: "a/b")?.reasoning, "on")
    }
}

final class BenchmarkPromptTests: XCTestCase {
    func testLongPromptHidesACodeAndEachRunIsFresh() throws {
        let first = Benchmark.prompts(model: "m")
        let second = Benchmark.prompts(model: "m")
        let long = try XCTUnwrap(first.first { $0.kind == "long" })
        let text = ((long.body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertGreaterThan(text.count / 4, 7_000, "about 13K tokens once tokenised (French costs more than 4 characters per token)")
        let code = try XCTUnwrap(text.range(of: "le code de vérification est ").map { String(text[$0.upperBound...].prefix(8)) })
        var outcome = Benchmark.StreamOutcome()
        outcome.text = "Le code est \(code)."
        XCTAssertTrue(long.check(outcome).0)
        outcome.text = "Je ne sais pas."
        XCTAssertFalse(long.check(outcome).0)
        let otherText = ((second.first { $0.kind == "long" }?.body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertNotEqual(text.prefix(60), otherText.prefix(60), "a fresh header defeats prefix caches")
    }

    func testToolCallNeedsTheToolAndReadableArguments() throws {
        let tool = try XCTUnwrap(Benchmark.prompts(model: "m").first { $0.kind == "outil" })
        var outcome = Benchmark.StreamOutcome()
        XCTAssertFalse(tool.check(outcome).0)
        outcome.toolName = "meteo"
        outcome.toolArguments = #"{"ville": "Lyon"}"#
        XCTAssertTrue(tool.check(outcome).0)
        outcome.toolArguments = "{ville"
        XCTAssertFalse(tool.check(outcome).0)
    }
}

final class ClaudeAskTests: XCTestCase {
    func testMCPConfigIsValidJSONAndThePromptNamesTheTools() throws {
        let model = LocalModel(name: "Youssofal/Qwen3.5-4B", store: .mtplx, path: "/x")
        let launch = ClaudeAsk.launch(model: model, engine: .mtplx, lml: #"/Applications/Modèles "locaux".app/Contents/MacOS/lml"#)
        let index = try XCTUnwrap(launch.arguments.firstIndex(of: "--mcp-config"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(launch.arguments[index + 1].utf8)) as? [String: Any])
        let server = try XCTUnwrap((config["mcpServers"] as? [String: Any])?["local-models"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, #"/Applications/Modèles "locaux".app/Contents/MacOS/lml"#)
        XCTAssertEqual(server["args"] as? [String], ["mcp"])
        let prompt = try XCTUnwrap(launch.arguments.last)
        XCTAssertTrue(prompt.contains("get_model_context") && prompt.contains("save_recipe") && prompt.contains("Youssofal/Qwen3.5-4B"))
        XCTAssertEqual(launch.arguments[launch.arguments.count - 2], "--", "the prompt cannot be read as an option")
        XCTAssertFalse(launch.arguments.contains("mcp__local-models__save_recipe"), "saving is never pre-approved")
    }
}
