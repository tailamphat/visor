import CLua
import Foundation

/// One plugin: its own Lua 5.4 state, sandboxed, with the `visor` table as its
/// only way out. Not thread-safe: use each plugin from one serial queue.
///
/// Sandbox: the base, string, table, math and utf8 libraries, plus os.time,
/// os.date and os.clock. No io, os.execute, require, load, debug or bytecode.
/// Every call into the plugin has an instruction budget, so a loop that never
/// ends is stopped with an error instead of hanging Visor.
public final class LuaPlugin {
    public struct Timer: Equatable, Sendable {
        public let id: Int
        public let interval: TimeInterval
    }

    /// Instructions per call: a fraction of a second of pure Lua.
    public static var budget = 20_000_000
    /// No plugin runs more often than this.
    public static var minInterval: TimeInterval = 30

    public let manifest: PluginManifest
    public private(set) var timers: [Timer] = []

    private let L: OpaquePointer
    private weak var host: PluginHost?
    private var timerRefs: [Int: Int32] = [:]
    private var visorRef: Int32 = 0
    private var mainRef: Int32 = 0
    private var output = PluginOutput()
    private var savedStore: Data?

    public init(manifest: PluginManifest, source: String, host: PluginHost, store: Data? = nil, settings: [String: Any] = [:]) throws {
        guard let state = luaL_newstate() else { throw PluginError.lua("Lua couldn't start (out of memory)") }
        L = state
        self.manifest = manifest
        self.host = host
        savedStore = store
        _ = Self.installDispatch
        openSandbox()
        installAPI(settings: manifest.settings.merging(settings) { _, user in user }, store: store)
        let bytes = Array(source.utf8)
        let loaded = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(1, buffer.count)) {
                clua_loadstring(L, $0, buffer.count, "@\(manifest.main)")
            }
        }
        guard loaded == LUA_OK else {
            // deinit closes the state: Swift runs it when a fully set-up init throws.
            throw PluginError.lua(string(at: -1) ?? "couldn't load \(manifest.main)")
        }
        mainRef = luaL_ref(L, clua_registryindex())
    }

    deinit { lua_close(L) }

    /// Runs the main file, then each `visor.every` callback once.
    public func start() throws {
        try call(mainRef)
        for timer in timers {
            do { try fire(timer.id) } catch { host?.failed("\(error)") }
        }
    }

    /// Runs one `visor.every` callback.
    public func fire(_ id: Int) throws {
        guard let ref = timerRefs[id] else { return }
        try call(ref)
    }

    /// Runs a piece of Lua in the plugin (tests and the console).
    public func run(_ code: String) throws {
        let bytes = Array(code.utf8)
        let loaded = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(1, buffer.count)) {
                clua_loadstring(L, $0, buffer.count, "=run")
            }
        }
        guard loaded == LUA_OK else {
            let message = string(at: -1) ?? "couldn't load"
            clua_pop(L, 1)
            throw PluginError.lua(message)
        }
        try callTop()
    }

    // MARK: Calling into Lua

    private func call(_ ref: Int32) throws {
        lua_rawgeti(L, clua_registryindex(), lua_Integer(ref))
        try callTop()
    }

    /// Calls the function on top of the stack with the budget on, then saves the store if it changed.
    private func callTop() throws {
        clua_set_budget(L, Self.budget)
        let status = clua_pcall(L, 0, 0)
        clua_set_budget(L, 0)
        defer { saveStore() }
        guard status == LUA_OK else {
            let message = string(at: -1) ?? "error"
            clua_pop(L, 1)
            throw PluginError.lua(message)
        }
    }

    private func saveStore() {
        lua_rawgeti(L, clua_registryindex(), lua_Integer(visorRef))
        lua_getfield(L, -1, "store")
        let store = value(at: -1) ?? [String: Any]()
        clua_pop(L, 2)
        guard JSONSerialization.isValidJSONObject(store),
              let data = try? JSONSerialization.data(withJSONObject: store, options: [.sortedKeys]),
              data != savedStore else { return }
        savedStore = data
        host?.saveStore(data)
    }

    // MARK: Sandbox and API

    private func openSandbox() {
        luaL_requiref(L, "_G", luaopen_base, 1)
        clua_pop(L, 1)
        for (name, open) in [("table", luaopen_table), ("string", luaopen_string), ("math", luaopen_math), ("utf8", luaopen_utf8)] as [(String, lua_CFunction)] {
            luaL_requiref(L, name, open, 1)
            clua_pop(L, 1)
        }
        // os: only the clock and dates.
        luaL_requiref(L, "os", luaopen_os, 0)
        clua_newtable(L)
        for name in ["time", "date", "clock", "difftime"] {
            lua_getfield(L, -2, name)
            lua_setfield(L, -2, name)
        }
        lua_setglobal(L, "os")
        clua_pop(L, 1)
        for name in ["dofile", "loadfile", "load", "collectgarbage", "require"] {
            lua_pushnil(L)
            lua_setglobal(L, name)
        }
        // string.dump makes bytecode; nothing here may load it, but it has no use either.
        lua_getglobal(L, "string")
        lua_pushnil(L)
        lua_setfield(L, -2, "dump")
        clua_pop(L, 1)
    }

    private enum Function: Int32, CaseIterable {
        case every, badge, panel, peek, log, secret, repos, now, isotime, httpGet, httpPost, jsonEncode, jsonDecode
    }

    private func installAPI(settings: [String: Any], store: Data?) {
        let me = Unmanaged.passUnretained(self).toOpaque()
        func function(_ f: Function, _ name: String) {
            clua_pushfunction(L, me, f.rawValue)
            lua_setfield(L, -2, name)
        }
        clua_newtable(L)
        function(.every, "every")
        function(.badge, "badge")
        function(.panel, "panel")
        function(.peek, "peek")
        function(.log, "log")
        function(.secret, "secret")
        function(.repos, "repos")
        function(.now, "now")
        function(.isotime, "isotime")
        clua_newtable(L)
        function(.httpGet, "get")
        function(.httpPost, "post")
        lua_setfield(L, -2, "http")
        clua_newtable(L)
        function(.jsonEncode, "encode")
        function(.jsonDecode, "decode")
        lua_setfield(L, -2, "json")
        push(settings)
        lua_setfield(L, -2, "settings")
        push(store.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [String: Any]())
        lua_setfield(L, -2, "store")
        lua_pushvalue(L, -1)
        visorRef = luaL_ref(L, clua_registryindex())
        lua_setglobal(L, "visor")
        // print goes to the log too.
        clua_pushfunction(L, me, Function.log.rawValue)
        lua_setglobal(L, "print")
    }

    private static let installDispatch: Void = {
        clua_set_dispatch { L, ctx, fn in
            guard let L, let ctx, let function = Function(rawValue: fn) else { return 0 }
            return Unmanaged<LuaPlugin>.fromOpaque(ctx).takeUnretainedValue().dispatch(L, function)
        }
    }()

    /// Runs one `visor.*` function. Returns the number of results, or -1 with an
    /// error message pushed (raised by the C trampoline, never from Swift).
    private func dispatch(_ L: OpaquePointer, _ function: Function) -> Int32 {
        func fail(_ message: String) -> Int32 {
            lua_pushstring(L, message)
            return -1
        }
        switch function {
        case .every:
            guard lua_type(L, 1) == LUA_TNUMBER, lua_type(L, 2) == LUA_TFUNCTION else {
                return fail("visor.every(seconds, function) needs a number and a function")
            }
            let seconds = max(Self.minInterval, lua_tonumberx(L, 1, nil))
            lua_pushvalue(L, 2)
            let id = timers.count + 1
            timerRefs[id] = luaL_ref(L, clua_registryindex())
            timers.append(Timer(id: id, interval: seconds))
            return 0
        case .badge:
            output.badge = (value(at: 1) as? [String: Any]).map(badge)
            host?.show(output)
            return 0
        case .panel:
            let list = value(at: 1) as? [Any] ?? []
            output.sections = list.prefix(10).compactMap { ($0 as? [String: Any]).flatMap(section) }
            host?.show(output)
            return 0
        case .peek:
            guard let fields = value(at: 1) as? [String: Any], let title = fields["title"] as? String else {
                return fail("visor.peek needs { title = ... }")
            }
            host?.peek(PluginPeek(title: title, subtitle: fields["subtitle"] as? String ?? "",
                                  state: PluginState(loose: fields["state"] as? String), icon: fields["icon"] as? String))
            return 0
        case .log:
            let count = lua_gettop(L)
            let parts = (count > 0 ? (1...count) : 1...0).map { i -> String in
                switch lua_type(L, i) {
                case LUA_TNIL: return "nil"
                case LUA_TBOOLEAN: return lua_toboolean(L, i) != 0 ? "true" : "false"
                case LUA_TNUMBER, LUA_TSTRING: return string(at: i, convert: true) ?? ""
                default: return String(cString: lua_typename(L, lua_type(L, i)))
                }
            }
            host?.log(parts.joined(separator: " "))
            return 0
        case .secret:
            guard let name = string(at: 1), manifest.secrets[name] != nil else { lua_pushnil(L); return 1 }
            if let value = host?.secret(name, host: string(at: 2)) { lua_pushstring(L, value) } else { lua_pushnil(L) }
            return 1
        case .repos:
            push((host?.repos() ?? []).map { repo -> [String: Any] in
                var fields: [String: Any] = ["host": repo.host, "owner": repo.owner, "name": repo.name, "path": repo.path,
                                             "slug": "\(repo.owner)/\(repo.name)"]
                if let branch = repo.branch { fields["branch"] = branch }
                return fields
            })
            return 1
        case .now:
            lua_pushnumber(L, Date().timeIntervalSince1970)
            return 1
        case .isotime:
            guard let text = string(at: 1), let date = Self.parseDate(text) else { lua_pushnil(L); return 1 }
            lua_pushinteger(L, lua_Integer(date.timeIntervalSince1970))
            return 1
        case .httpGet, .httpPost:
            guard let text = string(at: 1), let url = URL(string: text) else { return fail("visor.http needs a URL") }
            guard manifest.allows(url) else {
                return fail("\(text) isn't allowed: add its host to \"hosts\" in plugin.json (https only)")
            }
            let options = value(at: 2) as? [String: Any] ?? [:]
            var headers = (options["headers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String ?? ($0 as? NSNumber)?.stringValue }
            if let auth = options["auth"] as? String {
                guard manifest.secrets[auth] != nil else { return fail("auth = \"\(auth)\" isn't a secret in plugin.json") }
                // The sign-in's host can differ from the API's (github.com vs api.github.com).
                let signIn = options["auth_host"] as? String ?? url.host
                if let token = host?.secret(auth, host: signIn) { headers["Authorization"] = "Bearer \(token)" }
            }
            var body: Data?
            if function == .httpPost {
                if let text = options["body"] as? String { body = Data(text.utf8) } else if let object = options["body"],
                   JSONSerialization.isValidJSONObject(object) {
                    body = try? JSONSerialization.data(withJSONObject: object)
                    headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
                }
            }
            guard let host else { return fail("Visor isn't running this plugin anymore") }
            let response = host.request(PluginRequest(method: function == .httpPost ? "POST" : "GET", url: url, headers: headers, body: body))
            var result: [String: Any] = ["status": response.status, "headers": response.headers, "cached": response.cached,
                                         "body": String(decoding: response.body, as: UTF8.self)]
            if let json = try? JSONSerialization.jsonObject(with: response.body, options: .fragmentsAllowed) { result["json"] = json }
            push(result)
            return 1
        case .jsonEncode:
            let object = value(at: 1) ?? NSNull()
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else {
                return fail("visor.json.encode: can't encode that value")
            }
            lua_pushstring(L, String(decoding: data, as: UTF8.self))
            return 1
        case .jsonDecode:
            guard let text = string(at: 1), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) else {
                lua_pushnil(L)
                return 1
            }
            push(object)
            return 1
        }
    }

    // MARK: Building outputs

    private func badge(_ fields: [String: Any]) -> PluginBadge {
        PluginBadge(icon: fields["icon"] as? String ?? manifest.icon, count: (fields["count"] as? NSNumber)?.intValue,
                    state: PluginState(loose: fields["state"] as? String), help: fields["help"] as? String ?? "")
    }

    private func section(_ fields: [String: Any]) -> PluginSection? {
        guard let title = fields["title"] as? String else { return nil }
        let rows = (fields["rows"] as? [Any] ?? []).prefix(50).compactMap { item -> PluginRow? in
            guard let row = item as? [String: Any], let title = row["title"] as? String else { return nil }
            let url = (row["url"] as? String).flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
            var time: Date?
            if let seconds = row["time"] as? NSNumber { time = Date(timeIntervalSince1970: seconds.doubleValue) }
            if let text = row["time"] as? String { time = Self.parseDate(text) }
            return PluginRow(title: title, detail: row["detail"] as? String ?? "", status: PluginState(loose: row["status"] as? String),
                             url: url, time: time)
        }
        return PluginSection(title: title, rows: Array(rows))
    }

    private static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    // MARK: Lua <-> Swift values

    /// A string at `index`. `convert` also turns numbers into strings (never for table keys).
    private func string(at index: Int32, convert: Bool = false) -> String? {
        let type = lua_type(L, index)
        guard type == LUA_TSTRING || (convert && type == LUA_TNUMBER) else { return nil }
        var length = 0
        guard let chars = lua_tolstring(L, index, &length) else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: chars, count: length), as: UTF8.self)
    }

    /// A Lua value as JSON-like Swift: tables with keys 1...n become arrays, others dictionaries.
    private func value(at index: Int32, depth: Int = 0) -> Any? {
        let i = lua_absindex(L, index)
        switch lua_type(L, i) {
        case LUA_TBOOLEAN: return lua_toboolean(L, i) != 0
        case LUA_TNUMBER: return lua_isinteger(L, i) != 0 ? Int(lua_tointegerx(L, i, nil)) : lua_tonumberx(L, i, nil)
        case LUA_TSTRING: return string(at: i)
        case LUA_TTABLE:
            guard depth < 32 else { return nil }
            var dictionary: [String: Any] = [:]
            var numbered: [Int: Any] = [:]
            lua_pushnil(L)
            while lua_next(L, i) != 0 {
                if let item = value(at: -1, depth: depth + 1) {
                    if lua_type(L, -2) == LUA_TNUMBER, lua_isinteger(L, -2) != 0 {
                        numbered[Int(lua_tointegerx(L, -2, nil))] = item
                    } else if let key = string(at: -2) {
                        dictionary[key] = item
                    }
                }
                clua_pop(L, 1)
            }
            if dictionary.isEmpty, !numbered.isEmpty, Set(numbered.keys) == Set(1...numbered.count) {
                return (1...numbered.count).map { numbered[$0]! }
            }
            for (key, item) in numbered { dictionary[String(key)] = item }
            return dictionary
        default: return nil
        }
    }

    private func push(_ value: Any?) {
        switch value {
        case nil, is NSNull: lua_pushnil(L)
        // NSNumber first and whole: JSON's 0 and 1 would also pass as Bool.
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                lua_pushboolean(L, number.boolValue ? 1 : 0)
            } else if CFNumberIsFloatType(number) {
                lua_pushnumber(L, number.doubleValue)
            } else {
                lua_pushinteger(L, lua_Integer(number.int64Value))
            }
        case let text as String: lua_pushstring(L, text)
        case let array as [Any]:
            lua_createtable(L, Int32(array.count), 0)
            for (index, item) in array.enumerated() {
                push(item)
                lua_rawseti(L, -2, lua_Integer(index + 1))
            }
        case let dictionary as [String: Any]:
            lua_createtable(L, 0, Int32(dictionary.count))
            for (key, item) in dictionary {
                lua_pushstring(L, key)
                push(item)
                lua_rawset(L, -3)
            }
        default: lua_pushnil(L)
        }
    }
}
