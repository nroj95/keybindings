#Requires AutoHotkey v2.0

; =============================================================================
; keybindings.ahk - reusable, opt-in keybinding manager for AutoHotkey v2
; version: 0.2.0-preview.5 | settings/registry schema: 1 | layer protocol: 1
; =============================================================================
; responsibilities
;   - give actions stable IDs, two editable binding slots and one saved setup.
;   - register ordinary hotkeys locally and layer bindings through a supplied
;     CapsPauseClient factory. never launch the layer service or own its keys.
;   - coordinate participating scripts through per-owner manifests and a bounded
;     named mutex. no additional background program or machine-wide installation.
;   - provide Minecraft-style in-place press-to-bind keyboard/mouse capture.
;
; integration
;   manager := Keybindings("my-script", "My Script", options)
;   manager.AddAction(id, label, callback, defaultBindings, actionOptions)
;   manager.Start()
;   manager.ShowSettings()
;   callback(event): phase = down / repeat / up / cancel. act on down for a
;   one-shot command. callbacks MUST be short; schedule slow work separately.
;
; scope of this preview
;   - global contexts; exact Ctrl/Alt/Shift/Win modifiers, either side equivalent.
;   - ordinary keyboard/mouse shortcuts; keyboard suffixes for layer protocol 1.
;   - no arbitrary expressions, wildcard bindings, custom prefix pairs, sequences,
;     hotstrings, controller input, or automatic detection of unrelated programs.
;   - ordinary bindings are global, so an identical key/modifier combination in
;     a layer overlaps them and is rejected. Caps and Pause remain disjoint.
;     Protocol 1 does not expose a one-shot state query to other processes; do
;     not depend on keyboard-hook installation order to resolve these overlaps.
;   - all keyboard bindings use physical scan codes where available. settings do
;     not silently change key position when the active keyboard layout changes.
;
; safety
;   - including this file does not start anything. use one manager per process.
;   - configuration is data, never executable code. unknown schema = fail closed.
;   - the first running claimant keeps its binding. never silently steal/remap it.
;   - do not mix managed and hardcoded hotkeys for the same inputs in one script.
;   - consumers remain responsible for releasing their own synthesized outputs
;     on up, cancel, Stop and exit; another process cannot do that for them.
; =============================================================================

class Keybindings {
    static Version := "0.2.0-preview.5"
    static Current := 0

    __New(ownerId, displayName, options := {}) {
        Keybindings.Id(ownerId)
        Keybindings.Text(displayName, 100)
        if IsObject(Keybindings.Current)
            throw Error("Use one Keybindings manager per script; add all actions to it.")
        this.id := ownerId
        this.name := displayName
        ; One configured shortcut set. Earlier preview's selected profile is
        ; imported on first load without discarding customized keybindings.
        this.root := RTrim(Keybindings.Option(options, "directory",
            EnvGet("LOCALAPPDATA") "\nroj\AutoHotkey\keybindings-v1"), "\/")
        if this.root = "" || !RegExMatch(this.root, "i)^(?:[a-z]:\\|\\\\)")
            throw ValueError("The settings directory must be an absolute Windows path.")
        this.path := this.root "\" ownerId ".ini"
        this.scope := Format("{:08X}", Keybindings.Hash(StrLower(this.root)))
        this.mutexPrefix := "Local\nroj.Keybindings.v1." this.scope
        this.captureTitle := "nroj.Keybindings.v1.Capture." this.scope
        this.layerFactory := Keybindings.Option(options, "layerFactory", 0)
        this.statusCallback := Keybindings.Option(options, "statusCallback", 0)
        this.actions := Map()
        this.configuration := Map()
        this.document := Map()
        this.routes := []
        this.routeMap := Map()
        this.variants := Map()
        this.groups := Map()
        this.pressed := Map()
        this.blocked := Map()
        this.queue := []
        this.delivered := Map()
        this.nextToken := 0
        this.dispatching := false
        this.running := false
        this.applying := false
        this.disposed := false
        this.settings := 0
        this.client := 0
        this.ownerMutex := 0
        this.registryMutex := 0
        this.recording := 0
        this.externalCapture := false
        this.paused := false
        this.gated := false
        this.rows := []
        this.visibleRows := []
        this.scrollPosition := 0
        this.wheelRemainder := 0
        this.wheelCallback := ObjBindMethod(this, "_WheelSettings")
        this.wheelHookActive := false
        this.verticalScrollCallback := ObjBindMethod(this, "_VerticalScrollSettings")
        this.verticalScrollHookActive := false
        this.captureMouse := Map()
        this.firstRun := false
        this.releaseCallback := ObjBindMethod(this, "_CheckReleases")
        this.drainCallback := ObjBindMethod(this, "_Drain")
        this.maintenanceCallback := ObjBindMethod(this, "_Maintain")
        this.noticeCallback := ObjBindMethod(this, "_Notice")
        this.exitCallback := ObjBindMethod(this, "Stop")
        this.message := DllCall("RegisterWindowMessageW", "str",
            "nroj.Keybindings.v1.CaptureChanged", "uint")
        if !this.message
            throw OSError(A_LastError, "RegisterWindowMessageW")
        Keybindings.Current := this
    }

    ; defaults: ["Caps + J", "Ctrl + Alt + F9"]
    AddAction(actionId, label, callback, defaults := 0, options := {}) {
        if this.running || this.disposed
            throw Error("Define actions before Start().")
        Keybindings.Id(actionId)
        Keybindings.Text(label, 120)
        if this.actions.Has(actionId) || this.actions.Count >= 128
            throw ValueError("Duplicate action ID or the 128-action limit was reached.")
        if !HasMethod(callback, "Call")
            throw TypeError("An action callback must be callable.")
        category := Keybindings.Option(options, "category", "general")
        Keybindings.Text(category, 80)
        action := {id: actionId, label: label, callback: callback, category: category,
            repeat: !!Keybindings.Option(options, "repeat", false),
            defaultEnabled: !!Keybindings.Option(options, "enabled", true),
            defaults: this._NormalizeSlots(IsObject(defaults) ? defaults : [])}
        this.actions[actionId] := action
        return this
    }

    Start() {
        if this.running
            return this
        if this.disposed
            throw Error("A stopped manager cannot be restarted; reload the script.")
        DirCreate this.root
        this.registryMutex := DllCall("CreateMutexW", "ptr", 0, "int", false,
            "str", this.mutexPrefix ".Registry", "ptr")
        if !this.registryMutex
            throw OSError(A_LastError, "CreateMutexW")
        this.ownerMutex := DllCall("CreateMutexW", "ptr", 0, "int", false,
            "str", this._OwnerMutexName(this.id), "ptr")
        ownerError := A_LastError
        if !this.ownerMutex || ownerError = 183 {
            if this.ownerMutex
                DllCall("CloseHandle", "ptr", this.ownerMutex)
            this.ownerMutex := 0
            DllCall("CloseHandle", "ptr", this.registryMutex)
            this.registryMutex := 0
            throw Error("Another copy of " this.name " is already running, or its owner lock is unavailable.")
        }
        OnExit this.exitCallback
        OnMessage(this.message, this.noticeCallback)
        this.running := true
        try {
            this._Load()
            if HasMethod(this.layerFactory, "Call")
                this.client := this.layerFactory.Call(this.name, ObjBindMethod(this, "_Report"))
            this._Commit(this.configuration, false, true)
            this._Maintain()
            SetTimer(this.maintenanceCallback, 2000)
            this._Report("keybindings ready")
        }
        catch Error as startError {
            this.Stop()
            throw startError
        }
        return this
    }

