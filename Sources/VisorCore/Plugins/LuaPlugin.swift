import CLua
import Foundation

/// One plugin: its own Lua 5.4 state, sandboxed, with the `visor` table as its
/// only way out. Not thread-safe: use each plugin from one serial queue.
///
/// Sandbox: the base, string, table, math and utf8 libraries, plus os.time,
/// os.date and os.clock. No io, os.execute, require, load, debug or bytecode.
/// Every call into the plugin has an instruction budget, so a loop that never
/// ends is stopped with an error instead of hanging Visor, and a memory cap.
/// Plugins never see secrets: Visor attaches a sign-in to a request itself, and
/// only for the host it belongs to. Floods (views, peeks, requests, timers,
/// stored data) are rationed so a plugin can't slow the notch.
public final class LuaPlugin {
    public struct Timer: Equatable, Sendable {
        public let id: Int
        public let interval: TimeInterval
    }

    /// Instructions per call: a fraction of a second of pure Lua.
    public static var budget = 20_000_000
    /// No plugin runs more often than this, or less often than weekly.
    public static var minInterval: TimeInterval = 30
    public static let maxInterval: TimeInterval = 7 * 86400
    /// Memory a plugin's Lua may use.
    public static let memoryLimit = 64 * 1024 * 1024
    public static let maxTimers = 10
    public static let maxHandlers = 50
    public static let maxRequestsPerCall = 30
    /// visor.store, as JSON.
    public static let maxStore = 1024 * 1024
    /// At most one peek per call, and one per this many seconds.
    public static let peekGap: TimeInterval = 10

    public let manifest: PluginManifest
    public private(set) var timers: [Timer] = []

    private let L: OpaquePointer
    private weak var host: PluginHost?
    private var timerRefs: [Int: Int32] = [:]
    private var actionRefs: [String: Int32] = [:]
    private var visorRef: Int32 = 0
    private var mainRef: Int32 = 0
    private var output = PluginOutput()
    /// Something to show changed during this call; sent once when it ends.
    private var outputChanged = false
    private var savedStore: Data?
    private var requestsThisCall = 0
    private var peekedThisCall = false
    private var lastPeek = Date.distantPast

    public init(manifest: PluginManifest, source: String, host: PluginHost, store: Data? = nil, settings: [String: Any] = [:]) throws {
        guard let state = clua_newstate(Self.memoryLimit) else { throw PluginError.lua("Lua couldn't start (out of memory)") }
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
        try run(Self.prelude)
    }

    /// visor.ui: each piece is a table that remembers its kind. Lua, so the
    /// tables are plain and visor.view reads them like any other value.
    private static let prelude = """
    local ui = {}
    for _, kind in ipairs({ "stack", "columns", "text", "stats", "stat", "meter", "bars", "chips", "list",
                            "table", "clock", "progress", "buttons", "button", "picker", "toggle" }) do
      ui[kind] = function(t) t = t or {}; t.kind = kind; return t end
    end
    ui.divider = function() return { kind = "divider" } end
    visor.ui = ui

    -- No finalizers: __gc runs plugin code at times Visor doesn't choose (and on close).
    do
      local raw = setmetatable
      setmetatable = function(t, mt)
        if type(mt) == "table" and rawget(mt, "__gc") ~= nil then error("__gc isn't allowed in plugins", 2) end
        return raw(t, mt)
      end
    end
    """

    // The budget stays on while closing, as a second guard on anything closing runs.
    deinit {
        clua_set_budget(L, Self.budget)
        clua_close(L)
    }

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

