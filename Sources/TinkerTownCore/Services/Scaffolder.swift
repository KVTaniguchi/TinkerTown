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

    /// Minimal Node backend scaffold: creates backend/server.js and backend/package.json
    /// so the model can patch existing valid code instead of generating a full file (which often truncates).
    /// Uses only Node built-ins (http) so verification can run without npm install or network.
    public func createNodeBackend(at root: URL) throws {
        let fm = FileManager.default
        let backendDir = root.appendingPathComponent("backend")
        let serverPath = backendDir.appendingPathComponent("server.js")
        guard !fm.fileExists(atPath: serverPath.path) else { return }
        try fm.createDirectory(at: backendDir, withIntermediateDirectories: true)
        try writeMinimalNodeBackendFiles(backendDir: backendDir, fm: fm)
    }

    /// Overwrites backend/server.js and package.json with the minimal runnable scaffold.
    /// Use after a model patch leaves server.js with syntax errors so the next attempt sees valid code.
    public func restoreNodeBackend(at root: URL) throws {
        let fm = FileManager.default
        let backendDir = root.appendingPathComponent("backend")
        try fm.createDirectory(at: backendDir, withIntermediateDirectories: true)
        try writeMinimalNodeBackendFiles(backendDir: backendDir, fm: fm)
    }

    private func writeMinimalNodeBackendFiles(backendDir: URL, fm: FileManager) throws {
        let serverJs = """
        const http = require('http');
        const port = process.env.PORT || 3000;
        const server = http.createServer((req, res) => {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true }));
        });
        server.listen(port, () => console.log('Listening on', port));
        """
        let serverPath = backendDir.appendingPathComponent("server.js")
        try serverJs.write(to: serverPath, atomically: true, encoding: .utf8)
        let packageJson = """
        {"name":"backend","version":"1.0.0","main":"server.js","scripts":{"start":"node server.js"}}
        """
        let packagePath = backendDir.appendingPathComponent("package.json")
        try packageJson.write(to: packagePath, atomically: true, encoding: .utf8)
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