    Stop(*) {
        if this.disposed
            return
        this.disposed := true
        this.running := false
        try this._EndRecording()
        try this._CloseSettings()
        SetTimer(this.maintenanceCallback, 0)
        SetTimer(this.releaseCallback, 0)
        SetTimer(this.drainCallback, 0)
        try this._Deactivate()
        ; OnExit cannot rely on a queued timer to release a consumer's held output.
        for token, item in this.delivered.Clone() {
            this.delivered.Delete(token)
            event := item.event.Clone()
            event.phase := "cancel"
            this._Invoke(item.route, event)
        }
        this.queue := []
        this.pressed.Clear()
        this.blocked.Clear()
        try OnMessage(this.message, this.noticeCallback, 0)
        try OnExit(this.exitCallback, 0)
        if this.registryMutex
            DllCall("CloseHandle", "ptr", this.registryMutex)
        this.registryMutex := 0
        ; The manifest remains as a configured-binding warning. Windows removes
        ; this presence signal on exit/crash, so it cannot reserve active keys.
        if this.ownerMutex
            DllCall("CloseHandle", "ptr", this.ownerMutex)
        this.ownerMutex := 0
    }

    ; Returns a defensive copy of the single saved configuration.
    GetConfiguration() => this._CloneConfiguration(this.configuration)

    Apply(configuration, acceptSavedConflicts := false) {
        if !this.running || this.disposed
            throw Error("Start the manager before applying configuration.")
        this._Commit(configuration, true, acceptSavedConflicts)
    }

    ; Consumers can pause inputs for a module selector or power transition
    ; without erasing enabled flags, releasing registry ownership or restarting.
    SetPaused(paused := true) {
        if this.disposed
            return
        this.paused := !!paused
        if this.running
            this._RefreshGate()
    }

    GetStatus() {
        result := []
        for route in this.routes {
            state := route.state
            if IsObject(route.specification)
                state := route.specification.state
            result.Push({actionId: route.action.id, label: route.action.label,
                slot: route.slot, binding: route.binding.label, state: state})
        }
        return result
    }

    ; =========================================================================
    ; binding grammar and normalization (no hotkeys or file I/O)
    ; =========================================================================

    static Parse(text) {
        if Type(text) != "String"
            throw TypeError("A keybinding must be text.")
        text := Trim(text)
        if text = ""
            return 0
        if StrLen(text) > 140 || RegExMatch(text, "[\t\r\n]")
            throw ValueError("Invalid keybinding text.")
        layer := "normal"
        mask := 0
        keyName := ""
        if RegExMatch(text, "i)^(normal|caps|pause)\|([0-9]{1,2})\|([a-z0-9]+)$", &stored) {
            layer := StrLower(stored[1])
            mask := Integer(stored[2])
            keyName := stored[3]
            if mask > 15
                throw ValueError("Invalid saved modifier mask.")
        } else if RegExMatch(text, "^([\^!+#]+)([^\s+]+)$", &native) {
            for symbol in StrSplit(native[1]) {
                bit := InStr("^!+#", symbol)
                value := 1 << (bit - 1)
                if mask & value
                    throw ValueError("Repeated modifier.")
                mask |= value
            }
            keyName := native[2]
        } else {
            parts := StrSplit(text, "+")
            for index, part in parts {
                part := Trim(part)
                if part = ""
                    throw ValueError("Use a key name/scan code, not a literal + character.")
                lower := StrLower(part)
                if index = parts.Length {
                    keyName := part
                    break
                }
                if lower = "caps" || lower = "capslock" || lower = "pause" {
                    if layer != "normal"
                        throw ValueError("Only one CapsLock/Pause layer can be selected.")
                    layer := lower = "pause" ? "pause" : "caps"
                } else {
                    modifiers := Map("ctrl", 1, "control", 1, "alt", 2, "shift", 4, "win", 8)
                    if !modifiers.Has(lower) || mask & modifiers[lower]
                        throw ValueError("Use Ctrl, Alt, Shift or Win once before the base key.")
                    mask |= modifiers[lower]
                }
            }
        }
        key := Keybindings._BaseKey(keyName)
        if layer != "normal" && key.mouse
            throw ValueError("Layer protocol 1 supports keyboard suffixes only. Use an ordinary mouse binding.")
        if (mask = 3 && key.vk = 0x2E) || ((mask & 8) && key.vk = 0x4C)
            throw ValueError("Ctrl + Alt + Delete and Win + L are reserved by Windows.")
        prefix := layer = "caps" ? "Caps + " : layer = "pause" ? "Pause + " : ""
        for bit, name in Map(1, "Ctrl", 2, "Alt", 4, "Shift", 8, "Win")
            if mask & bit
                prefix .= name " + "
        return {layer: layer, modifiers: mask, key: key.code, mouse: key.mouse,
            wheel: key.wheel, label: prefix key.label,
            signature: layer "|" mask "|" StrLower(key.code)}
    }

    static _BaseKey(name) {
        if name = "" || StrLen(name) > 32 || RegExMatch(name, "[\s{}&~*$<>!^#+|]")
            throw ValueError("Use a base key name or scNNN; custom combinations are not supported.")
        mouseNames := Map("lbutton", "LButton", "rbutton", "RButton", "mbutton", "MButton",
            "xbutton1", "XButton1", "xbutton2", "XButton2", "wheelup", "WheelUp",
            "wheeldown", "WheelDown", "wheelleft", "WheelLeft", "wheelright", "WheelRight")
        lower := StrLower(name)
        if mouseNames.Has(lower)
            return {code: mouseNames[lower], label: mouseNames[lower], vk: 0,
                mouse: true, wheel: InStr(lower, "wheel") = 1}
        if RegExMatch(name, "i)^sc([0-9a-f]{3})$", &scanMatch) {
            scan := Integer("0x" scanMatch[1])
            if scan = 0 || scan > 0x1FF
                throw ValueError("Invalid scan code.")
            vk := GetKeyVK(name)
        } else {
            normalized := GetKeyName(name)
            vk := GetKeyVK(normalized)
            scan := GetKeySC(normalized)
            if !vk && !scan
                throw ValueError("Unknown key: " name)
        }
        if vk = 1 || vk = 2 || vk = 4 || vk = 5 || vk = 6
            throw ValueError("Use a named mouse button, not a virtual-key alias.")
        if vk = 0x14 || vk = 0x13 || vk = 3 || vk = 0x10 || vk = 0x11 || vk = 0x12
            || (vk >= 0xA0 && vk <= 0xA5) || vk = 0x5B || vk = 0x5C
            || RegExMatch(name, "i)^Joy")
            throw ValueError("A modifier or layer activation key cannot be the base key.")
        for reserved in ["CapsLock", "Pause", "CtrlBreak", "LControl", "RControl",
            "LAlt", "RAlt", "LShift", "RShift", "LWin", "RWin"]
            if scan && scan = GetKeySC(reserved)
                throw ValueError("This physical key is reserved for modifier/layer handling.")
        code := scan ? Format("sc{:03X}", scan) : Format("vk{:02X}", vk)
        friendly := GetKeyName(code)
        if friendly = ""
            friendly := code
        if StrLen(friendly) = 1
            friendly := StrUpper(friendly)
        return {code: code, label: friendly, vk: vk, mouse: false, wheel: false}
    }

