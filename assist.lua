------------------------------------------------------------
-- ASSISTANT DE REDACTION  —  F11 / F12  (API Claude directe)
--
-- F11 : dans Mail, WhatsApp, ou n'importe quel champ de texte
--       → copie le texte du champ actif (⌘A ⌘C) + capture de la
--         fenêtre pour le contexte (fil WhatsApp, mail cité)
--       → envoie le tout à Claude via l'API, avec les consignes
--         de CONSIGNES ci-dessous
--       → affiche à droite de l'écran principal : commentaire,
--         questions éventuelles, et la PROPOSITION de texte
--       → la proposition est déjà dans le presse-papiers
--
-- F12 : badge 📋 → tu cliques dans le champ cible (après avoir
--       sélectionné ce qu'il faut remplacer) → la proposition est
--       collée par-dessus la sélection. Sans sélection : insérée
--       au curseur. Le panneau se ferme.
--
-- Esc ferme le panneau. Chaque échange est journalisé dans
-- ~/.hammerspoon/corrections/.
--
-- PREREQUIS
--   1. ~/.hammerspoon/secrets.lua contenant :
--        return { anthropic = "sk-ant-…" }
--   2. Réglages Système → Clavier → Raccourcis → Mission Control :
--      décocher « Afficher le bureau » (F11), sinon F11 n'arrive
--      jamais à Hammerspoon.
------------------------------------------------------------


local MODEL       = "claude-sonnet-4-5"     -- rapide ; changer ici si besoin
local MAX_TOKENS  = 2000
local IMG_MAX_W   = 1600                     -- largeur max de la capture envoyée
local LOG_DIR     = os.getenv("HOME") .. "/.hammerspoon/corrections"
local OPEN_MARK   = "⟦⟦"
local CLOSE_MARK  = "⟧⟧"

hs.fs.mkdir(LOG_DIR)


local CONSIGNES = [[
Tu es l'assistant de rédaction de Pierre Lhoest (entrepreneur, fondateur d'EVS, THE FAKTORY). Il t'envoie une capture de la fenêtre où il écrit (Mail, WhatsApp, autre) et le texte du champ actif.

Ta mission :
1. Identifie ce qui est SON BROUILLON (ce qu'il est en train d'écrire) et ce qui est le CONTEXTE (message reçu, mail cité, fil de discussion).
2. Réécris son brouillon pour le rendre plus clair, plus concis (surtout s'il est long), plus professionnel et bien structuré, en restant fidèle à SON style : direct, chaleureux, sans jargon, tutoiement ou vouvoiement conservés tels qu'il les emploie. Garde la langue du brouillon. Ne change pas le fond ni les décisions ; n'invente rien.
3. Pierre est dyslexique et dicte souvent : corrige orthographe, grammaire, mots mal transcrits, sans jamais le commenter.
4. Si quelque chose n'est pas clair, manque, ou mériterait une modification plus importante (ton trop sec, promesse floue, chiffre absent, point non répondu du message reçu), dis-le dans QUESTIONS/SUGGESTIONS, en 1 à 4 puces courtes. Sinon écris « aucune ».
5. Si le brouillon a un ton professoral ou donneur de leçons, signale-le en une ligne.

FORMAT DE REPONSE, STRICT, sans rien d'autre :

COMMENTAIRE : une ou deux phrases sur ce que tu as changé et pourquoi.
QUESTIONS/SUGGESTIONS :
- …
⟦⟦
le texte final, prêt à coller, sans guillemets, sans titre, sans signature ajoutée
⟧⟧
]]


------------------------------------------------------------
-- outils
------------------------------------------------------------

local function log(t) print("[ASSIST] " .. tostring(t)) end

local function alert(t, d)
    hs.alert.closeAll()
    hs.alert.show(t, { textSize = 18, radius = 10, padding = 12 }, hs.screen.mainScreen(), d or 1.5)
end

local function apiKey()
    local ok, secrets = pcall(dofile, hs.configdir .. "/secrets.lua")
    if ok and type(secrets) == "table" and secrets.anthropic then return secrets.anthropic end
    return nil
end

local function jsonEscape(s)
    return (s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', ''):gsub('\t', '\\t'))
end


------------------------------------------------------------
-- panneau de résultat (webview à droite de l'écran principal)
------------------------------------------------------------

local panel     = nil
local lastText  = nil
local escTap    = nil


local function panelClose()
    if panel then panel:delete() ; panel = nil end
    if escTap then escTap:stop() ; escTap = nil end
end


local function htmlEscape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end


local function panelShow(comment, questions, proposal, pending)

    panelClose()

    local sf = hs.screen.primaryScreen():frame()
    local w  = math.floor(sf.w * 0.34)
    local h  = math.floor(sf.h * 0.85)
    local x  = math.floor(sf.x + sf.w - w - 16)
    local y  = math.floor(sf.y + 40)

    local body
    if pending then
        body = '<div class="wait">⏳ ' .. htmlEscape(pending) .. '</div>'
    else
        body = '<h2>Commentaire</h2><p>' .. htmlEscape(comment) .. '</p>'
            .. '<h2>Questions / suggestions</h2><p>' .. htmlEscape(questions):gsub("\n", "<br>") .. '</p>'
            .. '<h2>Proposition <span class="hint">— déjà copiée · F12 puis clic dans le champ pour remplacer</span></h2>'
            .. '<pre>' .. htmlEscape(proposal) .. '</pre>'
    end

    local html = [[<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;padding:18px 20px;font:15px/1.5 -apple-system,Helvetica,Arial,sans-serif;background:#1d1e22;color:#ecebe6}
h2{font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:#f0a838;margin:18px 0 6px}
h2:first-child{margin-top:0}
.hint{color:#9a9b94;font-weight:400;letter-spacing:0;text-transform:none}
p{margin:0;white-space:pre-wrap}
pre{white-space:pre-wrap;font:15px/1.5 -apple-system,Helvetica,Arial,sans-serif;background:#26282e;border:1px solid #3a3c44;border-radius:10px;padding:14px;margin:0}
.wait{font-size:20px;color:#f0a838;padding:40px 0;text-align:center}
.foot{margin-top:16px;color:#9a9b94;font-size:12px}
</style></head><body>]] .. body ..
    '<div class="foot">Esc = fermer</div></body></html>'

    panel = hs.webview.new({ x = x, y = y, w = w, h = h })
    panel:windowStyle({ "utility", "nonactivating", "HUD", "titled", "closable" })
    panel:windowTitle("Assistant — F12 pour coller")
    panel:level(hs.drawing.windowLevels.floating)
    panel:allowTextEntry(false)
    panel:html(html)
    panel:show()

    escTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
        if e:getKeyCode() == 53 then panelClose() ; return true end
        return false
    end)
    escTap:start()
end


------------------------------------------------------------
-- capture du champ actif + fenêtre
------------------------------------------------------------

local function grabFieldText(app)

    local saved = hs.pasteboard.getContents()
    local before = hs.pasteboard.changeCount()

    hs.eventtap.keyStroke({ "cmd" }, "a", 100000, app)
    hs.eventtap.keyStroke({ "cmd" }, "c", 100000, app)

    -- laisser le temps à l'app de remplir le presse-papiers
    local text = nil
    for _ = 1, 20 do
        hs.timer.usleep(50000)
        if hs.pasteboard.changeCount() ~= before then
            text = hs.pasteboard.getContents()
            break
        end
    end

    -- replier la sélection au début du champ
    hs.eventtap.keyStroke({}, "left", 50000, app)

    if saved then hs.pasteboard.setContents(saved) end

    return text or ""
end


local function windowImageBase64(win)

    local img = win:snapshot()
    if not img then return nil end

    local size = img:size()
    if size.w > IMG_MAX_W then
        img = img:setSize({ w = IMG_MAX_W, h = math.floor(size.h * IMG_MAX_W / size.w) })
    end

    local url = img:encodeAsURLString(false, "PNG")
    if not url then return nil end

    return url:match("^data:image/png;base64,(.+)$")
end


------------------------------------------------------------
-- appel API
------------------------------------------------------------

local function parseReply(text)

    local proposal = text:match(OPEN_MARK .. "%s*(.-)%s*" .. CLOSE_MARK)
    local head     = text:match("^(.-)" .. OPEN_MARK) or text

    local comment   = head:match("COMMENTAIRE%s*:%s*(.-)%s*QUESTIONS") or head:match("COMMENTAIRE%s*:%s*(.-)%s*$") or head
    local questions = head:match("QUESTIONS/SUGGESTIONS%s*:%s*(.-)%s*$") or "aucune"

    return (comment:gsub("^%s+", "")), (questions:gsub("^%s+", "")), proposal
end


local function logExchange(app, title, draft, reply)

    local f = io.open(LOG_DIR .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".md", "w")
    if not f then return end
    f:write("# " .. os.date("%Y-%m-%d %H:%M") .. " — " .. tostring(app) .. " — " .. tostring(title) .. "\n\n")
    f:write("## Brouillon\n\n" .. tostring(draft) .. "\n\n## Réponse\n\n" .. tostring(reply) .. "\n")
    f:close()
end


local function askClaude(appName, title, draft, imageB64)

    local key = apiKey()
    if not key then
        panelClose()
        alert("F11 — clé API absente : crée ~/.hammerspoon/secrets.lua", 5)
        return
    end

    local userText =
        "Application : " .. appName .. "\nFenêtre : " .. title
        .. "\n\nTEXTE DU CHAMP ACTIF (brouillon + éventuellement contexte cité) :\n" .. draft

    local content = '[{"type":"text","text":"' .. jsonEscape(userText) .. '"}'
    if imageB64 then
        content = content .. ',{"type":"image","source":{"type":"base64","media_type":"image/png","data":"' .. imageB64 .. '"}}'
    end
    content = content .. ']'

    local body = '{"model":"' .. MODEL .. '","max_tokens":' .. MAX_TOKENS
        .. ',"system":"' .. jsonEscape(CONSIGNES) .. '"'
        .. ',"messages":[{"role":"user","content":' .. content .. '}]}'

    local headers = {
        ["content-type"]      = "application/json",
        ["x-api-key"]         = key,
        ["anthropic-version"] = "2023-06-01"
    }

    local t0 = hs.timer.secondsSinceEpoch()

    hs.http.asyncPost("https://api.anthropic.com/v1/messages", body, headers, function(status, resp)

        local dt = string.format("%.1f s", hs.timer.secondsSinceEpoch() - t0)

        if status ~= 200 then
            log("HTTP " .. tostring(status) .. " : " .. tostring(resp))
            panelClose()
            alert("F11 — erreur API " .. tostring(status), 4)
            return
        end

        local ok, data = pcall(hs.json.decode, resp)
        local text = ok and data and data.content and data.content[1] and data.content[1].text or nil

        if not text then
            log("réponse illisible : " .. tostring(resp))
            panelClose()
            alert("F11 — réponse illisible", 3)
            return
        end

        local comment, questions, proposal = parseReply(text)

        if not proposal then
            proposal = text
            comment  = "(format inattendu : texte brut ci-dessous)"
        end

        lastText = proposal
        hs.pasteboard.setContents(proposal)
        logExchange(appName, title, draft, text)

        panelShow(comment, questions, proposal, nil)
        alert("Proposition prête (" .. dt .. ") — F12 pour coller", 2)
        log("réponse en " .. dt)
    end)
end


------------------------------------------------------------
-- F11
------------------------------------------------------------

local function assistDraft()

    alert("⏳ F11 — lecture du champ…", 2)

    local win = hs.window.focusedWindow()
    local app = win and win:application() or hs.application.frontmostApplication()
    if not win or not app then alert("F11 — aucune fenêtre active", 2) return end

    local appName = app:name() or "?"
    local title   = win:title() or ""

    hs.timer.doAfter(0.05, function()

        local draft = grabFieldText(app)

        if draft == "" then
            alert("F11 — champ vide ou texte non copiable", 3)
            return
        end

        local img = windowImageBase64(win)

        panelShow(nil, nil, nil, "Claude relit ton brouillon…")
        log("F11 : " .. appName .. " / " .. title .. " — " .. #draft .. " caractères, image " .. (img and "oui" or "non"))

        askClaude(appName, title, draft, img)
    end)
end


------------------------------------------------------------
-- F12 : coller la proposition là où tu cliques
------------------------------------------------------------

local pasteTap, pasteTimer = nil, nil
local pasteBadge = nil

local function pasteStop()
    if pasteTap then pasteTap:stop() ; pasteTap = nil end
    if pasteTimer then pasteTimer:stop() ; pasteTimer = nil end
    if pasteBadge then pasteBadge:delete() ; pasteBadge = nil end
end


local function pasteProposal()

    if not lastText then alert("F12 — rien à coller : fais F11 d'abord", 2) return end

    pasteStop()

    local pos = hs.mouse.absolutePosition()
    pasteBadge = hs.canvas.new({ x = pos.x + 14, y = pos.y + 14, w = 44, h = 44 })
    pasteBadge[1] = { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 10, yRadius = 10 },
        fillColor = { red = 0.85, green = 0.55, blue = 0.1, alpha = 0.9 } }
    pasteBadge[2] = { type = "text", text = "📋", textSize = 26, textAlignment = "center",
        frame = { x = 0, y = 4, w = 44, h = 40 } }
    pasteBadge:level(hs.canvas.windowLevels.screenSaver)
    pasteBadge:behavior({ "canJoinAllSpaces", "stationary" })
    pasteBadge:show()

    local follow = hs.timer.doEvery(0.03, function()
        if not pasteBadge then return end
        local p = hs.mouse.absolutePosition()
        pasteBadge:topLeft({ x = p.x + 14, y = p.y + 14 })
    end)

    alert("F12 — clique dans le champ (sélection = remplacée)", 2)

    pasteTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseUp }, function()

        follow:stop()
        pasteStop()

        hs.timer.doAfter(0.25, function()
            local app = hs.application.frontmostApplication()
            hs.pasteboard.setContents(lastText)
            hs.eventtap.keyStroke({ "cmd" }, "v", 200000, app)
            panelClose()
            alert("Collé ✅", 1)
            log("F12 : collé dans " .. (app and app:name() or "?"))
        end)

        return false
    end)

    pasteTap:start()

    pasteTimer = hs.timer.doAfter(20, function()
        follow:stop()
        pasteStop()
    end)
end


hs.hotkey.bind({}, "F11", assistDraft)
hs.hotkey.bind({}, "F12", pasteProposal)

print("[ASSIST] F11 = relire le brouillon (API " .. MODEL .. ") | F12 = coller la proposition")