    /// Runs the `visor.on` handler for a button, picker or toggle, with its value.
    /// Does nothing when the plugin has no handler by that name.
    public func act(_ name: String, value: Any?) throws {
        guard let ref = actionRefs[name] else { return }
        lua_rawgeti(L, clua_registryindex(), lua_Integer(ref))
        push(value)
        try callTop(arguments: 1)
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

    /// Calls the function below its arguments on the stack with the budget on, then saves the store if it changed.
    private func callTop(arguments: Int32 = 0) throws {
        requestsThisCall = 0
        peekedThisCall = false
        clua_set_budget(L, Self.budget)
        clua_enforce(L, 1)
        let status = clua_pcall(L, arguments, 0)
        clua_enforce(L, 0)
        clua_set_budget(L, 0)
        // One update per call, however many times the plugin showed something.
        if outputChanged {
            outputChanged = false
            host?.show(output)
        }
        let storeError = saveStore()
        guard status == LUA_OK else {
            let message = string(at: -1) ?? "error"
            clua_pop(L, 1)
            throw PluginError.lua(message)
        }
        if let storeError { throw PluginError.lua(storeError) }
    }

    /// Saves visor.store when it changed. Read raw: a metatable on visor never runs here.
    private func saveStore() -> String? {
        lua_rawgeti(L, clua_registryindex(), lua_Integer(visorRef))
        lua_pushstring(L, "store")
        lua_rawget(L, -2)
        let store = value(at: -1) ?? [String: Any]()
        clua_pop(L, 2)
        guard JSONSerialization.isValidJSONObject(store),
              let data = try? JSONSerialization.data(withJSONObject: store, options: [.sortedKeys]),
              data != savedStore else { return nil }
        guard data.count <= Self.maxStore else { return "visor.store is over 1 MB and wasn't saved" }
        savedStore = data
        host?.saveStore(data)
        return nil
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
        case every, badge, panel, view, on, peek, log, repos, now, isotime, httpGet, jsonEncode, jsonDecode
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
        function(.view, "view")
        function(.on, "on")
        function(.peek, "peek")
        function(.log, "log")
        function(.repos, "repos")
        function(.now, "now")
        function(.isotime, "isotime")
        clua_newtable(L)
        // Read-only: GET only, so a plugin can look but never change anything.
        function(.httpGet, "get")
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
            guard timers.count < Self.maxTimers else { return fail("visor.every: at most \(Self.maxTimers) timers") }
            let raw = lua_tonumberx(L, 1, nil)
            let seconds = raw.isFinite ? min(Self.maxInterval, max(Self.minInterval, raw)) : Self.minInterval
            lua_pushvalue(L, 2)
            let id = timers.count + 1
            timerRefs[id] = luaL_ref(L, clua_registryindex())
            timers.append(Timer(id: id, interval: seconds))
            return 0
        case .badge:
            output.badge = (value(at: 1) as? [String: Any]).map(badge)
            outputChanged = true
            return 0
        case .panel:
            let list = value(at: 1) as? [Any] ?? []
            output.sections = list.prefix(10).compactMap { ($0 as? [String: Any]).flatMap(section) }
            outputChanged = true
            return 0
        case .view:
            output.view = value(at: 1).flatMap(PluginNode.decode)
            outputChanged = true
            return 0
        case .on:
            guard let name = string(at: 1), lua_type(L, 2) == LUA_TFUNCTION else {
                return fail("visor.on(name, function) needs a name and a function")
            }
            guard actionRefs[name] != nil || actionRefs.count < Self.maxHandlers else {
                return fail("visor.on: at most \(Self.maxHandlers) handlers")
            }
            lua_pushvalue(L, 2)
            if let old = actionRefs[name] { luaL_unref(L, clua_registryindex(), old) }
            actionRefs[name] = luaL_ref(L, clua_registryindex())
            return 0
        case .peek:
            guard let fields = value(at: 1) as? [String: Any], let title = fields["title"] as? String else {
                return fail("visor.peek needs { title = ... }")
            }
            // Rationed: the notch is for news, not a ticker.
            guard !peekedThisCall, Date().timeIntervalSince(lastPeek) >= Self.peekGap else { return 0 }
            peekedThisCall = true
            lastPeek = Date()
            host?.peek(PluginPeek(title: String(title.prefix(120)), subtitle: String((fields["subtitle"] as? String ?? "").prefix(120)),
                                  state: PluginState(loose: fields["state"] as? String), icon: (fields["icon"] as? String).map { String($0.prefix(60)) }))
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
        case .httpGet:
            guard let text = string(at: 1), let url = URL(string: text) else { return fail("visor.http needs a URL") }
            guard manifest.allows(url) else {
                return fail("\(text) isn't allowed: add its host to \"hosts\" in plugin.json (https only)")
            }
            guard requestsThisCall < Self.maxRequestsPerCall else {
                return fail("visor.http: at most \(Self.maxRequestsPerCall) requests per call")
            }
            requestsThisCall += 1
            let options = value(at: 2) as? [String: Any] ?? [:]
            // Header names are tokens and values single lines: nothing can be smuggled into the request.
            var headers: [String: String] = [:]
            for (name, item) in options["headers"] as? [String: Any] ?? [:] {
                guard let text = item as? String ?? (item as? NSNumber)?.stringValue, Self.isHeaderName(name),
                      !text.contains("\r"), !text.contains("\n") else { continue }
                headers[name] = text
            }
            if let auth = options["auth"] as? String {
                switch signIn(auth, for: url, options: options) {
                case .failure(let error): return fail(error.message)
                case .success(let header):
                    if let header { headers[header.name] = header.value }
                }
            }
            guard let host else { return fail("Visor isn't running this plugin anymore") }
            let response = host.request(PluginRequest(method: "GET", url: url, headers: headers, body: nil))
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
        PluginBadge(icon: String((fields["icon"] as? String ?? manifest.icon).prefix(60)),
                    count: (fields["count"] as? NSNumber).map { Int(clamping: Int64(max(-1e15, min(1e15, $0.doubleValue)))) },
                    state: PluginState(loose: fields["state"] as? String), help: String((fields["help"] as? String ?? "").prefix(200)))
    }

    // MARK: Sign-ins

    /// The header that signs a request in with secret `name`, or why it can't.
    /// Plugins never see the secret; Visor adds it here, and only for its own host:
    /// a "{host}" secret (gh) for the sign-in's host and its subdomains
    /// (github.com → api.github.com), any other secret only for the hosts it names.
    private func signIn(_ name: String, for url: URL, options: [String: Any]) -> Result<(name: String, value: String)?, SignInError> {
        guard let secret = manifest.secrets[name] else { return .failure(SignInError("auth = \"\(name)\" isn't a secret in plugin.json")) }
        let requestHost = (url.host ?? "").lowercased()
        var hostForCommand: String?
        if secret.command.contains("{host}") {
            let signIn = (options["auth_host"] as? String)?.lowercased() ?? requestHost
            guard requestHost == signIn || requestHost.hasSuffix("." + signIn) else {
                return .failure(SignInError("the \(name) sign-in for \(signIn) can't be sent to \(requestHost)"))
            }
            hostForCommand = signIn
        } else {
            guard PluginManifest(id: "x", name: "x", hosts: secret.hosts).allows(url) else {
                return .failure(SignInError("\(name) can only be sent to \(secret.hosts.joined(separator: ", "))"))
            }
        }
        let headerName = options["auth_header"] as? String ?? "Authorization"
        let scheme = options["auth_scheme"] as? String ?? "Bearer"
        guard Self.isHeaderName(headerName), scheme.range(of: #"^[A-Za-z0-9-]{0,20}$"#, options: .regularExpression) != nil else {
            return .failure(SignInError("auth_header must be a header name and auth_scheme a single word"))
        }
        guard let token = host?.secret(name, host: hostForCommand), !token.contains("\r"), !token.contains("\n") else { return .success(nil) }
        return .success((headerName, scheme.isEmpty ? token : "\(scheme) \(token)"))
    }

    struct SignInError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static func isHeaderName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil
    }