    static ConflictingSignature(binding, index) {
        if index.Has(binding.signature)
            return binding.signature
        suffix := "|" binding.modifiers "|" StrLower(binding.key)
        if binding.layer = "normal" {
            for layer in ["caps", "pause"]
                if index.Has(layer suffix)
                    return layer suffix
        } else if index.Has("normal" suffix) {
            return "normal" suffix
        }
        return ""
    }

    static ModifierMask() {
        return (GetKeyState("Ctrl", "P") ? 1 : 0)
            | (GetKeyState("Alt", "P") ? 2 : 0)
            | (GetKeyState("Shift", "P") ? 4 : 0)
            | ((GetKeyState("LWin", "P") || GetKeyState("RWin", "P")) ? 8 : 0)
    }

    static Symbols(mask) {
        result := ""
        for bit, symbol in Map(1, "^", 2, "!", 4, "+", 8, "#")
            if mask & bit
                result .= symbol
        return result
    }

    static Option(options, name, fallback) => HasProp(options, name) ? options.%name% : fallback

    static Id(text) {
        if Type(text) != "String" || !RegExMatch(text, "^[a-z0-9][a-z0-9_.-]{0,63}$")
            throw ValueError("IDs must use lowercase ASCII letters, numbers, dots, hyphens or underscores.")
        if RegExMatch(text, "i)^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)")
            throw ValueError("This ID is a reserved Windows filename.")
    }

    static Text(text, limit) {
        if Type(text) != "String" || text = "" || StrLen(text) > limit
            || RegExMatch(text, "[\t\r\n]")
            throw ValueError("Invalid label text.")
    }

    static Hash(text) {
        value := 2166136261
        loop parse text
            value := ((value ^ Ord(A_LoopField)) * 16777619) & 0xFFFFFFFF
        return value
    }

    _NormalizeSlots(bindings) {
        if !(bindings is Array) || bindings.Length > 2
            throw ValueError("This preview supports two binding slots per action.")
        result := ["", ""]
        for index, text in bindings {
            binding := Keybindings.Parse(text)
            result[index] := IsObject(binding) ? binding.signature : ""
        }
        return result
    }

    _CloneConfiguration(source) {
        result := Map()
        for actionId, setting in source
            result[actionId] := {enabled: setting.enabled, bindings: setting.bindings.Clone()}
        return result
    }

    _DefaultConfiguration() {
        result := Map()
        for actionId, action in this.actions
            result[actionId] := {enabled: action.defaultEnabled, bindings: action.defaults.Clone()}
        return result
    }

    ; =========================================================================
    ; data-only manifests and cooperative conflict arbitration
    ; =========================================================================

    _Load() {
        this.firstRun := !FileExist(this.path)
        this.document := KB_Manifest.Read(this.path)
        if !this.firstRun && !this.document.Count
            throw Error("The existing settings file is empty or damaged; it was not overwritten.")
        if this.document.Count {
            KB_Manifest.Validate(this.document)
            if KB_Manifest.Get(this.document, "meta", "id") != this.id
                throw Error("Settings owner mismatch; the file was not modified.")
        }
        this.configuration := this._DefaultConfiguration()
        ; Migrate the previously selected profile. Never guess which of the two
        ; legacy profiles mattered, and never overwrite a damaged saved value.
        section := "bindings"
        if !this.document.Has(section) {
            legacyProfile := KB_Manifest.Get(this.document, "meta", "profile", "standalone")
            section := "profile:" legacyProfile
        }
        for actionId, action in this.actions {
            value := KB_Manifest.Get(this.document, section, actionId, "")
            if value = ""
                continue
            fields := StrSplit(value, "`t")
            if fields.Length != 3 || (fields[1] != "0" && fields[1] != "1")
                throw Error("Invalid saved settings for " actionId "; nothing was overwritten.")
            this.configuration[actionId] := {enabled: fields[1] = "1",
                bindings: this._NormalizeSlots([fields[2], fields[3]])}
        }
    }

    _OwnerMutexName(ownerId) => this.mutexPrefix ".Owner." ownerId

    _OwnerAlive(ownerId) {
        handle := DllCall("OpenMutexW", "uint", 0x100000, "int", false,
            "str", this._OwnerMutexName(ownerId), "ptr")
        if !handle {
            ; Access-denied is not proof that the other owner is dead.
            if A_LastError != 2
                throw OSError(A_LastError, "OpenMutexW", "Could not verify keybinding ownership.")
            return false
        }
        DllCall("CloseHandle", "ptr", handle)
        return true
    }

    _Lock() {
        previousCritical := A_IsCritical
        Critical "On"
        ; Bounded file-only transaction. No GUI, network, callbacks or IPC while
        ; holding this mutex; the hotkey path never takes this lock.
        result := DllCall("WaitForSingleObject", "ptr", this.registryMutex, "uint", 250, "uint")
        if result != 0 && result != 0x80 {
            Critical previousCritical
            throw Error("The keybinding registry is busy or inaccessible; try again.")
        }
        ; An abandoned mutex still grants ownership. Every manifest is parsed and
        ; validated below before it is trusted, rather than assuming consistency.
        return previousCritical
    }

    _Unlock(previousCritical) {
        DllCall("ReleaseMutex", "ptr", this.registryMutex)
        Critical previousCritical
    }

    _Owners() {
        owners := []
        loop files this.root "\*.ini", "F" {
            document := KB_Manifest.Read(A_LoopFileFullPath)
            KB_Manifest.Validate(document)
            ownerId := KB_Manifest.Get(document, "meta", "id")
            Keybindings.Id(ownerId)
            if A_LoopFileName != ownerId ".ini"
                throw Error("Registry owner/filename mismatch: " A_LoopFileName)
            if ownerId = this.id
                continue
            owner := {id: ownerId, name: KB_Manifest.Get(document, "meta", "name"),
                alive: this._OwnerAlive(ownerId), document: document,
                hwnd: Integer(KB_Manifest.Get(document, "meta", "hwnd", "0")),
                pid: Integer(KB_Manifest.Get(document, "meta", "pid", "0"))}
            owners.Push(owner)
        }
        return owners
    }

    _CandidateRoutes(configuration) {
        normalized := Map()
        routes := []
        layerCount := 0
        for actionId, action in this.actions {
            if !configuration.Has(actionId)
                throw ValueError("Missing action settings: " actionId)
            setting := configuration[actionId]
            slots := this._NormalizeSlots(setting.bindings)
            normalized[actionId] := {enabled: !!setting.enabled, bindings: slots}
            if !setting.enabled
                continue
            for slot, text in slots {
                binding := Keybindings.Parse(text)
                if !IsObject(binding)
                    continue
                if binding.layer != "normal"
                    layerCount += 1
                routes.Push({action: action, slot: slot, binding: binding, enabled: false,
                    state: "pending", specification: 0, token: 0, foreground: 0, oneShot: false})
            }
        }
        if layerCount > 128
            throw ValueError("Layer protocol 1 permits at most 128 layer bindings per client.")
        return {configuration: normalized, routes: routes}
    }

