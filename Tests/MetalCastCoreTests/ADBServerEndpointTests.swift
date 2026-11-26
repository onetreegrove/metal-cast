import Testing
@testable import MetalCastCore

@Suite("ADBServerEndpoint")
struct ADBServerEndpointTests {
    @Test("Default fallback when no environment variables are set")
    func defaultFallback() throws {
        let endpoint = try ADBServerEndpoint.resolve(environment: [:])
        #expect(endpoint.host == "127.0.0.1")
        #expect(endpoint.port == 5037)
        #expect(endpoint.cliAddressArgument == "tcp:127.0.0.1:5037")
    }

    @Test("Explicit endpoint overrides environment variables")
    func explicitOverridesEnvironment() throws {
        let explicit = try ADBServerEndpoint(host: "localhost", port: 5055)
        let env = [
            "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5040",
            "ANDROID_ADB_SERVER_PORT": "5041"
        ]
        let resolved = try ADBServerEndpoint.resolve(explicit: explicit, environment: env)
        #expect(resolved == explicit)
    }

    @Test("ADB_SERVER_SOCKET resolves loopback host and port")
    func serverSocketResolution() throws {
        let resolved = try ADBServerEndpoint.resolve(environment: [
            "ADB_SERVER_SOCKET": "tcp:localhost:5042"
        ])
        #expect(resolved.host == "localhost")
        #expect(resolved.port == 5042)
        #expect(resolved.cliAddressArgument == "tcp:localhost:5042")
    }

    @Test("ANDROID_ADB_SERVER_ADDRESS and PORT support IPv6 loopback")
    func addressAndPortIPv6() throws {
        let resolved = try ADBServerEndpoint.resolve(environment: [
            "ANDROID_ADB_SERVER_ADDRESS": "::1",
            "ANDROID_ADB_SERVER_PORT": "5099"
        ])
        #expect(resolved.host == "::1")
        #expect(resolved.port == 5099)
        #expect(resolved.cliAddressArgument == "tcp:[::1]:5099")

        let bracketedSocket = try ADBServerEndpoint.resolve(environment: [
            "ADB_SERVER_SOCKET": "tcp:[::1]:5100"
        ])
        #expect(bracketedSocket.host == "::1")
        #expect(bracketedSocket.port == 5100)
    }

    @Test("Rejects incompatible socket schemes, non-loopback hosts, and invalid ports")
    func rejectsInvalidEndpoints() {
        let badInputs: [[String: String]] = [
            ["ADB_SERVER_SOCKET": "localfilesystem:/tmp/adb.sock"],
            ["ADB_SERVER_SOCKET": "local:/tmp/adb.sock"],
            ["ADB_SERVER_SOCKET": "tcp:192.168.1.10:5037"],
            ["ADB_SERVER_SOCKET": "tcp:0.0.0.0:5037"],
            ["ADB_SERVER_SOCKET": "tcp:127.0.0.1:0"],
            ["ADB_SERVER_SOCKET": "tcp:127.0.0.1:70000"],
            ["ANDROID_ADB_SERVER_ADDRESS": "10.0.0.2"],
            ["ANDROID_ADB_SERVER_PORT": "0"],
            ["ANDROID_ADB_SERVER_PORT": "notaport"]
        ]

        for env in badInputs {
            #expect(throws: ADBFileError.self) {
                _ = try ADBServerEndpoint.resolve(environment: env)
            }
        }
    }

    @Test("Rejects conflicting ADB_SERVER_SOCKET and legacy variables")
    func rejectsConflicts() throws {
        #expect(throws: ADBFileError.self) {
            _ = try ADBServerEndpoint.resolve(environment: [
                "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5037",
                "ANDROID_ADB_SERVER_PORT": "5038"
            ])
        }

        #expect(throws: ADBFileError.self) {
            _ = try ADBServerEndpoint.resolve(environment: [
                "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5037",
                "ANDROID_ADB_SERVER_ADDRESS": "localhost"
            ])
        }

        let compatible = try ADBServerEndpoint.resolve(environment: [
            "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5038",
            "ANDROID_ADB_SERVER_ADDRESS": "127.0.0.1",
            "ANDROID_ADB_SERVER_PORT": "5038"
        ])
        #expect(compatible.port == 5038)
    }

    @Test("Sanitizes environment and prepends -L argument")
    func sanitizedEnvAndCLIArgs() throws {
        let rawEnv = [
            "PATH": "/usr/bin:/bin",
            "ADB_SERVER_SOCKET": "tcp:127.0.0.1:5038",
            "ANDROID_ADB_SERVER_PORT": "5038",
            "ANDROID_ADB_SERVER_ADDRESS": "127.0.0.1",
            "KEEP_ME": "yes"
        ]
        let cleaned = ADBServerEndpoint.sanitizedEnvironment(from: rawEnv)
        #expect(cleaned["ADB_SERVER_SOCKET"] == nil)
        #expect(cleaned["ANDROID_ADB_SERVER_PORT"] == nil)
        #expect(cleaned["ANDROID_ADB_SERVER_ADDRESS"] == nil)
        #expect(cleaned["PATH"] == "/usr/bin:/bin")
        #expect(cleaned["KEEP_ME"] == "yes")

        let endpoint = try ADBServerEndpoint(host: "127.0.0.1", port: 5038)
        #expect(
            endpoint.cliArguments(prependedTo: ["devices", "-l"]) ==
            ["-L", "tcp:127.0.0.1:5038", "devices", "-l"]
        )
    }
}