    private func section(_ fields: [String: Any]) -> PluginSection? {
        guard let title = fields["title"] as? String else { return nil }
        let rows = (fields["rows"] as? [Any] ?? []).prefix(50).compactMap { ($0 as? [String: Any]).flatMap(PluginRow.decode) }
        return PluginSection(title: title, rows: Array(rows))
    }

    private static func parseDate(_ text: String) -> Date? { PluginRow.parseDate(text) }

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
            // lua_next needs two slots per level; make room so deep tables can't overrun the stack.
            guard depth < 32, lua_checkstack(L, 4) != 0 else { return nil }
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

    /// Pushes a value. Room is made on the stack first, and nesting past 64 becomes nil,
    /// so deep JSON from a server can't overrun Lua's stack.
    private func push(_ value: Any?, depth: Int = 0) {
        guard lua_checkstack(L, 3) != 0 else { return }
        guard depth < 64 else { lua_pushnil(L); return }
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
                push(item, depth: depth + 1)
                lua_rawseti(L, -2, lua_Integer(index + 1))
            }
        case let dictionary as [String: Any]:
            lua_createtable(L, 0, Int32(dictionary.count))
            for (key, item) in dictionary {
                lua_pushstring(L, key)
                push(item, depth: depth + 1)
                lua_rawset(L, -3)
            }
        default: lua_pushnil(L)
        }
    }
}