    _Commit(configuration, strict, acceptSaved) {
        if this.applying
            throw Error("A keybinding update is already in progress.")
        candidate := this._CandidateRoutes(configuration)
        oldRoutes := this.routes
        oldConfiguration := this.configuration
        oldDocument := this.document
        this.applying := true
        published := false
        try {
            ; Disable old inputs BEFORE releasing their published claims. Retain
            ; their claims if validation fails, then restore the old runtime.
            this._Deactivate()
            previousCritical := this._Lock()
            try {
                owners := this._Owners()
                occupied := Map()
                configured := Map()
                for owner in owners {
                    for section in ["configured", "claims"] {
                        if !owner.document.Has(section)
                            continue
                        for signature, description in owner.document[section] {
                            parsed := Keybindings.Parse(signature)
                            if !IsObject(parsed) || parsed.signature != signature
                                throw Error("Invalid registry binding for " owner.name)
                            detail := owner.name " / " description
                            if section = "claims" && owner.alive
                                occupied[signature] := detail
                            else if section = "configured"
                                configured[signature] := {detail: detail, alive: owner.alive}
                        }
                    }
                }
                seen := Map()
                conflicts := []
                savedWarnings := []
                for route in candidate.routes {
                    signature := route.binding.signature
                    description := route.action.label " (slot " route.slot ")"
                    localConflict := Keybindings.ConflictingSignature(route.binding, seen)
                    activeConflict := Keybindings.ConflictingSignature(route.binding, occupied)
                    savedConflict := Keybindings.ConflictingSignature(route.binding, configured)
                    if localConflict != "" {
                        route.state := "conflict: " seen[localConflict]
                        conflicts.Push(route.binding.label " overlaps " seen[localConflict])
                    } else if activeConflict != "" {
                        route.state := "conflict: " occupied[activeConflict]
                        conflicts.Push(route.binding.label " overlaps the binding reserved by " occupied[activeConflict])
                    } else {
                        route.enabled := route.binding.layer = "normal" || IsObject(this.client)
                        route.state := route.enabled ? "pending" : "unavailable: no layer adapter"
                        if savedConflict != "" {
                            other := configured[savedConflict]
                            savedWarnings.Push(route.binding.label " is configured in " other.detail
                                . (other.alive ? " (currently inactive)" : " (not running)"))
                        }
                    }
                    seen[signature] := description
                }
                if strict && conflicts.Length
                    throw Error("Keybinding conflict:`n`n" Keybindings.Join(conflicts, "`n"))
                if strict && !acceptSaved && savedWarnings.Length
                    throw KB_SavedConflict("Saved binding warning:`n`n" Keybindings.Join(savedWarnings, "`n"))
                newDocument := this._MakeDocument(candidate.configuration, candidate.routes)
                KB_Manifest.WriteAtomic(this.path, newDocument)
                published := true
                this.configuration := candidate.configuration
                this.document := newDocument
                this.routes := candidate.routes
            }
            finally this._Unlock(previousCritical)
            this._Activate()
            if conflicts.Length
                this._Report("some bindings are inactive: " Keybindings.Join(conflicts, "; "))
        }
        catch Error as commitError {
            if !published {
                this.routes := oldRoutes
                this.configuration := oldConfiguration
                this.document := oldDocument
                this._Activate()
            }
            ; A native registration failure is recorded per binding by _Activate.
            ; Never claim that a post-publication error rolled back a saved file.
            throw commitError
        }
        finally this.applying := false
    }

    _MakeDocument(configuration, routes) {
        ; Preserve unrelated metadata, but retire old profile sections after migration.
        document := Map()
        for section, rows in this.document
            document[section] := rows.Clone()
        document["meta"] := Map("schema", "1", "id", this.id, "name", this.name,
            "hwnd", String(A_ScriptHwnd), "pid", String(DllCall("GetCurrentProcessId", "uint")))
        document["bindings"] := Map()
        for actionId, setting in configuration
            document["bindings"][actionId] := (setting.enabled ? "1" : "0")
                . "`t" setting.bindings[1] "`t" setting.bindings[2]
        ; Retire the old profile sections on first successful save.
        for sectionName in ["profile:standalone", "profile:layered", "profile:default"]
            if document.Has(sectionName)
                document.Delete(sectionName)
        document["configured"] := Map()
        document["claims"] := Map()
        for route in routes {
            document["configured"][route.binding.signature] := route.action.label
            if route.enabled
                document["claims"][route.binding.signature] := route.action.label
        }
        return document
    }

    static Join(items, separator) {
        result := ""
        for index, item in items
            result .= (index = 1 ? "" : separator) item
        return result
    }

    ; =========================================================================
    ; ordinary hotkeys, guarded releases and optional layer adapter
    ; =========================================================================

    _Deactivate() {
        for route in this.routes {
            route.enabled := false
            if route.token
                this._QueueEvent(route, "cancel", route.foreground, route.oneShot)
        }
        for key, press in this.pressed
            press.finished := true
        if IsObject(this.client) {
            this.client.Stop()
            for specification in this.client.bindings.Clone()
                this.client.Unbind(specification)
        }
        this.routeMap := Map()
    }

    _Activate() {
        this.externalCapture := DllCall("FindWindowW", "ptr", 0,
            "str", this.captureTitle, "ptr") != 0
        this._RefreshGate()
        this.routeMap := Map()
        for route in this.routes {
            ; Conflict state is a rejected claim, not merely a disabled native key.
            if InStr(route.state, "conflict:") = 1 || route.state = "unavailable: no layer adapter"
                continue
            route.enabled := true
            route.specification := 0
            route.token := 0
            binding := route.binding
            this.routeMap[binding.signature] := route
            try {
                if binding.layer = "normal" {
                    this._EnsureVariant(binding)
                    route.state := "active"
                    if !binding.wheel && GetKeyState(binding.key, "P")
                        this.blocked[binding.key] := true
                } else if IsObject(this.client) {
                    route.specification := this.client.Bind(binding.layer, binding.modifiers,
                        binding.key, route.action.label, ObjBindMethod(this, "_LayerEvent", route),
                        route.action.repeat)
                    route.state := "offline"
                } else {
                    route.state := "unavailable: no layer adapter"
                }
            }
            catch Error as registrationError {
                route.enabled := false
                route.state := "error: " registrationError.Message
                this._Report(route.action.label ": " registrationError.Message)
            }
        }
        this._UpdateReleaseTimer()
        this._RefreshGate()
        if IsObject(this.client) && !this.gated && this.running && this.client.bindings.Length
            this.client.Start()
    }

    _EnsureVariant(binding) {
        key := binding.key
        if !binding.wheel && !this.groups.Has(key) {
            predicate := ObjBindMethod(this, "_GuardEligible", key)
            HotIf predicate
            try {
                Hotkey("$*" key, ObjBindMethod(this, "_GuardDown", key), "On I100 B0")
                Hotkey("$*" key " Up", ObjBindMethod(this, "_KeyUp", key), "On I100 B0")
            }
            finally HotIf()
            this.groups[key] := predicate
        }
        signature := binding.signature
        if this.variants.Has(signature)
            return
        if this.variants.Count >= 4096
            throw Error("Too many distinct native hotkey variants; reload the script.")
        predicate := ObjBindMethod(this, "_Eligible", signature)
        HotIf predicate
        try Hotkey("$" Keybindings.Symbols(binding.modifiers) key,
            ObjBindMethod(this, "_KeyDown", signature), "On I100 B0")
        finally HotIf()
        ; HotIf owns predicate references for the process lifetime. Reuse them on
        ; every edit instead of leaking another variant for the same shortcut.
        this.variants[signature] := predicate
    }

