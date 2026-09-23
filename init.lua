------------------------------------------------------------
-- MEMCHROMEPAGES / MCP  —  version corrigée
--
-- F15 : retire l'entrée MCP sélectionnée (ne ferme rien)
-- F16 : réservé à Shottr
-- F17 : mémorise / met à jour la fenêtre Chrome active
-- F18 : entrée MCP suivante (retrouve ou reconstruit)
-- F19 : vérifie / rappelle toutes les entrées MCP
-- Cmd+Alt+Ctrl+D : DEBUG ON / OFF
--
-- Corrections principales par rapport à la version précédente :
--  1. Plus aucune manipulation de fenêtre par "front window" ou
--     par référence d'index : tout passe par l'ID Chrome de la
--     fenêtre (c'était la cause des collages dans la mauvaise
--     fenêtre / mauvais onglet).
--  2. Un seul AppleScript pour lire tout Chrome (au lieu de 2 par
--     onglet) -> plus rapide, plus de blocage de Hammerspoon.
--  3. Comparaison d'URL normalisée (fragment, slash final, http/s)
--     -> les fenêtres déjà ouvertes sont réellement retrouvées,
--     donc plus de reconstruction en double.
--  4. Verrou BUSY : un appui répété sur F17/F18/F19 ne relance
--     plus une deuxième exécution par-dessus la première.
--  5. F15 déselectionne après suppression : deux appuis de suite
--     ne suppriment plus silencieusement deux entrées.
--  6. Positionnement de la fenêtre reconstruite par "set bounds"
--     (déterministe) au lieu d'un timer sur focusedWindow().
------------------------------------------------------------


------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local COLLECTION_DIR  = os.getenv("HOME") .. "/.hammerspoon/workspaces"
local COLLECTION_FILE = COLLECTION_DIR .. "/MEMCHROMEPAGES.json"

local VERSION = "v27 — 2026-09-23"   -- à incrémenter à chaque modification

local DEBUG = true
local BUSY  = false          -- verrou anti double-déclenchement

hs.fs.mkdir(COLLECTION_DIR)


------------------------------------------------------------
-- OUTILS
------------------------------------------------------------

local function nowMs()
    return hs.timer.secondsSinceEpoch() * 1000
end


local function msg(title, text, duration, color)

    duration = duration or 2.5

    hs.alert.closeAll()

    local style = { textSize = 22, radius = 14, padding = 20 }
    if color then style.fillColor = color ; style.strokeColor = color end

    hs.alert.show(
        title .. "\n\n" .. (text or ""),
        style,
        hs.screen.mainScreen(),
        duration
    )
end

local COLOR_NEW    = { red = 0.05, green = 0.45, blue = 0.20, alpha = 0.92 }   -- vert
local COLOR_UPDATE = { red = 0.75, green = 0.45, blue = 0.05, alpha = 0.92 }   -- ambre


local function debugLog(fn, text, t0)

    if not DEBUG then return end

    local ms = 0
    if t0 then ms = nowMs() - t0 end

    print(string.format(
        "[MCP DEBUG] %s | %s | %.0f ms",
        tostring(fn), tostring(text), ms
    ))
end


-- Verrou : empêche deux actions MCP simultanées
local function guarded(name, fn)

    return function()

        if BUSY then
            debugLog(name, "IGNORE (occupé)", nil)
            return
        end

        BUSY = true

        local ok, err = pcall(fn)

        BUSY = false

        if not ok then
            print("[MCP LUA ERROR] " .. tostring(name) .. " : " .. tostring(err))
            msg(name .. " - ERREUR INTERNE", tostring(err), 5)
        end
    end
end


