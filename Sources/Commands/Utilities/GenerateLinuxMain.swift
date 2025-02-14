//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2015-2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Basics
import PackageGraph
import PackageModel
import TSCBasic

/// A utility for generating test entries on linux.
///
/// This uses input from macOS's test discovery and generates
/// corelibs-xctest compatible test manifests.
///
/// this functionality is deprecated as of 12/2020
/// We are keeping it here for transition purposes
/// This class is to be removed in future releases
final class LinuxMainGenerator {

    enum Error: Swift.Error {
        case noTestTargets
    }

    /// The package graph we're working on.
    let graph: PackageGraph

    /// The test suites that we need to write.
    let testSuites: [TestSuite]

    init(graph: PackageGraph, testSuites: [TestSuite]) {
        self.graph = graph
        self.testSuites = testSuites
    }

    /// Generate the XCTestManifests.swift and LinuxMain.swift for the package.
    func generate() throws {
        // Create the module struct from input.
        //
        // This converts the input test suite into a structure that
        // is more suitable for generating linux test entries.
        let modulesBuilder = ModulesBuilder()
        for suite in testSuites {
            modulesBuilder.add(suite.tests)
        }
        let modules = modulesBuilder.build().sorted(by: { $0.name < $1.name })

        // Generate manifest file for each test module we got from XCTest discovery.
        for module in modules {
            guard let target = graph.reachableTargets.first(where: { $0.c99name == module.name }) else {
                print("warning: did not find target '\(module.name)'")
                continue
            }
            assert(target.type == .test, "Unexpected target type \(target.type) for \(target)")

            // Write the manifest file for this module.
            let testManifest = target.sources.root.appending("XCTestManifests.swift")
            let stream = try LocalFileOutputByteStream(testManifest)

            stream <<< "#if !canImport(ObjectiveC)" <<< "\n"
            stream <<< "import XCTest" <<< "\n"
            for klass in module.classes.lazy.sorted(by: { $0.name < $1.name }) {
                stream <<< "\n"
                stream <<< "extension " <<< klass.name <<< " {" <<< "\n"
                stream <<< indent(4) <<< "// DO NOT MODIFY: This is autogenerated, use:\n"
                stream <<< indent(4) <<< "//   `swift test --generate-linuxmain`\n"
                stream <<< indent(4) <<< "// to regenerate.\n"
                stream <<< indent(4) <<< "static let __allTests__\(klass.name) = [" <<< "\n"
                for method in klass.methods {
                    stream <<< indent(8) <<< "(\"\(method)\", \(method))," <<< "\n"
                }
                stream <<< indent(4) <<< "]" <<< "\n"
                stream <<< "}" <<< "\n"
            }

            stream <<<
            """

            public func __allTests() -> [XCTestCaseEntry] {
                return [

            """

            for klass in module.classes {
                stream <<< indent(8) <<< "testCase(" <<< klass.name <<< ".__allTests__\(klass.name))," <<< "\n"
            }

            stream <<< """
                ]
            }
            #endif

            """
            stream.flush()
        }

        /// Write LinuxMain.swift file.
        guard let testTarget = graph.reachableProducts.first(where: { $0.type == .test })?.targets.first else {
            throw Error.noTestTargets
        }
        guard let linuxMainFileName = SwiftTarget.testEntryPointNames.first(where: { $0.lowercased().hasPrefix("linux") }) else {
            throw InternalError("Unknown linux main file name")
        }
        let linuxMain = testTarget.sources.root.parentDirectory.appending(components: linuxMainFileName)

        let stream = try LocalFileOutputByteStream(linuxMain)
        stream <<< "import XCTest" <<< "\n\n"
        for module in modules {
            stream <<< "import " <<< module.name <<< "\n"
        }
        stream <<< "\n"
        stream <<< "var tests = [XCTestCaseEntry]()" <<< "\n"
        for module in modules {
            stream <<< "tests += \(module.name).__allTests()" <<< "\n"
        }
        stream <<< "\n"
        stream <<< "XCTMain(tests)" <<< "\n"
        stream.flush()
    }

    private func indent(_ spaces: Int) -> ByteStreamable {
        return Format.asRepeating(string: " ", count: spaces)
    }
}

// MARK: - Internal data structure for LinuxMainGenerator.

private struct Module {
    struct Class {
        let name: String
        let methods: [String]
    }
    let name: String
    let classes: [Class]
}

private final class ModulesBuilder {

    final class ModuleBuilder {
        let name: String
        var classes: [ClassBuilder]

        init(_ name: String) {
            self.name = name
            self.classes = []
        }

        func build() -> Module {
            return Module(name: name, classes: classes.map({ $0.build() }))
        }
    }

    final class ClassBuilder {
        let name: String
        var methods: [String]

        init(_ name: String) {
            self.name = name
            self.methods = []
        }

        func build() -> Module.Class {
            return .init(name: name, methods: methods)
        }
    }

    /// The built modules.
    private var modules: [ModuleBuilder] = []

    func add(_ cases: [TestSuite.TestCase]) {
        for testCase in cases {
            let (module, theKlass) = testCase.name.spm_split(around: ".")
            guard let klass = theKlass else {
                // Ignore the classes that have zero tests.
                if testCase.tests.isEmpty {
                    continue
                }
                fatalError("unreachable \(testCase.name)")
            }
            for method in testCase.tests {
                add(module, klass, method)
            }
        }
    }

    private func add(_ moduleName: String, _ klassName: String, _ methodName: String) {
        // Find or create the module.
        let module: ModuleBuilder
        if let theModule = modules.first(where: { $0.name == moduleName }) {
            module = theModule
        } else {
            module = ModuleBuilder(moduleName)
            modules.append(module)
        }

        // Find or create the class.
        let klass: ClassBuilder
        if let theKlass = module.classes.first(where: { $0.name == klassName }) {
            klass = theKlass
        } else {
            klass = ClassBuilder(klassName)
            module.classes.append(klass)
        }

        // Finally, append the method to the class.
        klass.methods.append(methodName)
    }

    func build() -> [Module] {
        return modules.map({ $0.build() })
    }
}