    _Eligible(signature, *) {
        if !this.running || this.gated || this.applying || !this.routeMap.Has(signature)
            return false
        route := this.routeMap[signature]
        return route.enabled && !this.blocked.Has(route.binding.key)
            && Keybindings.ModifierMask() = route.binding.modifiers
    }

    _GuardEligible(key, *) => this.running && this.pressed.Has(key)

    _KeyDown(signature, *) {
        previousCritical := A_IsCritical
        Critical "On"
        try {
            if !this._Eligible(signature)
                return
            route := this.routeMap[signature]
            key := route.binding.key
            if this.pressed.Has(key) {
                this._GuardDown(key)
                return
            }
            foreground := DllCall("GetForegroundWindow", "ptr")
            if !route.binding.wheel {
                this.pressed[key] := {route: route, finished: false}
                this._UpdateReleaseTimer()
            }
            this._QueueEvent(route, "down", foreground, false)
            ; Wheel input has no physical key-up. Each wheel step is a complete
            ; activation, regardless of whether the action allows key repeat.
            if route.binding.wheel
                this._QueueEvent(route, "up", foreground, false)
        }
        finally Critical previousCritical
    }

    _GuardDown(key, *) {
        previousCritical := A_IsCritical
        Critical "On"
        try {
            if !this.pressed.Has(key)
                return
            press := this.pressed[key]
            route := press.route
            if press.finished
                return
            if this.gated || !route.enabled || this.applying
                || Keybindings.ModifierMask() != route.binding.modifiers {
                press.finished := true
                this._QueueEvent(route, "cancel", route.foreground, false)
            } else if route.action.repeat {
                this._QueueEvent(route, "repeat", route.foreground, false)
            }
        }
        finally Critical previousCritical
    }

    _KeyUp(key, *) {
        previousCritical := A_IsCritical
        Critical "On"
        try {
            if !this.pressed.Has(key)
                return
            press := this.pressed[key]
            if !press.finished
                this._QueueEvent(press.route, "up", press.route.foreground, false)
            this.pressed.Delete(key)
            this._UpdateReleaseTimer()
        }
        finally Critical previousCritical
    }

    _CheckReleases() {
        previousCritical := A_IsCritical
        Critical "On"
        try {
            for key in this.blocked.Clone()
                if !GetKeyState(key, "P")
                    this.blocked.Delete(key)
            for key, press in this.pressed.Clone() {
                if !GetKeyState(key, "P") {
                    this._KeyUp(key)
                } else if !press.finished && (this.gated || !press.route.enabled
                    || this.applying || Keybindings.ModifierMask() != press.route.binding.modifiers) {
                    press.finished := true
                    this._QueueEvent(press.route, "cancel", press.route.foreground, false)
                }
            }
            this._UpdateReleaseTimer()
        }
        finally Critical previousCritical
    }

    _UpdateReleaseTimer() {
        SetTimer(this.releaseCallback, this.running && (this.pressed.Count || this.blocked.Count) ? 15 : 0)
    }

    _LayerEvent(route, event) {
        if (event.phase = "down" || event.phase = "repeat")
            && (!this.running || this.gated || this.applying || !route.enabled)
            return
        this._QueueEvent(route, event.phase, event.foregroundHwnd, event.oneShot)
    }

    _QueueEvent(route, phase, foreground, oneShot) {
        previousCritical := A_IsCritical
        Critical "On"
        try {
            if phase = "down" {
                if route.token || this.queue.Length >= 256
                    return
                route.token := ++this.nextToken
                route.foreground := foreground
                route.oneShot := oneShot
            } else if !route.token {
                return
            }
            token := route.token
            if phase = "up" || phase = "cancel"
                route.token := 0
            if phase = "repeat" && this.queue.Length >= 128
                return
            event := {phase: phase, actionId: route.action.id, label: route.action.label,
                slot: route.slot, binding: route.binding.label, layer: route.binding.layer,
                key: route.binding.key, modifiers: route.binding.modifiers,
                foregroundHwnd: foreground, oneShot: oneShot}
            this.queue.Push({route: route, event: event, token: token, tick: A_TickCount})
            if this.running && !this.dispatching
                SetTimer(this.drainCallback, -1)
        }
        finally Critical previousCritical
    }

    _Drain() {
        if this.dispatching || !this.running
            return
        this.dispatching := true
        try {
            loop 32 {
                if !this.queue.Length || !this.running
                    break
                item := this.queue.RemoveAt(1)
                phase := item.event.phase
                if phase = "down" {
                    if this.gated || this.applying || !item.route.enabled
                        || ((A_TickCount - item.tick) & 0xFFFFFFFF) > 500
                        continue
                    this.delivered[item.token] := item
                } else {
                    if !this.delivered.Has(item.token)
                        continue
                    if phase = "up" || phase = "cancel"
                        this.delivered.Delete(item.token)
                }
                this._Invoke(item.route, item.event)
            }
        }
        finally {
            this.dispatching := false
            if this.queue.Length && this.running
                SetTimer(this.drainCallback, -1)
        }
    }

    _Invoke(route, event) {
        try route.action.callback.Call(event)
        catch Error as callbackError
            this._Report("action callback failed: " route.action.id " - " callbackError.Message)
    }

    _Report(text) {
        OutputDebug "Keybindings [" this.id "]: " text
        if HasMethod(this.statusCallback, "Call")
            try this.statusCallback.Call(text)
    }

    _RefreshGate() {
        gated := this.paused || IsObject(this.settings) || this.externalCapture || !this.running
        if gated = this.gated
            return
        this.gated := gated
        if gated {
            for route in this.routes
                if route.token
                    this._QueueEvent(route, "cancel", route.foreground, route.oneShot)
            for key, press in this.pressed
                press.finished := true
            if IsObject(this.client)
                this.client.Stop()
        } else {
            ; Never activate a new shortcut halfway through a key which was
            ; already held while capture/settings temporarily disabled input.
            for route in this.routes
                if route.binding.layer = "normal" && !route.binding.wheel
                    && GetKeyState(route.binding.key, "P")
                    this.blocked[route.binding.key] := true
            this._UpdateReleaseTimer()
            if IsObject(this.client) && this.client.bindings.Length
                this.client.Start()
        }
    }

    _Maintain(*) {
        if !this.running
            return
        this.externalCapture := DllCall("FindWindowW", "ptr", 0,
            "str", this.captureTitle, "ptr") != 0
        this._RefreshGate()
        if !IsObject(this.client) || !this.client.session || this.gated || this.applying
            return
        ; The adapter reconnects automatically. Retry rejected registrations too:
        ; a key may have been physically held, or another layer client exited.
        for route in this.routes {
            specification := route.specification
            if route.enabled && IsObject(specification) && !specification.remoteId
                && !GetKeyState(route.binding.key, "P")
                this.client.Register(specification)
        }
    }

    _Notice(wParam, lParam, message, receiverHwnd) {
        if receiverHwnd != A_ScriptHwnd
            return
        this.externalCapture := DllCall("FindWindowW", "ptr", 0,
            "str", this.captureTitle, "ptr") != 0
        this._RefreshGate()
        return 1
    }

    ; =========================================================================
    ; category-based, immediately saved keybinding screen
    ; =========================================================================