------------------------------------------------------------
-- NORMALISATION D'URL
--
-- Deux URLs qui ne diffèrent que par le schéma, le "www.",
-- le slash final ou le fragment (#...) sont considérées
-- comme la même page.
------------------------------------------------------------

local function normalizeURL(url)

    if not url or url == "" then return nil end

    local u = tostring(url)

    u = u:gsub("#.*$", "")            -- fragment
    u = u:gsub("^https?://", "")      -- schéma
    u = u:gsub("^www%.", "")          -- www
    u = u:gsub("/+$", "")             -- slash final
    u = u:lower()

    if u == "" then return nil end

    return u
end


-- Même chose sans la partie "?query" : sert de correspondance
-- de secours (Google Docs, Notion... changent souvent la query)
local function normalizePath(url)

    local n = normalizeURL(url)

    if not n then return nil end

    n = n:gsub("%?.*$", "")
    n = n:gsub("/+$", "")

    if n == "" then return nil end

    return n
end


local function isRealURL(url)

    if not url or url == "" then return false end

    if url:match("^chrome://newtab") then return false end
    if url == "about:blank" then return false end

    return true
end


------------------------------------------------------------
-- COLLECTION
------------------------------------------------------------

local function emptyCollection()

    return {
        name              = "MEMCHROMEPAGES",
        currentIndex      = 0,
        lastRecalledIndex = 0,
        windows           = {},
        trash             = {}
    }
end


local function loadCollection()

    local f = io.open(COLLECTION_FILE, "r")

    if not f then return emptyCollection() end

    local content = f:read("*a")
    f:close()

    local data = hs.json.decode(content)

    if not data then return emptyCollection() end

    data.windows           = data.windows or {}
    data.trash             = data.trash or {}
    data.currentIndex      = data.currentIndex or 0
    data.lastRecalledIndex = data.lastRecalledIndex or 0

    -- Purge des entrées sans aucune page réelle
    -- (fenêtres "chrome://newtab" seules, entrées sans onglet)
    local kept, removed = {}, 0

    for i, win in ipairs(data.windows) do

        local hasReal = false

        for _, tab in ipairs(win.tabs or {}) do
            if isRealURL(tab.url) then hasReal = true break end
        end

        if hasReal then
            table.insert(kept, win)
        else
            removed = removed + 1
            if data.currentIndex >= i and data.currentIndex > 0 then
                data.currentIndex = data.currentIndex - 1
            end
            if data.lastRecalledIndex == i then
                data.lastRecalledIndex = 0
            elseif data.lastRecalledIndex > i then
                data.lastRecalledIndex = data.lastRecalledIndex - 1
            end
        end
    end

    if removed > 0 then
        data.windows = kept
        print("[MCP] " .. removed .. " entrée(s) vide(s) purgée(s)")
    end

    return data
end


local function saveCollection(data)

    data.name    = "MEMCHROMEPAGES"
    data.savedAt = os.date("%Y-%m-%d %H:%M:%S")

    local f = io.open(COLLECTION_FILE, "w")

    if not f then
        msg("ERREUR MCP", "Impossible d'écrire MEMCHROMEPAGES.json", 4)
        return false
    end

    local encoded = hs.json.encode(data, true)

    f:write(encoded)
    f:close()

    -- Historique : une copie horodatée à chaque écriture, 20 conservées
    local histDir = COLLECTION_DIR .. "/historique"
    hs.fs.mkdir(histDir)

    local h = io.open(histDir .. "/MEMCHROMEPAGES-" .. os.date("%Y%m%d-%H%M%S") .. ".json", "w")
    if h then h:write(encoded) ; h:close() end

    local names = {}
    for name in hs.fs.dir(histDir) do
        if name:match("^MEMCHROMEPAGES%-.*%.json$") then table.insert(names, name) end
    end
    table.sort(names)
    while #names > 20 do
        os.remove(histDir .. "/" .. table.remove(names, 1))
    end

    return true
end


------------------------------------------------------------
-- TITRE D'UNE ENTREE
------------------------------------------------------------

local function windowTitle(win)

    if not win or not win.tabs or #win.tabs == 0 then
        return "Fenêtre Chrome"
    end

    local i = win.activeTabIndex or 1

    if i < 1 or i > #win.tabs then i = 1 end

    local t = win.tabs[i].title

    if t and t ~= "" then return t end

    return win.tabs[1].title or "Fenêtre Chrome"
end


-- Liste des URLs normalisées "réelles" d'une entrée
local function normalizedURLs(win)

    local list = {}

    if not win or not win.tabs then return list end

    for _, tab in ipairs(win.tabs) do

        if isRealURL(tab.url) then

            local n = normalizeURL(tab.url)

            if n then table.insert(list, n) end
        end
    end

    return list
end


------------------------------------------------------------
-- APPLESCRIPT
------------------------------------------------------------

-- Echappement correct pour une chaîne AppleScript
-- (string.format("%q", ...) produit du Lua, pas de l'AppleScript)
local function asStr(s)

    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", " ")
    s = s:gsub("\r", " ")

    return '"' .. s .. '"'
end


local function runAppleScript(label, script)

    local ok, result, raw = hs.osascript.applescript(script)

    if not ok then

        local detail = tostring(result)

        if raw ~= nil then
            detail = detail .. "\n" .. tostring(raw)
        end

        print("[MCP APPLESCRIPT ERROR] " .. tostring(label) .. "\n" .. detail)

        return false, nil, detail
    end

    return true, result, nil
end


------------------------------------------------------------
-- SNAPSHOT DE TOUT CHROME  (un seul AppleScript)
--
-- Retourne :
--   { { id = <chromeWindowId>, urls = { "...", ... } }, ... }
------------------------------------------------------------

local CHROME_SNAPSHOT = [[
    tell application "Google Chrome"

        set out to ""

        repeat with w in windows

            set n to ""
            try
                set n to name of w
            end try
            set ai to 1
            try
                set ai to active tab index of w
            end try
            set bs to ""
            try
                set b to bounds of w
                set bs to ((item 1 of b) as string) & "," & ((item 2 of b) as string) & "," & ((item 3 of b) as string) & "," & ((item 4 of b) as string)
            end try
            set out to out & "W" & (id of w as string) & "<|>" & n & "<|>" & (ai as string) & "<|>" & bs & linefeed

            repeat with t in tabs of w

                set u to ""
                set ti to ""

                try
                    set u to URL of t
                end try
                try
                    set ti to title of t
                end try

                set out to out & "T" & u & "<|>" & ti & linefeed

            end repeat

        end repeat

        return out

    end tell
]]


local function chromeSnapshot()

    local app = hs.application.get("Google Chrome")

    if not app then return {} end

    local ok, raw = runAppleScript("snapshot", CHROME_SNAPSHOT)

    if not ok or type(raw) ~= "string" then return {} end

    local windows = {}
    local current = nil

    for line in raw:gmatch("[^\r\n]+") do

        local tag  = line:sub(1, 1)
        local rest = line:sub(2)

        if tag == "W" then

            local parts = {}
            for part in (rest .. "<|>"):gmatch("(.-)<|>") do table.insert(parts, part) end

            local bounds = nil
            local x1, y1, x2, y2 = (parts[4] or ""):match("^(-?%d+),(-?%d+),(-?%d+),(-?%d+)$")
            if x1 then
                bounds = { x = tonumber(x1), y = tonumber(y1),
                           w = tonumber(x2) - tonumber(x1), h = tonumber(y2) - tonumber(y1) }
            end

            current = { id = tonumber(parts[1] or rest), name = parts[2] or "",
                        active = tonumber(parts[3]) or 1, bounds = bounds,
                        urls = {}, titles = {} }
            table.insert(windows, current)

        elseif tag == "T" and current then

            local url, title = rest:match("^(.-)<|>(.*)$")
            table.insert(current.urls, url or rest)
            table.insert(current.titles, title or "")
        end
    end

    return windows
end


------------------------------------------------------------
-- PROFILS CHROME  (compte Google de chaque fenêtre)
--
-- Chrome ne dit pas par AppleScript à quel profil appartient une
-- fenêtre, mais son titre système le dit : "… - Google Chrome – Pierre".
-- Le fichier Local State de Chrome donne le dossier de chaque
-- profil (Default, Profile 1…) et son e-mail.
------------------------------------------------------------

local DEFAULT_PROFILE_EMAIL = "p.lhoest@gmail.com"   -- compte par défaut des entrées sans profil

local CHROME_LOCAL_STATE =
    os.getenv("HOME") .. "/Library/Application Support/Google/Chrome/Local State"

-- { dirs = { ["Default"] = { name=, email= }, … }, byEmail = {}, byName = {} }
local function chromeProfiles()

    local f = io.open(CHROME_LOCAL_STATE, "r")
    if not f then return { dirs = {}, byEmail = {}, byName = {} } end
    local raw = f:read("*a") ; f:close()

    local ok, data = pcall(hs.json.decode, raw)
    local cache = ok and data and data.profile and data.profile.info_cache or {}

    local out = { dirs = {}, byEmail = {}, byName = {} }

    for dir, info in pairs(cache) do
        local email = (info.user_name or ""):lower()
        local name  = info.name or info.gaia_name or dir
        out.dirs[dir] = { name = name, email = email }
        if email ~= "" then out.byEmail[email] = dir end
        out.byName[name] = dir
        if info.gaia_name then out.byName[info.gaia_name] = dir end
    end

    return out
end


-- Dossier de profil pour une entrée (email mémorisé, sinon nom, sinon défaut)
local function profileDirFor(win)

    local p = chromeProfiles()

    if win.profile and p.byEmail[win.profile:lower()] then
        return p.byEmail[win.profile:lower()], win.profile
    end
    if win.profileName and p.byName[win.profileName] then
        return p.byName[win.profileName], p.dirs[p.byName[win.profileName]].email
    end
    if p.byEmail[DEFAULT_PROFILE_EMAIL] then
        return p.byEmail[DEFAULT_PROFILE_EMAIL], DEFAULT_PROFILE_EMAIL
    end

    return nil, nil
end


-- Profil de la fenêtre Chrome au premier plan, d'après son titre système
local function frontChromeProfile()

    local fw = hs.window.frontmostWindow()
    if not fw then return nil, nil end

    local title = fw:title() or ""
    local name  = title:match("Google Chrome%s*[–—-]%s*(.-)%s*$")
    if not name or name == "" then return nil, nil end

    local p   = chromeProfiles()
    local dir = p.byName[name]
    local email = dir and p.dirs[dir] and p.dirs[dir].email or nil

    return email, name
end


------------------------------------------------------------
-- LIRE LA FENETRE CHROME ACTIVE  (un seul AppleScript)
------------------------------------------------------------

local READ_FRONT = [[
    tell application "Google Chrome"

        if (count of windows) = 0 then
            return "ERR:NOWINDOW"
        end if

        set w to front window

        set b to bounds of w

        set out to "M" & (id of w as string) ¬
            & "<|>" & (active tab index of w as string) ¬
            & "<|>" & ((item 1 of b) as string) ¬
            & "<|>" & ((item 2 of b) as string) ¬
            & "<|>" & ((item 3 of b) as string) ¬
            & "<|>" & ((item 4 of b) as string) & linefeed

        repeat with t in tabs of w

            set u to ""
            set ti to ""

            try
                set u to URL of t
            end try

            try
                set ti to title of t
            end try

            set out to out & "T" & u & "<|>" & ti & linefeed

        end repeat

        return out

    end tell
]]


-- Trouve l'écran contenant un point (coordonnées globales)
local function screenAtPoint(x, y)

    for _, screen in ipairs(hs.screen.allScreens()) do

        local f = screen:fullFrame()

        if x >= f.x and x < f.x + f.w
            and y >= f.y and y < f.y + f.h
        then
            return screen
        end
    end

    return hs.screen.mainScreen()
end


local function readFrontChromeWindow()

    local app = hs.application.frontmostApplication()

    if not app or app:name() ~= "Google Chrome" then
        return nil, "Cliquez d'abord sur une fenêtre Chrome"
    end

    local ok, raw, err = runAppleScript("F17 read", READ_FRONT)

    if not ok then
        return nil, "Erreur AppleScript Chrome\n" .. tostring(err)
    end

    if type(raw) ~= "string" or raw:match("^ERR:") then
        return nil, "Aucune fenêtre Chrome lisible"
    end

    local chromeId, activeIndex
    local x1, y1, x2, y2
    local tabs = {}

    for line in raw:gmatch("[^\r\n]+") do

        local tag  = line:sub(1, 1)
        local rest = line:sub(2)

        if tag == "M" then

            local parts = {}

            for p in (rest .. "<|>"):gmatch("(.-)<|>") do
                table.insert(parts, p)
            end

            chromeId    = tonumber(parts[1])
            activeIndex = tonumber(parts[2]) or 1
            x1          = tonumber(parts[3]) or 0
            y1          = tonumber(parts[4]) or 0
            x2          = tonumber(parts[5]) or 0
            y2          = tonumber(parts[6]) or 0

        elseif tag == "T" then

            local url, title = rest:match("^(.-)<|>(.*)$")

            table.insert(tabs, {
                url   = url or rest or "",
                title = title or ""
            })
        end
    end

    if #tabs == 0 then
        return nil, "Aucun onglet dans la fenêtre active"
    end

    local w = math.max(1, (x2 or 0) - (x1 or 0))
    local h = math.max(1, (y2 or 0) - (y1 or 0))

    local screen = screenAtPoint(x1 + w / 2, y1 + h / 2)

    return {
        chromeWindowId = chromeId,
        activeTabIndex = activeIndex,
        tabs           = tabs,

        bounds = {
            x = math.floor(x1),
            y = math.floor(y1),
            w = math.floor(w),
            h = math.floor(h)
        },

        screenUUID = screen and screen:getUUID() or nil,

        profile     = (function() local e = frontChromeProfile() ; return e end)(),
        profileName = (function() local _, n = frontChromeProfile() ; return n end)()
    }
end


------------------------------------------------------------
-- RECHERCHE D'UNE ENTREE DANS LE SNAPSHOT CHROME
--
-- Score = nombre d'URLs communes (normalisées).
-- La meilleure fenêtre gagne ; à égalité, la première.
------------------------------------------------------------

-- Ensembles d'URLs d'une entrée mémorisée :
--   full = URL normalisée complète   (correspondance forte, 2 pts)
--   path = sans la query             (correspondance faible, 1 pt)
local function wantedSets(win)

    local full, path, count = {}, {}, 0

    if not win or not win.tabs then return full, path, 0 end

    for _, tab in ipairs(win.tabs) do

        if isRealURL(tab.url) then

            local f = normalizeURL(tab.url)
            local p = normalizePath(tab.url)

            if f then full[f] = true ; count = count + 1 end
            if p then path[p] = true end
        end
    end

    return full, path, count
end


-- Score d'une liste d'URLs vivantes contre une entrée mémorisée.
-- Retourne score, index du meilleur onglet.
local function matchScore(full, path, activeURL, urls)

    local score, firstHit, activeHit = 0, nil, nil

    for i, url in ipairs(urls) do

        local f = normalizeURL(url)
        local p = normalizePath(url)

        local hit = 0

        if f and full[f] then
            hit = 2
        elseif p and path[p] then
            hit = 1
        end

        if hit > 0 then

            score = score + hit

            if not firstHit then firstHit = i end

            if activeURL and not activeHit
                and (f == activeURL or p == activeURL)
            then
                activeHit = i
            end
        end
    end

    return score, (activeHit or firstHit or 1)
end


local function findLiveWindow(win, snapshot)

    local full, path, count = wantedSets(win)

    if count == 0 then return nil end

    -- URL de l'onglet actif mémorisé (pour choisir le bon onglet)
    local activeURL = nil

    if win.tabs and win.activeTabIndex
        and win.tabs[win.activeTabIndex]
    then
        activeURL = normalizePath(win.tabs[win.activeTabIndex].url)
    end

    local bestId, bestTab, bestScore, bestName = nil, 1, 0, nil

    for _, live in ipairs(snapshot) do

        local score, tab = matchScore(full, path, activeURL, live.urls)

        debugLog(
            "match",
            "fenêtre Chrome id=" .. tostring(live.id)
            .. " score=" .. tostring(score)
            .. " (" .. tostring(#live.urls) .. " onglets)",
            nil
        )

        if score > bestScore then
            bestScore = score
            bestId    = live.id
            bestTab   = tab
            bestName  = live.name
        end
    end

    if bestScore > 0 then
        return bestId, bestTab, bestScore, bestName
    end

    return nil
end


-- Attribue chaque fenêtre Chrome vivante à UNE seule entrée
-- (la meilleure correspondance gagne). Retourne index -> {id, tab, name}
local function assignLive(collection, snapshot)

    local byId = {}
    for _, live in ipairs(snapshot) do byId[live.id] = live end

    local used, result = {}, {}

    -- passe 1 : identité — l'ID Chrome mémorisé existe encore ET partage au moins une URL
    for i, win in ipairs(collection.windows) do
        local live = win.chromeWindowId and byId[win.chromeWindowId] or nil
        if live and not used[live.id] then
            local full, path, count = wantedSets(win)
            if count > 0 then
                local activeURL = nil
                if win.tabs and win.activeTabIndex and win.tabs[win.activeTabIndex] then
                    activeURL = normalizePath(win.tabs[win.activeTabIndex].url)
                end
                local score, tab = matchScore(full, path, activeURL, live.urls)
                if score > 0 then
                    used[live.id] = true
                    result[i] = { id = live.id, tab = tab, name = live.name, how = "id" }
                end
            end
        end
    end

    -- passe 2 : les autres, par meilleur recouvrement d'URLs, sans réutiliser une fenêtre
    local cands = {}

    for i, win in ipairs(collection.windows) do
        if not result[i] then
            local _, _, realCount = wantedSets(win)
            if realCount > 0 then
                local rest = {}
                for _, live in ipairs(snapshot) do
                    if not used[live.id] then table.insert(rest, live) end
                end
                local id, tab, score, name = findLiveWindow(win, rest)
                if id then
                    table.insert(cands, { index = i, id = id, tab = tab, score = score, name = name })
                end
            end
        end
    end

    table.sort(cands, function(a, b) return a.score > b.score end)

    for _, c in ipairs(cands) do
        if not used[c.id] then
            used[c.id] = true
            result[c.index] = { id = c.id, tab = c.tab, name = c.name, how = "urls" }
        end
    end

    return result
end


------------------------------------------------------------
-- METTRE UNE FENETRE AU PREMIER PLAN  (par ID, jamais par index)
------------------------------------------------------------

local function focusWindowById(winId, tabIndex)

    if not winId then return false end

    local ti = tostring(tabIndex or 1)

    local script = table.concat({
        'tell application "Google Chrome"',
        '    try',
        '        set w to window id ' .. tostring(winId),
        '        try',
        '            set minimized of w to false',
        '        end try',
        '        if ' .. ti .. ' <= (count of tabs of w) then',
        '            set active tab index of w to ' .. ti,
        '        end if',
        '        set index of w to 1',
        '        activate',
        '        return true',
        '    on error errMsg',
        '        return "ERR:" & errMsg',
        '    end try',
        'end tell'
    }, "\n")

    local ok, result = runAppleScript("focusWindowById", script)

    if not ok then return false end

    if result ~= true then
        print("[MCP FOCUS ERROR] id=" .. tostring(winId) .. " : " .. tostring(result))
        return false
    end

    return true
end


------------------------------------------------------------
-- ECRAN / GEOMETRIE DE RESTAURATION
------------------------------------------------------------

local function screenForStoredWindow(win)

    if win.screenUUID then

        for _, screen in ipairs(hs.screen.allScreens()) do

            if screen:getUUID() == win.screenUUID then
                return screen
            end
        end
    end

    return hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
end


local function targetBounds(win)

    local screen = screenForStoredWindow(win)
    local sf     = screen:frame()

    local ww = (win.bounds and win.bounds.w) or math.floor(sf.w * 0.8)
    local hh = (win.bounds and win.bounds.h) or math.floor(sf.h * 0.8)

    ww = math.min(ww, math.floor(sf.w * 0.92))
    hh = math.min(hh, math.floor(sf.h * 0.90))

    local x, y

    -- Si la position mémorisée tombe bien sur cet écran, on la garde
    if win.bounds
        and win.bounds.x >= sf.x - 5
        and win.bounds.y >= sf.y - 5
        and win.bounds.x + ww <= sf.x + sf.w + 5
        and win.bounds.y + hh <= sf.y + sf.h + 5
    then
        x = win.bounds.x
        y = win.bounds.y
    else
        x = math.floor(sf.x + (sf.w - ww) / 2)
        y = math.floor(sf.y + (sf.h - hh) / 2)
    end

    return math.floor(x), math.floor(y), math.floor(ww), math.floor(hh)
end


------------------------------------------------------------
-- RECONSTRUIRE UNE FENETRE CHROME
--
-- Tout se fait sur l'ID de la fenêtre créée :
-- plus de "front window" (source des onglets collés
-- dans la mauvaise fenêtre).
------------------------------------------------------------

-- Crée la fenêtre dans le profil voulu avec tous ses onglets, et
-- attend qu'elle apparaisse dans Chrome (max ~4 s). Retourne son ID.
local function createWindowInProfile(win, dir)

    local before = {}
    for _, live in ipairs(chromeSnapshot()) do before[live.id] = true end

    local args = { "-na", "Google Chrome", "--args", "--profile-directory=" .. dir, "--new-window" }
    local urls = {}
    for _, tab in ipairs(win.tabs) do
        local u = tab.url or ""
        if isRealURL(u) then table.insert(args, u) ; table.insert(urls, u) end
    end
    if #urls == 0 then return nil end

    local task = hs.task.new("/usr/bin/open", nil, args)
    if not task or not task:start() then return nil end

    local wantFirst = normalizeURL(urls[1])

    for _ = 1, 40 do
        hs.timer.usleep(100000)   -- 0,1 s
        for _, live in ipairs(chromeSnapshot()) do
            if not before[live.id] then
                for _, u in ipairs(live.urls) do
                    if normalizeURL(u) == wantFirst then return live.id end
                end
            end
        end
    end

    -- pas retrouvée par URL : la première fenêtre nouvelle fera l'affaire
    for _, live in ipairs(chromeSnapshot()) do
        if not before[live.id] then return live.id end
    end

    return nil
end


local function createChromeWindow(win)

    if not win.tabs or #win.tabs == 0 then return false end

    local firstURL = win.tabs[1].url or "about:blank"

    ----------------------------------------------------------
    -- 1. Créer la fenêtre dans le bon profil et récupérer son ID
    ----------------------------------------------------------

    local winId = nil
    local dir, email = profileDirFor(win)

    if dir then
        winId = createWindowInProfile(win, dir)
        if winId then
            debugLog("CREATE", "profil " .. tostring(email) .. " (" .. dir .. ") id=" .. winId, nil)
        else
            print("[MCP CREATE] ouverture par profil échouée, repli AppleScript")
        end
    else
        print("[MCP CREATE] profil inconnu pour « " .. windowTitle(win) .. " », repli AppleScript (profil courant)")
    end

    if not winId then

        local createScript = table.concat({
            'tell application "Google Chrome"',
            '    activate',
            '    set w to make new window',
            '    set URL of active tab of w to ' .. asStr(firstURL),
            '    return (id of w as string)',
            'end tell'
        }, "\n")

        local okCreate, newId, errCreate =
            runAppleScript("createChromeWindow", createScript)

        if not okCreate then
            print("[MCP CREATE ERROR] " .. tostring(errCreate))
            return false
        end

        winId = tonumber(newId)

        if not winId then
            print("[MCP CREATE ERROR] ID de fenêtre illisible : " .. tostring(newId))
            return false
        end
    else
        -- les onglets sont déjà tous ouverts par `open` : on saute l'étape 2
        win._tabsAlreadyOpen = true
    end

    ----------------------------------------------------------
    -- 2. Ajouter les autres onglets  (tous dans UN seul script)
    ----------------------------------------------------------

    if #win.tabs > 1 and not win._tabsAlreadyOpen then

        local lines = {
            'tell application "Google Chrome"',
            '    try',
            '        set w to window id ' .. tostring(winId)
        }

        for i = 2, #win.tabs do

            local url = win.tabs[i].url or "about:blank"

            table.insert(
                lines,
                '        make new tab at end of tabs of w with properties {URL:'
                .. asStr(url) .. '}'
            )
        end

        table.insert(lines, '        return true')
        table.insert(lines, '    on error errMsg')
        table.insert(lines, '        return "ERR:" & errMsg')
        table.insert(lines, '    end try')
        table.insert(lines, 'end tell')

        local addScript = table.concat(lines, "\n")

        local okAdd, resAdd, errAdd = runAppleScript("add tabs", addScript)

        if not okAdd then
            print("[MCP ADD TAB ERROR] " .. tostring(errAdd))
        elseif resAdd ~= true then
            print("[MCP ADD TAB ERROR] " .. tostring(resAdd))
        end
    end

    ----------------------------------------------------------
    -- 3. Onglet actif + position/taille  (déterministe)
    ----------------------------------------------------------

    local active = win.activeTabIndex or 1

    local x, y, w, h = targetBounds(win)

    local finishScript = table.concat({
        'tell application "Google Chrome"',
        '    try',
        '        set w to window id ' .. tostring(winId),
        '        if ' .. tostring(active) .. ' <= (count of tabs of w) then',
        '            set active tab index of w to ' .. tostring(active),
        '        end if',
        '        set bounds of w to {'
            .. tostring(x) .. ', ' .. tostring(y) .. ', '
            .. tostring(x + w) .. ', ' .. tostring(y + h) .. '}',
        '        set index of w to 1',
        '        return true',
        '    on error errMsg',
        '        return "ERR:" & errMsg',
        '    end try',
        'end tell'
    }, "\n")

    win._tabsAlreadyOpen = nil

    local okFinish, resFinish = runAppleScript("finish window", finishScript)

    if okFinish and resFinish ~= true then
        print("[MCP FINISH ERROR] " .. tostring(resFinish))
    end

    return true, winId
end


------------------------------------------------------------
-- PETITS UTILITAIRES FENETRE (par ID)
------------------------------------------------------------

local function setWindowBounds(winId, x, y, w, h)
    runAppleScript("setWindowBounds", table.concat({
        'tell application "Google Chrome"',
        '    try',
        '        set bounds of (window id ' .. tostring(winId) .. ') to {'
            .. x .. ', ' .. y .. ', ' .. (x + w) .. ', ' .. (y + h) .. '}',
        '    end try',
        'end tell'
    }, "\n"))
end

-- Position actuelle {x, y} d'une fenêtre, ou nil
local function getWindowOrigin(winId)
    local ok, res = runAppleScript("getWindowOrigin", table.concat({
        'tell application "Google Chrome"',
        '    try',
        '        set b to bounds of (window id ' .. tostring(winId) .. ')',
        '        return ((item 1 of b) as string) & "," & ((item 2 of b) as string)',
        '    on error',
        '        return ""',
        '    end try',
        'end tell'
    }, "\n"))
    if not ok or type(res) ~= "string" then return nil end
    local x, y = res:match("^(-?%d+),(-?%d+)$")
    if not x then return nil end
    return { x = tonumber(x), y = tonumber(y) }
end

-- Rect complet {x, y, w, h} d'une fenêtre, ou nil
local function getWindowRect(winId)
    local ok, res = runAppleScript("getWindowRect", table.concat({
        'tell application "Google Chrome"',
        '    try',
        '        set b to bounds of (window id ' .. tostring(winId) .. ')',
        '        return ((item 1 of b) as string) & "," & ((item 2 of b) as string) & "," & ((item 3 of b) as string) & "," & ((item 4 of b) as string)',
        '    on error',
        '        return ""',
        '    end try',
        'end tell'
    }, "\n"))
    if not ok or type(res) ~= "string" then return nil end
    local x1, y1, x2, y2 = res:match("^(-?%d+),(-?%d+),(-?%d+),(-?%d+)$")
    if not x1 then return nil end
    return { x = tonumber(x1), y = tonumber(y1), w = tonumber(x2) - tonumber(x1), h = tonumber(y2) - tonumber(y1) }
end

local function sendWindowBack(winId)
    runAppleScript("sendWindowBack", table.concat({
        'tell application "Google Chrome"',
        '    try',
        '        set index of (window id ' .. tostring(winId) .. ') to (count of windows)',
        '    end try',
        'end tell'
    }, "\n"))
end

local function closeWindowById(winId)
    runAppleScript("closeWindowById", table.concat({
        'tell application "Google Chrome"',
        '    try',
        '        close (window id ' .. tostring(winId) .. ')',
        '    end try',
        'end tell'
    }, "\n"))
end

-- Place la fenêtre au centre de l'écran principal, à la taille mémorisée,
-- en cascade : chaque affichage décale de CASCADE_STEP px vers la droite
-- et le bas ; l'offset revient à 0 après CASCADE_MAX affichages.
local CASCADE_STEP = 30
local CASCADE_MAX  = 15
local cascadeIndex = 0

local function centerOnMainScreen(winId, win)
    local sf = hs.screen.primaryScreen():frame()
    local ww = math.min((win.bounds and win.bounds.w) or math.floor(sf.w * 0.8), math.floor(sf.w * 0.92))
    local hh = math.min((win.bounds and win.bounds.h) or math.floor(sf.h * 0.8), math.floor(sf.h * 0.90))

    local off = cascadeIndex * CASCADE_STEP
    cascadeIndex = (cascadeIndex + 1) % CASCADE_MAX

    -- on centre le paquet de fenêtres, pas seulement la première
    local span = (CASCADE_MAX - 1) * CASCADE_STEP / 2
    local x = math.floor(sf.x + (sf.w - ww) / 2 - span + off)
    local y = math.floor(sf.y + (sf.h - hh) / 2 - span + off)

    -- rester dans l'écran
    x = math.max(sf.x, math.min(x, sf.x + sf.w - ww))
    y = math.max(sf.y, math.min(y, sf.y + sf.h - hh))

    setWindowBounds(winId, x, y, ww, hh)

    return { x = x, y = y }
end


------------------------------------------------------------
-- F17 : MEMORISER / METTRE A JOUR
--
-- Une entrée existante est reconnue par :
--   - l'ID Chrome de la fenêtre  (si elle est toujours ouverte)
--   - sinon un recouvrement d'URLs (>= 1 URL commune)
-- -> plus de doublons quand on a juste navigué dans un onglet.
------------------------------------------------------------

local function findStoredWindow(collection, candidate)

    local full, path, count = wantedSets(candidate)

    if count == 0 then return nil end

    local function overlap(win)
        local urls = {}
        for _, tab in ipairs(win.tabs or {}) do table.insert(urls, tab.url or "") end
        return (matchScore(full, path, nil, urls))
    end

    -- a) même fenêtre Chrome ET au moins une URL commune
    if candidate.chromeWindowId then

        for i, win in ipairs(collection.windows) do

            if win.chromeWindowId
                and win.chromeWindowId == candidate.chromeWindowId
                and overlap(win) > 0
            then
                return i
            end
        end
    end

    -- b) recouvrement d'URLs

    local bestIndex, bestScore = nil, 0

    for i, win in ipairs(collection.windows) do

        local urls = {}

        for _, tab in ipairs(win.tabs or {}) do
            table.insert(urls, tab.url or "")
        end

        local score = matchScore(full, path, nil, urls)

        if score > bestScore then
            bestScore = score
            bestIndex = i
        end
    end

    if bestScore > 0 then return bestIndex end

    return nil
end


local function saveActiveChromeWindow()

    local t0 = nowMs()

    msg("F17 - MCP", "Lecture de la fenêtre active...", 1)

    debugLog("F17", "START", t0)

    local win, err = readFrontChromeWindow()

    if not win then
        msg("F17 - ERREUR", err, 6)
        print("[MCP F17 ERROR] " .. tostring(err))
        return
    end

    debugLog("F17", "Chrome lu - " .. tostring(#win.tabs) .. " onglets", t0)

    local _, _, realCount = wantedSets(win)

    if realCount == 0 then
        msg(
            "F17 - MCP IGNORE",
            "Cette fenêtre ne contient que des onglets vides"
            .. "\n(chrome://newtab) : rien à mémoriser",
            4
        )
        return
    end

    local collection = loadCollection()
    local existing   = findStoredWindow(collection, win)

    if existing then

        local before = collection.windows[existing]
        local oldTitle = windowTitle(before)
        local oldTabs  = #(before.tabs or {})

        -- mise à jour : onglets, onglet ACTIF à cet instant, écran, taille
        collection.windows[existing]   = win
        collection.currentIndex        = existing
        collection.lastRecalledIndex   = existing

        saveCollection(collection)

        msg(
            "F17 - MISE À JOUR  " .. existing .. "/" .. #collection.windows,
            "avant : " .. oldTitle .. " (" .. oldTabs .. " onglets)"
            .. "\nmaintenant : " .. windowTitle(win) .. " (" .. #win.tabs .. " onglets)"
            .. "\nonglet actif = " .. tostring(win.activeTabIndex)
            .. " · compte : " .. tostring(win.profile or win.profileName or "inconnu"),
            4, COLOR_UPDATE
        )

        debugLog("F17", "MISE À JOUR index=" .. existing .. " actif=" .. tostring(win.activeTabIndex), t0)

    else

        table.insert(collection.windows, win)

        collection.currentIndex      = #collection.windows
        collection.lastRecalledIndex = #collection.windows

        saveCollection(collection)

        msg(
            "F17 - NOUVELLE FENÊTRE  " .. #collection.windows .. "/" .. #collection.windows,
            windowTitle(win)
            .. "\n" .. #win.tabs .. " onglets · onglet actif = " .. tostring(win.activeTabIndex)
            .. "\ncompte : " .. tostring(win.profile or win.profileName or "inconnu"),
            4, COLOR_NEW
        )

        debugLog("F17", "NOUVELLE index=" .. #collection.windows, t0)
    end

    debugLog("F17", "FIN", t0)
end


------------------------------------------------------------
-- ETIQUETTES AU MILIEU DES FENETRES  (n° · intitulé, rouge = sélectionnée)
------------------------------------------------------------

local labels = {}

local function labelsHide()
    for _, c in pairs(labels) do c:delete() end
    labels = {}
end

-- items : { { index = i, rect = {x,y,w,h}, title = "…" }, … }
local function labelsShow(items, selIndex)

    labelsHide()

    for _, it in ipairs(items) do

        local r = it.rect
        if r and r.w > 80 and r.h > 60 then

            local text = it.index .. " · " .. tostring(it.title):sub(1, 48)
            local w    = math.min(r.w - 40, 60 + #text * 9)
            local h    = 46
            local sel  = (it.index == selIndex)

            local c = hs.canvas.new({
                x = r.x + (r.w - w) / 2, y = r.y + (r.h - h) / 2, w = w, h = h })

            c[1] = { type = "rectangle", action = "fill",
                roundedRectRadii = { xRadius = 12, yRadius = 12 },
                fillColor = sel and { red = 0.8, green = 0.12, blue = 0.12, alpha = 0.92 }
                               or  { red = 0, green = 0, blue = 0, alpha = 0.72 } }
            c[2] = { type = "text", text = text, textSize = 18, textColor = { white = 1 },
                textAlignment = "center", frame = { x = 8, y = 10, w = w - 16, h = h - 12 } }

            c:level(hs.canvas.windowLevels.screenSaver)
            c:behavior({ "canJoinAllSpaces", "stationary" })
            c:clickActivating(false)
            c:show()

            labels[#labels + 1] = c
        end
    end
end


local mosaic = { active = false, tiles = {}, sel = 0, tap = nil, before = nil, chosen = nil, at = 0 }


------------------------------------------------------------
-- F13 / F14 : LISTE EN SURIMPRESSION + CURSEUR
--
-- Une liste de LIST_SLOTS bâtonnets s'affiche sur l'écran
-- principal ; F13 monte, F14 descend. La fenêtre sélectionnée est
-- mise au premier plan SANS bouger ni changer de taille.
-- "✗" devant un bâtonnet = fenêtre absente (fermée).
-- La liste s'efface LIST_TIMEOUT s après la dernière touche.
--
-- F15 : bâtonnet ✗ → on rappelle la fenêtre, là où elle était
--       (ou plein page si on ne sait pas). Sinon : undo du dernier
--       F18 (l'entrée revient dans la liste et la fenêtre est
--       reconstruite).
-- F17 : ajoute / met à jour la fenêtre Chrome active (inchangé).
-- F18 : retire le bâtonnet sélectionné ET ferme sa fenêtre Chrome.
-- F19 : mosaïque de toutes les entrées sur l'écran du haut
--       (déplace, redimensionne, reconstruit les absentes) ; un
--       clic sur l'une d'elles la met plein écran sur le moniteur
--       principal.
------------------------------------------------------------

local LIST_SLOTS   = 24
local LIST_TIMEOUT = 5

local list = {
    lastClick = { i = 0, t = 0 },
    deleting  = false,   -- mode F18 : Delete confirme, Esc annule
    delTap    = nil,
    active = false,
    sel    = 0,
    top    = 1,        -- premier index affiché (défilement si > 15)
    canvas = nil,
    timer  = nil,
    snap   = nil,      -- snapshot Chrome de la session
    live   = {}        -- index -> { id, tab, name } ou false
}


local function listClose()
    labelsHide()
    list.active   = false
    list.deleting = false
    if list.delTap then list.delTap:stop()  ; list.delTap = nil end
    if list.timer  then list.timer:stop()   ; list.timer  = nil end
    if list.canvas then list.canvas:delete() ; list.canvas = nil end
end


local function listArm()
    if list.timer then list.timer:stop() end
    list.timer = hs.timer.doAfter(list.deleting and 15 or LIST_TIMEOUT, listClose)
end


-- Présence de chaque entrée (une passe Chrome)
local function listRefreshLive(collection)

    list.snap = chromeSnapshot()
    list.live = {}

    local assigned = assignLive(collection, list.snap)

    for i = 1, #collection.windows do
        list.live[i] = assigned[i] or false
        if list.live[i] then list.live[i].rect = getWindowRect(list.live[i].id) end
    end
end


local function listDraw(collection)

    local total = #collection.windows
    local sf    = hs.screen.primaryScreen():frame()
    local lineH = 28
    local w     = 420
    local shown = math.min(LIST_SLOTS, total)
    local bannerH = list.deleting and 58 or 0
    local h     = shown * lineH + 28 + bannerH

    if list.canvas then list.canvas:delete() end

    list.canvas = hs.canvas.new({ x = sf.x + sf.w - w - 24, y = sf.y + 24, w = w, h = h })
    list.canvas[1] = { type = "rectangle", action = "fill",
        roundedRectRadii = { xRadius = 14, yRadius = 14 },
        fillColor = { red = 0, green = 0, blue = 0, alpha = 0.82 } }

    -- fenêtre de défilement
    if list.sel < list.top then list.top = list.sel end
    if list.sel > list.top + shown - 1 then list.top = list.sel - shown + 1 end
    if list.top < 1 then list.top = 1 end

    for row = 0, shown - 1 do

        local i = list.top + row
        if i > total then break end

        local win  = collection.windows[i]
        local cur  = (i == list.sel)
        local here = list.live[i] and true or false
        local y    = 14 + row * lineH

        -- bâtonnet
        list.canvas[#list.canvas + 1] = { type = "rectangle", action = "fill",
            roundedRectRadii = { xRadius = 3, yRadius = 3 },
            fillColor = cur and { red = 1, green = 0.75, blue = 0.2 }
                     or (here and { white = 0.85 } or { white = 0.35 }),
            frame = { x = 14, y = y + 6, w = 6, h = lineH - 12 } }

        local acct = win.profile and (" · " .. win.profile:gsub("@gmail%.com$", "")) or ""
        list.canvas[#list.canvas + 1] = { type = "text",
            id = "line" .. i, trackMouseUp = true,
            text = (here and "   " or "✗  ") .. i .. "  " .. windowTitle(win):sub(1, 36) .. acct,
            textSize = 15,
            textColor = cur and { red = 1, green = 0.85, blue = 0.4 }
                     or (here and { white = 0.95 } or { white = 0.55 }),
            frame = { x = 28, y = y, w = w - 40, h = lineH } }
    end

    if total > shown then
        list.canvas[#list.canvas + 1] = { type = "text",
            text = list.top .. "–" .. math.min(total, list.top + shown - 1) .. " / " .. total,
            textSize = 11, textColor = { white = 0.5 }, textAlignment = "right",
            frame = { x = 0, y = h - bannerH - 16, w = w - 12, h = 14 } }
    end

    if list.deleting then
        list.canvas[#list.canvas + 1] = { type = "rectangle", action = "fill",
            roundedRectRadii = { xRadius = 8, yRadius = 8 },
            fillColor = { red = 0.75, green = 0.15, blue = 0.15, alpha = 0.95 },
            frame = { x = 10, y = h - bannerH + 2, w = w - 20, h = bannerH - 8 } }
        local target = collection.windows[list.sel]
        local live   = list.live[list.sel]
        local tline  = "→ " .. (target and windowTitle(target):sub(1, 40) or "?")
        local wline  = live and ("fenêtre Chrome : " .. tostring(live.name or ""):sub(1, 40))
                            or "fenêtre déjà fermée (✗) — seule la liste change"
        list.canvas[#list.canvas + 1] = { type = "text",
            text = tline .. "\n" .. wline .. "\n⌫ DELETE = retirer + fermer      ESC = annuler",
            textSize = 12, textColor = { white = 1 }, textAlignment = "center",
            frame = { x = 10, y = h - bannerH + 4, w = w - 20, h = bannerH - 8 } }
    end

    list.canvas:level(hs.canvas.windowLevels.screenSaver)
    list.canvas:behavior({ "canJoinAllSpaces", "stationary" })
    list.canvas:clickActivating(false)

    -- étiquettes au milieu des fenêtres ouvertes
    do
        local items = {}
        for i, win in ipairs(collection.windows) do
            if list.live[i] and list.live[i].rect then
                table.insert(items, { index = i, rect = list.live[i].rect, title = windowTitle(win) })
            end
        end
        labelsShow(items, list.sel)
    end

    -- double-clic sur une ligne : on va chercher la fenêtre et on la
    -- pose sur la moitié gauche de l'écran principal
    list.canvas:mouseCallback(function(_, event, id)

        if event ~= "mouseUp" or type(id) ~= "string" then return end

        local i = tonumber(id:match("^line(%d+)$"))
        if not i then return end

        local now = hs.timer.secondsSinceEpoch()
        local dbl = (list.lastClick.i == i) and (now - list.lastClick.t) < 0.45
        list.lastClick = { i = i, t = now }

        listArm()

        if not dbl then
            list.sel = i
            local c = loadCollection()
            c.currentIndex = i ; c.lastRecalledIndex = i
            saveCollection(c)
            listDraw(c)
            return
        end

        local c   = loadCollection()
        local win = c.windows[i]
        if not win then return end

        local liveId, tabIndex = nil, win.activeTabIndex or 1
        if list.live[i] then
            liveId, tabIndex = list.live[i].id, list.live[i].tab
        else
            local ok, newId = createChromeWindow(win)
            liveId = ok and newId or nil
            if liveId then list.live[i] = { id = liveId, tab = tabIndex } end
        end

        if not liveId then
            msg("LISTE", "Impossible d'ouvrir : " .. windowTitle(win), 2)
            return
        end

        local pf = hs.screen.primaryScreen():frame()
        setWindowBounds(liveId, math.floor(pf.x), math.floor(pf.y), math.floor(pf.w / 2), math.floor(pf.h))
        focusWindowById(liveId, tabIndex)

        win.chromeWindowId = liveId
        c.currentIndex = i ; c.lastRecalledIndex = i
        list.sel = i
        if list.live[i] then list.live[i].rect = getWindowRect(liveId) end
        saveCollection(c)
        listDraw(c)

        debugLog("LISTE", "double-clic " .. i .. " → moitié gauche", nil)
    end)

    list.canvas:show()
end


local function listStep(delta)

    local t0 = nowMs()

    local collection = loadCollection()
    local total      = #collection.windows

    if total == 0 then
        msg("F13 / F14", "Liste vide", 2)
        return
    end

    if not list.active then
        listRefreshLive(collection)
        list.sel    = collection.currentIndex or 0
        list.active = true
    end

    list.sel = list.sel + delta
    if list.sel > total then list.sel = 1 end
    if list.sel < 1 then list.sel = total end

    collection.currentIndex      = list.sel
    collection.lastRecalledIndex = list.sel

    local live = list.live[list.sel]

    if live then
        -- présente : devant, sans bouger
        focusWindowById(live.id, live.tab)
        collection.windows[list.sel].chromeWindowId = live.id
    end

    saveCollection(collection)
    listDraw(collection)
    listArm()

    debugLog("LISTE", (delta > 0 and "F14" or "F13") .. " -> " .. list.sel
        .. (live and " (présente)" or " (absente ✗)"), t0)
end


local function browsePrev() listStep(-1) end
local function browseNext() listStep(1)  end


------------------------------------------------------------
-- PLACEMENT "F15" : demi-largeur de l'écran principal, centrée,
-- SELECT_TOP_PT sous le bord supérieur (≈ 3 cm), pleine hauteur restante
------------------------------------------------------------

local SELECT_TOP_PT = 85    -- 3 cm ≈ 85 points

local function placeSelect(winId)
    local pf = hs.screen.primaryScreen():frame()
    local w  = math.floor(pf.w / 2)
    local x  = math.floor(pf.x + (pf.w - w) / 2)
    local y  = math.floor(pf.y) + SELECT_TOP_PT
    local h  = math.floor(pf.h) - SELECT_TOP_PT
    setWindowBounds(winId, x, y, w, h)
end


------------------------------------------------------------
-- MOSAIQUE : état, étiquettes, curseur
------------------------------------------------------------

local function topScreen()
    local best, y = hs.screen.primaryScreen(), math.huge
    for _, sc in ipairs(hs.screen.allScreens()) do
        local f = sc:frame()
        if f.y < y then best, y = sc, f.y end
    end
    return best
end


local function mosaicLabels(collection)
    local items = {}
    for _, t in ipairs(mosaic.tiles) do
        local win = collection.windows[t.index]
        if win then
            table.insert(items, { index = t.index, rect = { x = t.x, y = t.y, w = t.w, h = t.h },
                title = windowTitle(win) })
        end
    end
    labelsShow(items, mosaic.sel)
end


local function mosaicStop(silent)
    labelsHide()
    if mosaic.tap then mosaic.tap:stop() ; mosaic.tap = nil end
    mosaic.active = false
    mosaic.tiles  = {}
    if not silent then msg("F19", "Mosaïque libérée · F19 = remettre les pages", 1.5) end
end


local function mosaicTileFor(index)
    for _, t in ipairs(mosaic.tiles) do if t.index == index then return t end end
    return nil
end


------------------------------------------------------------
-- F15 : SELECTIONNER — la fenêtre du curseur vient devant,
-- demi-largeur, centrée, 3 cm sous le haut de l'écran principal
-- (reconstruite dans son compte si elle était fermée)
------------------------------------------------------------

local function selectCurrent()

    local collection = loadCollection()
    local total      = #collection.windows

    if total == 0 then msg("F15", "Liste vide", 2) return end

    local index
    if mosaic.active and mosaic.sel > 0 then index = mosaic.sel
    elseif list.active then index = list.sel
    else index = collection.lastRecalledIndex or collection.currentIndex or 0 end

    if index < 1 or index > total then
        msg("F15", "Aucune entrée sélectionnée\n\nF13 / F14 d'abord", 2)
        return
    end

    local win = collection.windows[index]

    local liveId, tabIndex = nil, win.activeTabIndex or 1
    local rebuilt = false

    if mosaic.active and mosaicTileFor(index) then
        local t = mosaicTileFor(index) ; liveId, tabIndex = t.id, t.tab
    elseif list.active and list.live[index] then
        liveId, tabIndex = list.live[index].id, list.live[index].tab
    else
        local assigned = assignLive(collection, chromeSnapshot())
        if assigned[index] then liveId, tabIndex = assigned[index].id, assigned[index].tab end
    end

    if not liveId then
        local ok, newId = createChromeWindow(win)
        liveId  = ok and newId or nil
        rebuilt = true
    end

    if not liveId then
        msg("F15 - ERREUR", "Impossible d'ouvrir : " .. windowTitle(win), 3)
        return
    end

    placeSelect(liveId)
    focusWindowById(liveId, tabIndex)

    win.chromeWindowId = liveId
    collection.currentIndex      = index
    collection.lastRecalledIndex = index
    saveCollection(collection)

    if mosaic.active then
        local t = mosaicTileFor(index)
        if t then
            local r = getWindowRect(liveId)
            if r then t.x, t.y, t.w, t.h = r.x, r.y, r.w, r.h end
        end
        mosaic.chosen = liveId
        mosaicLabels(collection)
    elseif list.active then
        list.live[index] = { id = liveId, tab = tabIndex, rect = getWindowRect(liveId) }
        listDraw(collection)
        listArm()
    end

    msg("F15 - " .. index .. "/" .. total, windowTitle(win)
        .. (rebuilt and "\nreconstruite" or "") .. "\ndevant · ½ largeur · 3 cm sous le haut", 2)

    debugLog("F15", "select index=" .. index .. " id=" .. tostring(liveId), nil)
end


------------------------------------------------------------
-- F18 : SUPPRIMER COMPLETEMENT (liste + fenêtre Chrome)
-- Bandeau ⌫ Delete / Esc dans la liste. Une sauvegarde manuelle
-- est faite juste avant (⌃⇧F pour la restaurer).
------------------------------------------------------------

local BACKUP_DIR = COLLECTION_DIR .. "/sauvegardes"

local function backupFile(tag)
    hs.fs.mkdir(BACKUP_DIR)
    local src = io.open(COLLECTION_FILE, "r")
    if not src then return nil end
    local content = src:read("*a") ; src:close()
    local name = "MEMCHROMEPAGES-" .. os.date("%Y%m%d-%H%M%S") .. (tag and ("-" .. tag) or "") .. ".json"
    local dst = io.open(BACKUP_DIR .. "/" .. name, "w")
    if not dst then return nil end
    dst:write(content) ; dst:close()
    return name
end


local function removeEntryNow(index)

    local collection = loadCollection()
    local total      = #collection.windows

    if total == 0 then msg("F18", "Liste déjà vide", 2) return end

    if not index then
        if mosaic.active and mosaic.sel > 0 then index = mosaic.sel
        elseif list.active then index = list.sel
        else index = collection.lastRecalledIndex or collection.currentIndex or 0 end
    end

    if index < 1 or index > total then
        msg("F18", "Aucune entrée sélectionnée\n\nF13 / F14 d'abord", 3)
        return
    end

    backupFile("avant-F18")

    -- la fenêtre à fermer = celle attribuée dans ce qui est AFFICHÉ
    local liveId, liveName = nil, nil
    if mosaic.active and mosaicTileFor(index) then
        liveId = mosaicTileFor(index).id
    elseif list.active and list.live[index] then
        liveId, liveName = list.live[index].id, list.live[index].name
    else
        local assigned = assignLive(collection, chromeSnapshot())
        if assigned[index] then liveId, liveName = assigned[index].id, assigned[index].name end
    end

    local removed = table.remove(collection.windows, index)
    local title   = windowTitle(removed)

    debugLog("F18", "supprime index=" .. index .. " « " .. title .. " » fenêtre="
        .. tostring(liveId) .. (liveName and (" (" .. liveName .. ")") or ""), nil)

    if liveId then closeWindowById(liveId) end

    table.insert(collection.trash, { index = index, win = removed, at = os.date("%Y-%m-%d %H:%M:%S") })
    while #collection.trash > 20 do table.remove(collection.trash, 1) end

    local newTotal = #collection.windows
    collection.currentIndex      = math.min(index, newTotal)
    collection.lastRecalledIndex = collection.currentIndex
    saveCollection(collection)

    if mosaic.active then
        local kept = {}
        for _, t in ipairs(mosaic.tiles) do
            if t.index ~= index then
                if t.index > index then t.index = t.index - 1 end
                table.insert(kept, t)
            end
        end
        mosaic.tiles = kept
        mosaic.sel   = math.min(index, newTotal)
        if newTotal > 0 then mosaicLabels(collection) else mosaicStop(true) end
    elseif list.active then
        listRefreshLive(collection)
        list.sel = collection.currentIndex
        if newTotal > 0 then listDraw(collection) else listClose() end
        listArm()
    end

    msg("F18 - SUPPRIMÉE", title .. (liveId and "\nfenêtre Chrome fermée" or "")
        .. "\n" .. newTotal .. " restantes · ⌃⇧F pour restaurer", 3)
end


local function removeLastRecalledWindow()

    local collection = loadCollection()
    local total      = #collection.windows

    if total == 0 then msg("F18", "Liste déjà vide", 2) return end

    -- dans la mosaïque : suppression directe de la tuile sélectionnée
    if mosaic.active and mosaic.sel > 0 then
        removeEntryNow(mosaic.sel)
        return
    end

    if not list.active then
        listRefreshLive(collection)
        list.sel = math.max(1, math.min(total, collection.currentIndex or 1))
        list.active = true
    end

    list.deleting = true
    listDraw(collection)
    listArm()

    if list.delTap then list.delTap:stop() end

    list.delTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)

        if not list.deleting then return false end

        local code = e:getKeyCode()

        if code == 51 or code == 117 then        -- ⌫ / ⌦
            list.deleting = false
            if list.delTap then list.delTap:stop() ; list.delTap = nil end
            removeEntryNow(list.sel)
            return true
        elseif code == 53 then                   -- Esc
            list.deleting = false
            if list.delTap then list.delTap:stop() ; list.delTap = nil end
            listDraw(loadCollection())
            listArm()
            msg("F18", "Annulé", 1)
            return true
        end

        return false
    end)

    list.delTap:start()
end


------------------------------------------------------------
-- F19 : MOSAIQUE SUR L'ECRAN DU HAUT
--   reste affichée jusqu'à : clic GAUCHE = la macro s'arrête
--   (les fenêtres restent) ; clic DROIT sur une fenêtre = comme F15
--   F13 / F14 déplacent le curseur rouge, F15 / F18 s'y appliquent
--   F19 à nouveau = remettre les pages comme avant
------------------------------------------------------------

local function mosaicUndo()

    local restored, closed = 0, 0

    for _, b in ipairs(mosaic.before or {}) do
        if b.id ~= mosaic.chosen then
            if b.rebuilt then
                closeWindowById(b.id) ; closed = closed + 1
            elseif b.rect then
                setWindowBounds(b.id, b.rect.x, b.rect.y, b.rect.w, b.rect.h) ; restored = restored + 1
            end
        end
    end

    mosaicStop(true)
    mosaic.before = nil
    mosaic.chosen = nil

    msg("F19 - ÉCRAN REMIS", restored .. " fenêtres remises en place"
        .. (closed > 0 and (" · " .. closed .. " reconstruites refermées") or ""), 3)
end


local function buildMosaic()

    local t0 = nowMs()

    local collection = loadCollection()
    local total      = #collection.windows

    if total == 0 then msg("F19", "Liste vide", 2) return end

    mosaicStop(true)
    mosaic.before = {}
    mosaic.chosen = nil
    mosaic.at     = hs.timer.secondsSinceEpoch()

    local sc   = topScreen()
    local sf   = sc:frame()
    local snap = chromeSnapshot()

    local cols  = math.ceil(math.sqrt(total))
    local rows  = math.ceil(total / cols)
    local gap   = 10
    local cellW = math.floor((sf.w - (cols + 1) * gap) / cols)
    local cellH = math.floor((sf.h - (rows + 1) * gap) / rows)

    local rebuilt  = 0
    local assigned = assignLive(collection, snap)

    for i, win in ipairs(collection.windows) do

        local liveId, tabIndex = nil, 1
        if assigned[i] then liveId, tabIndex = assigned[i].id, assigned[i].tab end

        local wasRebuilt = false
        if not liveId then
            local ok, newId = createChromeWindow(win)
            liveId = ok and newId or nil
            if liveId then rebuilt = rebuilt + 1 ; wasRebuilt = true end
        end

        if liveId then
            table.insert(mosaic.before, { id = liveId, rebuilt = wasRebuilt,
                rect = (not wasRebuilt) and getWindowRect(liveId) or nil })

            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local x = math.floor(sf.x + gap + col * (cellW + gap))
            local y = math.floor(sf.y + gap + row * (cellH + gap))
            setWindowBounds(liveId, x, y, cellW, cellH)
            win.chromeWindowId = liveId
            table.insert(mosaic.tiles, { id = liveId, tab = tabIndex, index = i,
                x = x, y = y, w = cellW, h = cellH })
        end
    end

    saveCollection(collection)

    mosaic.active = true
    mosaic.sel    = math.max(1, math.min(total, collection.currentIndex or 1))
    mosaicLabels(collection)

    -- clic gauche = stop ; clic droit sur une tuile = comme F15
    mosaic.tap = hs.eventtap.new(
        { hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.rightMouseDown },
        function(e)

            if not mosaic.active then return false end

            local pt = e:location()
            local t  = e:getType()

            if t == hs.eventtap.event.types.leftMouseDown then
                mosaicStop(false)
                return false
            end

            for _, tile in ipairs(mosaic.tiles) do
                if pt.x >= tile.x and pt.x < tile.x + tile.w and pt.y >= tile.y and pt.y < tile.y + tile.h then
                    mosaic.sel = tile.index
                    selectCurrent()
                    return true
                end
            end

            return false
        end)

    mosaic.tap:start()

    msg("F19 - MOSAÏQUE", total .. " fenêtres" .. (rebuilt > 0 and (" · " .. rebuilt .. " reconstruites") or "")
        .. "\n\nF13 / F14 curseur · F15 ou clic droit = devant ½ largeur"
        .. "\nF18 = supprimer · clic gauche = quitter · F19 = remettre les pages", 8)

    debugLog("F19", "mosaïque " .. total .. " (" .. rebuilt .. " reconstruites)", t0)
end


local function recallAllMCP()

    -- F19 après une mosaïque = tout remettre comme avant
    if mosaic.before then
        mosaicUndo()
        return
    end

    -- accusé de réception immédiat, puis le travail (qui peut prendre quelques secondes)
    msg("F19", "⏳ mosaïque en préparation…", 10)
    hs.timer.doAfter(0.05, buildMosaic)
end


------------------------------------------------------------
-- F13 / F14 : curseur de la mosaïque quand elle est active,
-- sinon la liste
------------------------------------------------------------

local function browsePrev()
    if mosaic.active and #mosaic.tiles > 0 then
        local c = loadCollection()
        mosaic.sel = mosaic.sel - 1 ; if mosaic.sel < 1 then mosaic.sel = #c.windows end
        c.currentIndex = mosaic.sel ; c.lastRecalledIndex = mosaic.sel ; saveCollection(c)
        mosaicLabels(c)
        return
    end
    listStep(-1)
end

local function browseNext()
    if mosaic.active and #mosaic.tiles > 0 then
        local c = loadCollection()
        mosaic.sel = mosaic.sel + 1 ; if mosaic.sel > #c.windows then mosaic.sel = 1 end
        c.currentIndex = mosaic.sel ; c.lastRecalledIndex = mosaic.sel ; saveCollection(c)
        mosaicLabels(c)
        return
    end
    listStep(1)
end


------------------------------------------------------------
-- SYNCHRO AUTOMATIQUE
--
-- Toutes les SYNC_EVERY secondes, et à chaque changement de
-- fenêtre Chrome (focus, fermeture), chaque entrée MCP dont la
-- fenêtre est ouverte est mise à jour : onglets, onglet ACTIF,
-- position, taille, écran. Ainsi, quand on ferme une fenêtre,
-- l'entrée reflète son dernier état — et F15 la rouvre sur le
-- dernier onglet actif.
-- Seules les fenêtres reconnues par IDENTITÉ sont synchronisées.
------------------------------------------------------------

local SYNC_EVERY = 30
local syncBusy   = false

local function autoSync(reason)

    if syncBusy or BUSY then return end
    syncBusy = true

    local ok, err = pcall(function()

        local collection = loadCollection()
        if #collection.windows == 0 then return end

        local snap = chromeSnapshot()
        if #snap == 0 then return end

        local byId = {}
        for _, live in ipairs(snap) do byId[live.id] = live end

        local assigned = assignLive(collection, snap)
        local changed  = 0

        for i, win in ipairs(collection.windows) do

            local a = assigned[i]
            local live = a and a.how == "id" and byId[a.id] or nil

            if live and #live.urls > 0 then

                local newTabs = {}
                for k, u in ipairs(live.urls) do
                    table.insert(newTabs, { url = u, title = live.titles[k] or "" })
                end

                local sameTabs = (#newTabs == #(win.tabs or {}))
                if sameTabs then
                    for k, t in ipairs(newTabs) do
                        local old = win.tabs[k]
                        if not old or old.url ~= t.url or old.title ~= t.title then sameTabs = false break end
                    end
                end

                local sameActive = (win.activeTabIndex == live.active)
                local sameBounds = win.bounds and live.bounds
                    and win.bounds.x == live.bounds.x and win.bounds.y == live.bounds.y
                    and win.bounds.w == live.bounds.w and win.bounds.h == live.bounds.h

                if not (sameTabs and sameActive and sameBounds) then
                    win.tabs           = newTabs
                    win.activeTabIndex = live.active
                    if live.bounds then
                        win.bounds = live.bounds
                        local sc = screenAtPoint(live.bounds.x + live.bounds.w / 2, live.bounds.y + live.bounds.h / 2)
                        win.screenUUID = sc and sc:getUUID() or win.screenUUID
                    end
                    win.chromeWindowId = live.id
                    changed = changed + 1
                end
            end
        end

        if changed > 0 then
            saveCollection(collection)
            debugLog("SYNC", tostring(reason) .. " : " .. changed .. " entrée(s) mise(s) à jour", nil)
        end
    end)

    syncBusy = false

    if not ok then print("[MCP SYNC ERROR] " .. tostring(err)) end
end

local syncTimer = hs.timer.doEvery(SYNC_EVERY, function() autoSync("périodique") end)

-- déclenchement immédiat (avec 0,8 s de latence) sur changement de fenêtre Chrome
local syncDebounce = nil
local chromeFilter = hs.window.filter.new("Google Chrome")

chromeFilter:subscribe(
    { hs.window.filter.windowFocused, hs.window.filter.windowUnfocused,
      hs.window.filter.windowDestroyed, hs.window.filter.windowMoved },
    function(_, _, event)
        if syncDebounce then syncDebounce:stop() end
        syncDebounce = hs.timer.doAfter(0.8, function() autoSync(event) end)
    end
)


------------------------------------------------------------
-- CTRL+F : SAUVEGARDE MANUELLE DE LA LISTE  (jamais effacée)
-- CTRL+SHIFT+F : RESTAURER LA DERNIERE SAUVEGARDE MANUELLE
------------------------------------------------------------

local function backupList()

    hs.fs.mkdir(BACKUP_DIR)

    local src = io.open(COLLECTION_FILE, "r")
    if not src then msg("SAUVEGARDE", "Liste introuvable", 2) return end
    local content = src:read("*a") ; src:close()

    local name = "MEMCHROMEPAGES-" .. os.date("%Y%m%d-%H%M%S") .. ".json"
    local dst  = io.open(BACKUP_DIR .. "/" .. name, "w")
    if not dst then msg("SAUVEGARDE", "Écriture impossible", 2) return end
    dst:write(content) ; dst:close()

    local n = 0
    for f in hs.fs.dir(BACKUP_DIR) do if f:match("%.json$") then n = n + 1 end end

    local c = loadCollection()
    msg("⌃F - SAUVEGARDÉE", #c.windows .. " entrées → sauvegardes/" .. name .. "\n" .. n .. " sauvegarde(s) au total", 3)
    debugLog("BACKUP", name, nil)
end


local function restoreLastBackup()

    local names = {}
    for f in hs.fs.dir(BACKUP_DIR) do
        if f:match("^MEMCHROMEPAGES%-.*%.json$") then table.insert(names, f) end
    end
    table.sort(names)

    if #names == 0 then msg("⌃⇧F", "Aucune sauvegarde manuelle", 2) return end

    local last = names[#names]
    local src  = io.open(BACKUP_DIR .. "/" .. last, "r")
    if not src then msg("⌃⇧F", "Lecture impossible", 2) return end
    local content = src:read("*a") ; src:close()

    local data = hs.json.decode(content)
    if not data or not data.windows then msg("⌃⇧F", "Sauvegarde illisible", 2) return end

    saveCollection(loadCollection())   -- l'état actuel part dans l'historique avant tout
    saveCollection(data)

    if list.active then listClose() end

    msg("⌃⇧F - RESTAURÉE", last .. "\n" .. #data.windows .. " entrées", 3)
    debugLog("RESTORE", last, nil)
end


hs.hotkey.bind({ "ctrl" }, "F", backupList)
hs.hotkey.bind({ "ctrl", "shift" }, "F", restoreLastBackup)


------------------------------------------------------------
-- DEBUG ON/OFF
------------------------------------------------------------

hs.hotkey.bind({ "cmd", "alt", "ctrl" }, "D", function()

    DEBUG = not DEBUG

    msg("MCP DEBUG", DEBUG and "ACTIVE" or "DESACTIVE", 2)

    print("[MCP DEBUG] DEBUG=" .. tostring(DEBUG))
end)


------------------------------------------------------------
-- RACCOURCIS
------------------------------------------------------------

hs.hotkey.bind({}, "F13", guarded("F13", browsePrev))
hs.hotkey.bind({}, "F14", guarded("F14", browseNext))
hs.hotkey.bind({}, "F15", guarded("F15", selectCurrent))

-- F16 reste exclusivement à Shottr

hs.hotkey.bind({}, "F17", guarded("F17", saveActiveChromeWindow))
hs.hotkey.bind({}, "F18", guarded("F18", removeLastRecalledWindow))
hs.hotkey.bind({}, "F19", guarded("F19", recallAllMCP))


------------------------------------------------------------
-- DEMARRAGE
------------------------------------------------------------

local startCollection = loadCollection()

print("")
print("==========================================")
print(" MEMCHROMEPAGES / MCP  " .. VERSION)
print(" MCP = " .. #startCollection.windows .. " entrées")
print(" F13/F14 = liste curseur")
print(" F15 = undo")
print(" F16 = Shottr")
print(" F17 = mémoriser")
print(" F18 = retirer")
print(" F19 = toutes")
print(" DEBUG = " .. tostring(DEBUG))
do
    local p = chromeProfiles()
    for dir, info in pairs(p.dirs) do
        print(" profil Chrome : " .. dir .. " = " .. info.name .. " <" .. info.email .. ">")
    end
end
print("==========================================")
print("")

msg(
    "HAMMERSPOON PRET  —  " .. VERSION,
    "MCP : " .. #startCollection.windows .. " entrées"
    .. "\n\nF1 / F2   luminosité − / +"
    .. "\nF3        vue éclatée"
    .. "\nF4        fenêtre sous souris → clic → coller → Enter"
    .. "\nF5        zone → clic → coller"
    .. "\nF11       relire le brouillon (Claude) · F12 coller la proposition"
    .. "\nF13 / F14 liste : curseur ↑ ↓, fenêtre devant · double-clic = ½ gauche"
    .. "\nF15       sélectionner : devant, ½ largeur, 3 cm sous le haut"
    .. "\nF16       Shottr"
    .. "\nF17       mémoriser"
    .. "\nF18       supprimer (liste + fenêtre) · ⌫ Delete / Esc"
    .. "\nF19       mosaïque · clic droit = F15 · clic gauche = quitter · F19 = remettre"
    .. "\n⌃F        sauvegarder la liste · ⌃⇧F restaurer"
    .. "\n\nDEBUG : " .. (DEBUG and "ON" or "OFF"),
    7
)


------------------------------------------------------------
-- MODULE SEPARE : CAPTURE F4 / F5  (capture.lua)
------------------------------------------------------------

local okCapture, errCapture = pcall(dofile, hs.configdir .. "/capture.lua")

if not okCapture then
    print("[CAPTURE] non chargé : " .. tostring(errCapture))
end


------------------------------------------------------------
-- MODULE SEPARE : F1 / F2 / F3  (funkeys.lua)
------------------------------------------------------------

local okFun, errFun = pcall(dofile, hs.configdir .. "/funkeys.lua")

if not okFun then
    print("[FUNKEYS] non chargé : " .. tostring(errFun))
end


------------------------------------------------------------
-- MODULE SEPARE : ASSISTANT F11 / F12  (assist.lua)
------------------------------------------------------------

local okAssist, errAssist = pcall(dofile, hs.configdir .. "/assist.lua")

if not okAssist then
    print("[ASSIST] non chargé : " .. tostring(errAssist))
end
