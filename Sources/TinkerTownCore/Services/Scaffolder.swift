import Foundation

/// High-level project scaffolding helpers used by agent tasks.
/// These wrap common "create project" operations in a safer API than arbitrary shell commands.
public struct Scaffolder {
    private let shell: ShellRunning

    public init(shell: ShellRunning = ShellRunner()) {
        self.shell = shell
    }

    /// Create a Swift package at the given path if it does not already exist.
    public func createSwiftPackage(name: String, at root: URL) throws {
        let fm = FileManager.default
        let packageDir = root.appendingPathComponent(name)
        if !fm.fileExists(atPath: packageDir.path) {
            try fm.createDirectory(at: packageDir, withIntermediateDirectories: true)
            _ = try shell.run("swift package init --type library", cwd: packageDir)
        }
    }

    /// Placeholder for creating a Vapor backend. In v1 we just create a Swift package
    /// and leave further customization to the agent.
    public func createVaporBackend(name: String, at root: URL) throws {
        try createSwiftPackage(name: name, at: root)
    }

    /// Placeholder for creating an Xcode app target. A future version could call
    /// `xcodebuild -create-xcodeproj` or similar; for now, this is a no-op shim.
    public func createXcodeAppPlaceholder(name: String, at root: URL) throws {
        let fm = FileManager.default
        let appDir = root.appendingPathComponent(name)
        if !fm.fileExists(atPath: appDir.path) {
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
    }

    /// Minimal web SPA scaffold: create an index.html with a basic layout if missing.
    public func createWebSPA(name: String, at root: URL) throws {
        let fm = FileManager.default
        let webDir = root.appendingPathComponent(name)
        if !fm.fileExists(atPath: webDir.path) {
            try fm.createDirectory(at: webDir, withIntermediateDirectories: true)
        }
        let index = webDir.appendingPathComponent("index.html")
        if !fm.fileExists(atPath: index.path) {
            let html = """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <title>\(name)</title>
            </head>
            <body>
              <div id="app">Todo SPA placeholder</div>
              <script>
              // TODO: Implement SPA logic here.
              </script>
            </body>
            </html>
            """
            try html.write(to: index, atomically: true, encoding: .utf8)
        }
    }
}