    ShowSettings(*) {
        if !this.running
            throw Error("Start the keybinding manager first.")
        if IsObject(this.settings) {
            this.settings.Show()
            return
        }

        ; Keep small module lists compact, while allowing a longer scrollable list.
        categories := Map()
        enabledActions := 0
        for actionId, action in this.actions {
            if !this.configuration[actionId].enabled
                continue
            enabledActions += 1
            categories[action.category] := true
        }
        rowCount := Min(11, Max(4, enabledActions + categories.Count))
        rowStartY := 48
        ; The scrollable rows end before the pinned bottom action bar.
        footerDividerY := rowStartY + rowCount * 35 + 8
        footerY := footerDividerY + 15
        windowHeight := footerY + 49

        window := Gui("-Resize", this.name " - keybindings")
        this.settings := window
        this._RefreshGate()
        window.SetFont("s10", "Segoe UI")
        ; Center the search box independently of the scrollable rows.
        searchBox := window.AddEdit("x210 y13 w400 vsearch")
        ; EM_SETCUEBANNER supplies a search hint without an extra label.
        DllCall("SendMessageW", "ptr", searchBox.Hwnd, "uint", 0x1501,
            "uptr", 1, "str", "search...", "ptr")
        searchBox.OnEvent("Change", ObjBindMethod(this, "_SearchChanged"))

        this.visibleRows := []
        loop rowCount {
            index := A_Index
            y := rowStartY + (index - 1) * 35
            title := window.AddText("x22 y" (y + 6) " w290", "")
            categoryTitle := window.AddText("x22 y" (y + 6) " w752 Center", "")
            primary := window.AddButton("x323 y" y " w185 h29", "unbound")
            secondary := window.AddButton("x518 y" y " w170 h29", "unbound")
            reset := window.AddButton("x698 y" y " w76 h29", "reset")
            primary.OnEvent("Click", ObjBindMethod(this, "_BeginRecording", index, 1))
            secondary.OnEvent("Click", ObjBindMethod(this, "_BeginRecording", index, 2))
            reset.OnEvent("Click", ObjBindMethod(this, "_ResetAction", index))
            this.visibleRows.Push({title: title, categoryTitle: categoryTitle,
                primary: primary, secondary: secondary, reset: reset, actionId: ""})
        }
        ; A real Windows scrollbar has one thumb, proportionally sized by page.
        ; A Slider is a trackbar and renders an unwanted separate channel/handle.
        this.settingsScroll := window.AddCustom("ClassScrollBar x778 y" rowStartY
            " w24 h" (rowCount * 35) " +0x1") ; SBS_VERT
        ; Only the binding rows scroll. This separator and centered actions stay put.
        window.AddText("x22 y" footerDividerY " w752 h2 +0x10", "")
        window.AddButton("x268 y" footerY " w140 h31", "reset all").OnEvent("Click",
            ObjBindMethod(this, "_ResetAll"))
        window.AddButton("x422 y" footerY " w130 h31", "done").OnEvent("Click",
            ObjBindMethod(this, "_RequestCloseSettings"))
        window.OnEvent("Close", ObjBindMethod(this, "_RequestCloseSettings"))
        window.OnEvent("Escape", ObjBindMethod(this, "_RequestCloseSettings"))
        this.scrollPosition := 0
        this._RenderSettings()
        window.Show("w820 h" windowHeight)
        ; The scrollbar sends WM_VSCROLL to its parent; wheels use WM_MOUSEWHEEL.
        ; Register both handlers only while the settings window exists.
        OnMessage(0x020A, this.wheelCallback)
        this.wheelHookActive := true
        OnMessage(0x0115, this.verticalScrollCallback)
        this.verticalScrollHookActive := true
    }

    _SearchChanged(*) {
        this.scrollPosition := 0
        this.wheelRemainder := 0
        this._RenderSettings()
    }

    _WheelSettings(wParam, lParam, messageId, receiverHwnd) {
        if !IsObject(this.settings) || IsObject(this.recording)
            return
        ; Handle only wheel messages for this GUI or its child controls.
        if receiverHwnd != this.settings.Hwnd
            && DllCall("GetAncestor", "ptr", receiverHwnd, "uint", 2, "ptr") != this.settings.Hwnd
            return
        ; Windows can deliver the wheel to the focused control even when the
        ; pointer is elsewhere. Never scroll a window behind the cursor.
        MouseGetPos(, , &hoverWindow)
        if hoverWindow != this.settings.Hwnd
            return

        maximum := Max(0, this.rows.Length - this.visibleRows.Length)
        if maximum = 0
            return 0
        ; Wheel delta is a signed 16-bit number in the high word of wParam.
        wheelDelta := (wParam >> 16) & 0xFFFF
        if wheelDelta >= 0x8000
            wheelDelta -= 0x10000
        this.wheelRemainder += wheelDelta
        wheelSteps := Floor(Abs(this.wheelRemainder) / 120)
        if wheelSteps = 0
            return 0
        wheelDirection := this.wheelRemainder > 0 ? -1 : 1
        this.wheelRemainder += wheelDirection * wheelSteps * 120
        this.scrollPosition := Min(Max(this.scrollPosition + wheelDirection * wheelSteps * 3,
            0), maximum)
        this._RenderSettings()
        return 0
    }

    _VerticalScrollSettings(wParam, lParam, messageId, receiverHwnd) {
        if !IsObject(this.settings) || receiverHwnd != this.settings.Hwnd
            || lParam != this.settingsScroll.Hwnd
            return
        maximum := Max(0, this.rows.Length - this.visibleRows.Length)
        scrollCommand := wParam & 0xFFFF
        nextPosition := this.scrollPosition
        switch scrollCommand {
            case 0: nextPosition -= 1             ; SB_LINEUP
            case 1: nextPosition += 1             ; SB_LINEDOWN
            case 2: nextPosition -= this.visibleRows.Length ; SB_PAGEUP
            case 3: nextPosition += this.visibleRows.Length ; SB_PAGEDOWN
            case 4, 5:                           ; SB_THUMBPOSITION / SB_THUMBTRACK
                scrollInfo := Buffer(28, 0)
                NumPut("uint", 28, scrollInfo, 0)
                NumPut("uint", 0x10, scrollInfo, 4) ; SIF_TRACKPOS
                if DllCall("GetScrollInfo", "ptr", lParam, "int", 2,
                    "ptr", scrollInfo, "int")
                    nextPosition := NumGet(scrollInfo, 24, "int")
            case 6: nextPosition := 0             ; SB_TOP
            case 7: nextPosition := maximum       ; SB_BOTTOM
            default: return 0                    ; SB_ENDSCROLL / unknown
        }
        nextPosition := Min(Max(nextPosition, 0), maximum)
        if nextPosition = this.scrollPosition
            return 0
        this.scrollPosition := nextPosition
        this._RenderSettings()
        return 0
    }

