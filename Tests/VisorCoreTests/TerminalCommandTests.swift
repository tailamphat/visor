import Foundation
import Testing
import VisorCore

@Suite struct TerminalCommandTests {
    @Test func everyCatalogCommandBuildsAScript() {
        var count = 0
        for tool in ReleaseTool.all {
            for method in InstallMethod.allCases {
                guard let command = tool.updateCommand(method) else { continue }
                count += 1
                let script = TerminalCommand.script(toolName: tool.name, command: command, binaryDir: nil)
                #expect(script != nil, "\(command)")
                #expect(script?.contains("\n\(command)\n") == true)
            }
        }
        #expect(count > 8)
    }

    @Test func exactContent() {
        let script = TerminalCommand.script(toolName: "Claude Code", command: "brew upgrade x", binaryDir: "/Users/me/.local/bin")
        #expect(script == """
        #!/bin/zsh -f
        rm -f -- "$0"; rmdir -- "${0:h}" 2>/dev/null
        export PATH='/Users/me/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
        print -r -- 'Visor: updating Claude Code'
        brew upgrade x
        rc=$?
        if [ "$rc" -eq 0 ]; then
          print -r -- 'Done. You can close this window.'
        else
          print -r -- "Update failed (exit status $rc). You can close this window."
        fi

        """)
    }

    @Test func refusesAnythingNotPlain() {
        for bad in ["", "rm -rf ~; x", "a\"b", "a'b", "a\\b", "a\nb", "a$(x)", "a`x`", "a|b", "a&b", "a>b", "a*b",
                    "é", String(repeating: "a", count: 121)] {
            #expect(TerminalCommand.script(toolName: "T", command: bad, binaryDir: nil) == nil, "\(bad)")
            #expect(TerminalCommand.script(toolName: bad, command: "brew upgrade x", binaryDir: nil) == nil, "\(bad)")
        }
    }

    @Test func oddFolderIsDropped() {
        let script = TerminalCommand.script(toolName: "T", command: "x", binaryDir: "/a'b")
        #expect(script?.contains("export PATH='/opt/homebrew/bin") == true)
        #expect(TerminalCommand.script(toolName: "T", command: "x", binaryDir: "rel")?.contains("'rel:") == false)
    }

    @Test func writesPrivateExecutableFile() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("visor-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let url = try TerminalCommand.write("echo hi\n", in: base)
        func mode(_ u: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.posixPermissions] as? Int) ?? -1 }
        #expect(mode(url) == 0o700)
        #expect(mode(url.deletingLastPathComponent()) == 0o700)
        #expect(url.pathExtension == "command")
        #expect(try String(contentsOf: url, encoding: .utf8) == "echo hi\n")
    }
}