    _RenderSettings(*) {
        if !IsObject(this.settings)
            return
        search := StrLower(Trim(this.settings["search"].Value))
        categories := Map()
        orderedCategories := []
        for actionId, action in this.actions {
            setting := this.configuration[actionId]
            ; Enabled is owned by the supplying module, not this screen.
            if !setting.enabled
                continue
            searchable := action.id " " action.category " " action.label
            for encoded in setting.bindings {
                parsed := Keybindings.Parse(encoded)
                if IsObject(parsed)
                    searchable .= " " parsed.label
            }
            if search != "" && !InStr(StrLower(searchable), search)
                continue
            if !categories.Has(action.category) {
                categories[action.category] := []
                orderedCategories.Push(action.category)
            }
            categories[action.category].Push(actionId)
        }
        this.rows := []
        for categoryName in orderedCategories {
            this.rows.Push({id: "", label: categoryName})
            for actionId in categories[categoryName]
                this.rows.Push({id: actionId, label: this.actions[actionId].label})
        }
        maximum := Max(0, this.rows.Length - this.visibleRows.Length)
        this.scrollPosition := Min(Max(this.scrollPosition, 0), maximum)
        this.settingsScroll.Visible := maximum > 0
        ; SCROLLINFO controls both the actual offset and the proportional thumb.
        ; nMax is the final row index, and nPage is the visible row count.
        scrollInfo := Buffer(28, 0)
        NumPut("uint", 28, scrollInfo, 0)
        NumPut("uint", 0x7, scrollInfo, 4) ; SIF_RANGE | SIF_PAGE | SIF_POS
        NumPut("int", 0, scrollInfo, 8)
        NumPut("int", Max(0, this.rows.Length - 1), scrollInfo, 12)
        NumPut("uint", this.visibleRows.Length, scrollInfo, 16)
        NumPut("int", this.scrollPosition, scrollInfo, 20)
        DllCall("SetScrollInfo", "ptr", this.settingsScroll.Hwnd, "int", 2,
            "ptr", scrollInfo, "int", true, "int")
        for index, row in this.visibleRows {
            position := this.scrollPosition + index
            visible := position <= this.rows.Length
            entry := visible ? this.rows[position] : 0
            row.actionId := visible ? entry.id : ""
            row.title.Visible := visible && entry.id != ""
            row.categoryTitle.Visible := visible && entry.id = ""
            row.primary.Visible := visible && entry.id != ""
            row.secondary.Visible := visible && entry.id != ""
            row.reset.Visible := visible && entry.id != ""
            if !visible
                continue
            if entry.id = "" {
                row.categoryTitle.Text := entry.label
                continue
            }
            row.title.Text := entry.label
            setting := this.configuration[entry.id]
            for slot, control in [row.primary, row.secondary] {
                parsed := Keybindings.Parse(setting.bindings[slot])
                control.Text := IsObject(parsed) ? parsed.label : "+ add"
            }
            ; A reset button has no purpose when both bindings match defaults.
            defaults := this.actions[entry.id].defaults
            row.reset.Enabled := setting.bindings[1] != defaults[1]
                || setting.bindings[2] != defaults[2]
        }
    }

    _ResetAction(index, *) {
        if index > this.visibleRows.Length
            return
        actionId := this.visibleRows[index].actionId
        if actionId = ""
            return
        configuration := this.GetConfiguration()
        configuration[actionId].bindings := this.actions[actionId].defaults.Clone()
        this._SaveConfiguration(configuration)
    }

    _ResetAll(*) {
        if MsgBox("Reset all visible modules' bindings to defaults?",
            this.name, "YesNo Icon?") != "Yes"
            return
        configuration := this.GetConfiguration()
        for actionId, action in this.actions
            if configuration[actionId].enabled
                configuration[actionId].bindings := action.defaults.Clone()
        this._SaveConfiguration(configuration)
    }

    _SaveConfiguration(configuration) {
        try {
            try this.Apply(configuration)
            catch KB_SavedConflict as savedWarning {
                if MsgBox(savedWarning.Message "`n`nKeep these assignments anyway?",
                    this.name, "YesNo Icon!") != "Yes"
                    return false
                this.Apply(configuration, true)
            }
            this._Report("keybinding changes saved")
            this._RenderSettings()
            return true
        }
        catch Error as settingsError {
            MsgBox(settingsError.Message, this.name " - binding rejected", "Icon!")
            return false
        }
    }

    _RequestCloseSettings(*) {
        if IsObject(this.recording) {
            this._EndRecording()
            return
        }
        this._CloseSettings()
    }

    _CloseSettings(*) {
        this._EndRecording()
        if this.wheelHookActive {
            OnMessage(0x020A, this.wheelCallback, 0)
            this.wheelHookActive := false
        }
        if this.verticalScrollHookActive {
            OnMessage(0x0115, this.verticalScrollCallback, 0)
            this.verticalScrollHookActive := false
        }
        this.wheelRemainder := 0
        if IsObject(this.settings)
            this.settings.Destroy()
        this.settings := 0
        this._RefreshGate()
    }

    ; =========================================================================
    ; direct keyboard and mouse capture (no second editor window)
    ; =========================================================================

    _BeginRecording(index, slot, *) {
        if IsObject(this.recording) || !IsObject(this.settings)
            return
        actionId := this.visibleRows[index].actionId
        if actionId = ""
            return
        captureMutex := DllCall("CreateMutexW", "ptr", 0, "int", false,
            "str", this.mutexPrefix ".Capture", "ptr")
        mutexError := A_LastError
        if !captureMutex || mutexError = 183 {
            if captureMutex
                DllCall("CloseHandle", "ptr", captureMutex)
            MsgBox("Another keybinding recorder is already open.", this.name, "Icon!")
            return
        }
        record := {mutex: captureMutex, window: 0, hook: 0, peers: [],
            pending: "", pendingKey: "", clearing: false, actionId: actionId, slot: slot,
            finish: ObjBindMethod(this, "_FinishRecordedKey"),
            timeout: ObjBindMethod(this, "_RecordingTimedOut")}
        this.recording := record
        try {
            record.window := Gui("+ToolWindow -Caption", this.captureTitle)
            record.markerHwnd := record.window.Hwnd ; hidden cross-process capture marker
            previousCritical := this._Lock()
            try record.peers := this._Owners()
            finally this._Unlock(previousCritical)
            ; Pause participating scripts before collecting a physical chord.
            for owner in record.peers
                if owner.alive && !this._TellPeer(owner)
                    throw Error(owner.name " could not pause for key recording.")
            this.externalCapture := true
            this._RefreshGate()
            record.button := slot = 1 ? this.visibleRows[index].primary : this.visibleRows[index].secondary
            record.button.Text := "press keys..."
            hook := InputHook("L0 I101")
            hook.KeyOpt("{All}", "SN")
            hook.OnKeyDown := ObjBindMethod(this, "_RecordKey")
            record.hook := hook
            hook.Start()
            for mouseName in ["LButton", "RButton", "MButton", "XButton1", "XButton2",
                "WheelUp", "WheelDown", "WheelLeft", "WheelRight"] {
                mouseHotkey := "$*" mouseName
                Hotkey(mouseHotkey, ObjBindMethod(this, "_RecordMouse", mouseName), "On I100 B0")
                this.captureMouse[mouseHotkey] := true
            }
            SetTimer(record.finish, 25)
            SetTimer(record.timeout, -10000)
        }
        catch Error as recordingError {
            this._EndRecording()
            MsgBox(recordingError.Message, this.name " - could not record", "Icon!")
        }
    }

    _CaptureLayer() {
        if GetKeyState("CapsLock", "P")
            return "caps"
        if GetKeyState("Pause", "P") || GetKeyState("CtrlBreak", "P")
            return "pause"
        return "normal"
    }

    _RecordKey(hook, vk, sc) {
        if !IsObject(this.recording)
            return
        if !WinActive("ahk_id " this.settings.Hwnd) {
            this._EndRecording()
            return
        }
        if vk = 0x1B {
            this._EndRecording()
            return
        }
        ; Both Backspace (VK_BACK) and Delete (VK_DELETE) clear an assignment.
        if vk = 0x08 || vk = 0x2E {
            this.recording.pending := "CLEAR"
            this.recording.pendingKey := sc ? Format("sc{:03X}", sc) : Format("vk{:02X}", vk)
            this.recording.clearing := true
            this.recording.button.Text := "unbound ..."
            return
        }
        if vk = 0x10 || vk = 0x11 || vk = 0x12 || (vk >= 0xA0 && vk <= 0xA5)
            || vk = 0x5B || vk = 0x5C || vk = 0x14 || vk = 0x13
            return
        if this.recording.pending != ""
            return
        key := sc ? Format("sc{:03X}", sc) : Format("vk{:02X}", vk)
        this._StageRecordedBinding(this._CaptureLayer(), Keybindings.ModifierMask(), key, key)
    }

    _RecordMouse(mouseName, *) {
        if !IsObject(this.recording)
            return
        if !WinActive("ahk_id " this.settings.Hwnd) {
            this._EndRecording()
            return
        }
        if this.recording.pending != ""
            return
        ; Protocol 1 only accepts keyboard keys after CapsLock/Pause.
        this._StageRecordedBinding(this._CaptureLayer(), Keybindings.ModifierMask(), mouseName, "")
    }

    _StageRecordedBinding(layer, modifiers, key, waitKey) {
        try {
            binding := Keybindings.Parse(layer "|" modifiers "|" key)
            this.recording.pending := binding.signature
            this.recording.pendingKey := waitKey
            this.recording.button.Text := binding.label " ..."
            ; The periodic release watcher also handles wheel-only input.
        }
        catch Error as captureError {
            this._EndRecording()
            MsgBox(captureError.Message, this.name " - unsupported binding", "Icon!")
        }
    }

    _FinishRecordedKey(*) {
        if !IsObject(this.recording)
            return
        record := this.recording
        if !IsObject(this.settings) || !WinActive("ahk_id " this.settings.Hwnd) {
            this._EndRecording()
            return
        }
        if record.pending = ""
            return
        if record.pendingKey != "" && GetKeyState(record.pendingKey, "P")
            return
        if !record.clearing && (Keybindings.ModifierMask() || GetKeyState("CapsLock", "P")
            || GetKeyState("Pause", "P") || GetKeyState("CtrlBreak", "P"))
            return
        value := record.clearing ? "" : record.pending
        actionId := record.actionId
        slot := record.slot
        this._EndRecording()
        configuration := this.GetConfiguration()
        configuration[actionId].bindings[slot] := value
        this._SaveConfiguration(configuration)
    }

    _RecordingTimedOut(*) => this._EndRecording()

    _EndRecording(*) {
        if !IsObject(this.recording)
            return
        record := this.recording
        this.recording := 0
        try SetTimer(record.finish, 0)
        try SetTimer(record.timeout, 0)
        if IsObject(record.hook)
            try record.hook.Stop()
        for mouseHotkey in this.captureMouse
            try Hotkey(mouseHotkey, "Off")
        this.captureMouse.Clear()
        if IsObject(record.window)
            try record.window.Destroy()
        if record.mutex
            DllCall("CloseHandle", "ptr", record.mutex)
        this.externalCapture := false
        for owner in record.peers
            if owner.alive
                try this._TellPeer(owner)
        this._RefreshGate()
        this._RenderSettings()
    }

    _TellPeer(owner) {
        processId := 0
        if !owner.hwnd || !DllCall("GetWindowThreadProcessId", "ptr", owner.hwnd,
            "uint*", &processId, "uint") || processId != owner.pid
            return false
        reply := 0
        delivered := DllCall("SendMessageTimeoutW", "ptr", owner.hwnd,
            "uint", this.message, "uptr", 0, "ptr", 0, "uint", 0x22,
            "uint", 350, "ptr*", &reply, "ptr")
        return delivered && reply = 1
    }
}

class KB_SavedConflict extends Error {
}

; =============================================================================
; private data codec - UTF-8 INI-style text, parsed here (no executable settings)
; =============================================================================

class KB_Manifest {
    static Get(document, section, key, fallback := "") {
        return document.Has(section) && document[section].Has(key)
            ? document[section][key] : fallback
    }

    static Read(path) {
        if !FileExist(path)
            return Map()
        if FileGetSize(path) > 2 * 1024 * 1024
            throw Error("Keybinding manifest exceeds the size limit: " path)
        return this.Decode(FileRead(path, "UTF-8"))
    }

    static Decode(text) {
        result := Map()
        section := ""
        text := LTrim(text, Chr(0xFEFF))
        loop parse text, "`n", "`r" {
            line := A_LoopField
            if line = "" || SubStr(line, 1, 1) = ";"
                continue
            if RegExMatch(line, "^\[([^\[\]\t\r\n]+)\]$", &match) {
                section := match[1]
                if result.Has(section)
                    throw Error("Duplicate manifest section: " section)
                result[section] := Map()
                continue
            }
            equal := InStr(line, "=")
            if section = "" || equal <= 1
                throw Error("Malformed keybinding manifest; it was not overwritten.")
            key := SubStr(line, 1, equal - 1)
            if result[section].Has(key)
                throw Error("Duplicate manifest key: " key)
            result[section][key] := SubStr(line, equal + 1)
        }
        return result
    }

    static Validate(document) {
        if this.Get(document, "meta", "schema") != "1"
            throw Error("Unknown or damaged keybinding registry schema; no bindings were claimed.")
        Keybindings.Id(this.Get(document, "meta", "id"))
        Keybindings.Text(this.Get(document, "meta", "name"), 100)
    }

    static Encode(document) {
        text := "; keybindings schema 1 - UTF-8; edit through the configuration window`n"
        for section, rows in document {
            if RegExMatch(section, "[\[\]\t\r\n]")
                throw ValueError("Invalid manifest section.")
            text .= "`n[" section "]`n"
            for key, value in rows {
                if key = "" || RegExMatch(key, "[=\t\r\n]") || RegExMatch(value, "[\r\n]")
                    throw ValueError("Invalid manifest field.")
                text .= key "=" value "`n"
            }
        }
        return text
    }

    static WriteAtomic(path, document) {
        temporary := path ".tmp-" DllCall("GetCurrentProcessId", "uint") "-" Random(1, 0x7FFFFFFF)
        stream := 0
        try {
            stream := FileOpen(temporary, "w", "UTF-8")
            if !IsObject(stream)
                throw OSError(A_LastError, "FileOpen")
            content := this.Encode(document)
            if stream.Write(content) != StrPut(content, "UTF-8") - 1
                throw Error("The settings write was incomplete; the previous file was retained.")
            ; Accessing Handle flushes AHK's buffer before the Windows flush.
            if !DllCall("FlushFileBuffers", "ptr", stream.Handle, "int")
                throw OSError(A_LastError, "FlushFileBuffers")
            stream.Close()
            stream := 0
            ; Same-directory replacement: readers see the old or complete new
            ; snapshot, never half of an IniWrite sequence. Do not delete first.
            if !DllCall("MoveFileExW", "str", temporary, "str", path, "uint", 0x9, "int")
                throw OSError(A_LastError, "MoveFileExW")
        }
        finally {
            if IsObject(stream)
                stream.Close()
            if FileExist(temporary)
                try FileDelete temporary
        }
    }
}
