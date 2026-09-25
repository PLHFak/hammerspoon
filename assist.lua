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
--       → en bas du panneau : un champ « consigne » pour demander
--         une retouche (plus court, plus formel, ajoute…) —
--         Entrée = renvoyer ; Claude garde tout le fil en mémoire
--       → bouton « Coller » (ou F12) quand c'est bon
--
-- F12 / bouton Coller : badge 📋 → tu cliques dans le champ
--       cible → la proposition est collée. Si « remplacer tout
--       le champ » est coché, ⌘A est fait avant (WhatsApp) ;
--       sinon elle remplace la sélection / s'insère au curseur
--       (Mail : sélectionne d'abord ton brouillon).
--
-- Esc ferme le panneau. Chaque échange est journalisé dans
-- ~/.hammerspoon/corrections/.
--
-- PREREQUIS : ~/.hammerspoon/secrets.lua contenant
--     return { anthropic = "sk-ant-…" }
------------------------------------------------------------


local MODEL       = "claude-sonnet-4-5"     -- rapide ; changer ici si besoin
local MAX_TOKENS  = 2000
local IMG_MAX_W   = 1600                     -- largeur max de la capture envoyée
local LOG_DIR     = os.getenv("HOME") .. "/.hammerspoon/corrections"
local OPEN_MARK   = "⟦⟦"
local CLOSE_MARK  = "⟧⟧"

-- apps où « remplacer tout le champ » est coché par défaut
local REPLACE_ALL_APPS = { ["WhatsApp"] = true, ["Messages"] = true, ["Slack"] = true }

hs.fs.mkdir(LOG_DIR)


local CONSIGNES = [[
Tu es l'assistant de rédaction de Pierre Lhoest (entrepreneur, fondateur d'EVS, THE FAKTORY). Il t'envoie une capture de la fenêtre où il écrit (Mail, WhatsApp, autre) et le texte du champ actif.

Ta mission :
1. Identifie ce qui est SON BROUILLON (ce qu'il est en train d'écrire) et ce qui est le CONTEXTE (message reçu, mail cité, fil de discussion).
2. Réécris son brouillon pour le rendre plus clair, plus concis (surtout s'il est long), plus professionnel et bien structuré, en restant fidèle à SON style : direct, chaleureux, sans jargon, tutoiement ou vouvoiement conservés tels qu'il les emploie. Garde la langue du brouillon. Ne change pas le fond ni les décisions ; n'invente rien.
3. Pierre est dyslexique et dicte souvent : corrige orthographe, grammaire, mots mal transcrits, sans jamais le commenter.
4. Si quelque chose n'est pas clair, manque, ou mériterait une modification plus importante (ton trop sec, promesse floue, chiffre absent, point non répondu du message reçu), dis-le dans QUESTIONS/SUGGESTIONS, en 1 à 4 puces courtes. Sinon écris « aucune ».
5. Si le brouillon a un ton professoral ou donneur de leçons, signale-le en une ligne.
6. Si Pierre te renvoie une consigne après ta proposition (plus court, plus formel, ajoute ceci, réponds à sa question…), applique-la à TA DERNIERE PROPOSITION et renvoie le texte complet corrigé, dans le même format.

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

local function htmlEscape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end


------------------------------------------------------------
-- état de la session en cours (un fil par F11)
------------------------------------------------------------

local session = {
    app        = nil,    -- nom de l'app d'origine
    title      = nil,
    draft      = nil,
    messages   = {},     -- fil API : { role, content }
    proposal   = nil,    -- dernière proposition
    replaceAll = false,
    busy       = false
}

local askClaude          -- défini plus bas
local pasteProposal      -- défini plus bas


------------------------------------------------------------
-- panneau (webview clair, à droite de l'écran principal)
------------------------------------------------------------

local panel     = nil
local escTap    = nil
local userContent = nil


local function panelClose()
    if panel then panel:delete() ; panel = nil end
    if escTap then escTap:stop() ; escTap = nil end
end


local function panelHTML(comment, questions, proposal, pending)

    local body
    if pending then
        body = '<div class="wait">⏳ ' .. htmlEscape(pending) .. '</div>'
    else
        body = '<h2>Commentaire</h2><p>' .. htmlEscape(comment) .. '</p>'
            .. '<h2>Questions / suggestions</h2><p>' .. htmlEscape(questions):gsub("\n", "<br>") .. '</p>'
            .. '<h2>Proposition</h2>'
            .. '<pre id="prop">' .. htmlEscape(proposal) .. '</pre>'
    end

    local checked = session.replaceAll and " checked" or ""

    return [[<!doctype html><html><head><meta charset="utf-8"><style>
html,body{height:100%}
body{margin:0;display:flex;flex-direction:column;font:15px/1.5 -apple-system,Helvetica,Arial,sans-serif;background:#f7f6f2;color:#1e1e1e}
.main{flex:1;overflow:auto;padding:16px 20px}
h2{font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:#8a6d1f;margin:16px 0 6px}
h2:first-child{margin-top:0}
p{margin:0;white-space:pre-wrap;color:#333}
pre{white-space:pre-wrap;font:15px/1.55 -apple-system,Helvetica,Arial,sans-serif;background:#fff;border:1px solid #d9d6cc;border-radius:10px;padding:14px;margin:0}
.wait{font-size:19px;color:#8a6d1f;padding:40px 0;text-align:center}
.bar{border-top:1px solid #d9d6cc;background:#efede6;padding:12px 16px}
textarea{width:100%;box-sizing:border-box;height:64px;resize:none;font:14px/1.4 -apple-system,Helvetica,Arial,sans-serif;border:1px solid #c9c5b8;border-radius:8px;padding:8px 10px;background:#fff}
.row{display:flex;align-items:center;gap:10px;margin-top:8px}
button{font:600 14px -apple-system,Helvetica,Arial,sans-serif;border:0;border-radius:8px;padding:9px 16px;cursor:pointer}
#send{background:#e6dcc0;color:#3b2f0a}
#paste{background:#1f6f43;color:#fff;margin-left:auto}
label{font-size:12px;color:#555;display:flex;align-items:center;gap:5px}
.hint{font-size:11px;color:#888;margin-top:6px}
button:disabled{opacity:.5;cursor:default}
</style></head><body>
<div class="main">]] .. body .. [[</div>
<div class="bar">
<textarea id="q" placeholder="Ta consigne : plus court, plus formel, ajoute…, réponds à…  (Entrée = envoyer)"></textarea>
<div class="row">
<button id="send" onclick="send()">↻ Renvoyer</button>
<label><input type="checkbox" id="all"]] .. checked .. [[> remplacer tout le champ (⌘A)</label>
<button id="paste" onclick="paste()">📋 Coller</button>
</div>
<div class="hint">Coller ou F12 → puis clique dans le champ cible · Esc = fermer</div>
</div>
<script>
function post(o){ try{ webkit.messageHandlers.assist.postMessage(o); }catch(e){} }
function send(){ var t=document.getElementById('q').value.trim(); if(!t) return;
  document.getElementById('send').disabled=true; post({cmd:'send', text:t}); }
function paste(){ post({cmd:'paste', all:document.getElementById('all').checked}); }
document.getElementById('all').addEventListener('change',function(){ post({cmd:'all', all:this.checked}); });
document.getElementById('q').addEventListener('keydown',function(e){
  if(e.key==='Enter' && !e.shiftKey){ e.preventDefault(); send(); } });
</script>
</body></html>]]
end


local function panelShow(comment, questions, proposal, pending)

    local keepFrame = panel and panel:frame() or nil
    panelClose()

    local sf = hs.screen.primaryScreen():frame()
    local w  = math.floor(sf.w * 0.34)
    local h  = math.floor(sf.h * 0.85)
    local x  = math.floor(sf.x + sf.w - w - 16)
    local y  = math.floor(sf.y + 40)
    local frame = keepFrame or { x = x, y = y, w = w, h = h }

    userContent = hs.webview.usercontent.new("assist")
    userContent:setCallback(function(m)
        local b = m and m.body or {}
        if b.cmd == "send" and b.text and b.text ~= "" then
            if session.busy then return end
            table.insert(session.messages, { role = "user", content = b.text })
            panelShow(nil, nil, nil, "Claude retouche…")
            askClaude()
        elseif b.cmd == "paste" then
            session.replaceAll = b.all and true or false
            pasteProposal()
        elseif b.cmd == "all" then
            session.replaceAll = b.all and true or false
        end
    end)

    panel = hs.webview.new(frame, { developerExtrasEnabled = false }, userContent)
    panel:windowStyle({ "utility", "titled", "closable", "resizable" })
    panel:windowTitle("Assistant — F12 ou Coller")
    panel:level(hs.drawing.windowLevels.floating)
    panel:allowTextEntry(true)
    panel:html(panelHTML(comment, questions, proposal, pending))
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
-- appel API (tout le fil de la session)
------------------------------------------------------------

local function parseReply(text)

    local proposal = text:match(OPEN_MARK .. "%s*(.-)%s*" .. CLOSE_MARK)
    local head     = text:match("^(.-)" .. OPEN_MARK) or text

    local comment   = head:match("COMMENTAIRE%s*:%s*(.-)%s*QUESTIONS") or head:match("COMMENTAIRE%s*:%s*(.-)%s*$") or head
    local questions = head:match("QUESTIONS/SUGGESTIONS%s*:%s*(.-)%s*$") or "aucune"

    return (comment:gsub("^%s+", "")), (questions:gsub("^%s+", "")), proposal
end


local function logExchange(reply)

    local f = io.open(LOG_DIR .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".md", "w")
    if not f then return end
    f:write("# " .. os.date("%Y-%m-%d %H:%M") .. " — " .. tostring(session.app) .. " — " .. tostring(session.title) .. "\n\n")
    f:write("## Brouillon\n\n" .. tostring(session.draft) .. "\n\n")
    local last = session.messages[#session.messages]
    if last and last.role == "user" and type(last.content) == "string" then
        f:write("## Consigne\n\n" .. last.content .. "\n\n")
    end
    f:write("## Réponse\n\n" .. tostring(reply) .. "\n")
    f:close()
end


askClaude = function()

    local key = apiKey()
    if not key then
        panelClose()
        alert("F11 — clé API absente : crée ~/.hammerspoon/secrets.lua", 5)
        return
    end

    local payload = {
        model      = MODEL,
        max_tokens = MAX_TOKENS,
        system     = CONSIGNES,
        messages   = session.messages
    }

    local body = hs.json.encode(payload)

    local headers = {
        ["content-type"]      = "application/json",
        ["x-api-key"]         = key,
        ["anthropic-version"] = "2023-06-01"
    }

    local t0 = hs.timer.secondsSinceEpoch()
    session.busy = true

    hs.http.asyncPost("https://api.anthropic.com/v1/messages", body, headers, function(status, resp)

        session.busy = false
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

        -- la réponse entre dans le fil pour les consignes suivantes
        table.insert(session.messages, { role = "assistant", content = text })

        local comment, questions, proposal = parseReply(text)

        if not proposal then
            proposal = text
            comment  = "(format inattendu : texte brut ci-dessous)"
        end

        session.proposal = proposal
        hs.pasteboard.setContents(proposal)
        logExchange(text)

        panelShow(comment, questions, proposal, nil)
        alert("Proposition prête (" .. dt .. ") — Coller ou F12", 2)
        log("réponse en " .. dt)
    end)
end


------------------------------------------------------------
-- F11
------------------------------------------------------------

local function assistDraft()

    if session.busy then alert("F11 — déjà en cours…", 1.5) return end

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

        -- nouvelle session
        session.app        = appName
        session.title      = title
        session.draft      = draft
        session.proposal   = nil
        session.replaceAll = REPLACE_ALL_APPS[appName] or false

        local userText =
            "Application : " .. appName .. "\nFenêtre : " .. title
            .. "\n\nTEXTE DU CHAMP ACTIF (brouillon + éventuellement contexte cité) :\n" .. draft

        local content = { { type = "text", text = userText } }
        if img then
            table.insert(content, { type = "image",
                source = { type = "base64", media_type = "image/png", data = img } })
        end

        session.messages = { { role = "user", content = content } }

        panelShow(nil, nil, nil, "Claude relit ton brouillon…")
        log("F11 : " .. appName .. " / " .. title .. " — " .. #draft .. " caractères, image " .. (img and "oui" or "non"))

        askClaude()
    end)
end


------------------------------------------------------------
-- F12 / bouton Coller : coller la proposition là où tu cliques
------------------------------------------------------------

local pasteTap, pasteTimer = nil, nil
local pasteBadge = nil

local function pasteStop()
    if pasteTap then pasteTap:stop() ; pasteTap = nil end
    if pasteTimer then pasteTimer:stop() ; pasteTimer = nil end
    if pasteBadge then pasteBadge:delete() ; pasteBadge = nil end
end


pasteProposal = function()

    if not session.proposal then alert("F12 — rien à coller : fais F11 d'abord", 2) return end

    pasteStop()

    local text       = session.proposal
    local replaceAll = session.replaceAll

    local pos = hs.mouse.absolutePosition()
    pasteBadge = hs.canvas.new({ x = pos.x + 14, y = pos.y + 14, w = 44, h = 44 })
    pasteBadge[1] = { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 10, yRadius = 10 },
        fillColor = { red = 0.12, green = 0.44, blue = 0.26, alpha = 0.92 } }
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

    alert(replaceAll and "clique dans le champ — tout le champ sera remplacé"
                      or "clique dans le champ — la sélection sera remplacée", 2)

    pasteTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseUp }, function()

        follow:stop()
        pasteStop()

        hs.timer.doAfter(0.25, function()
            local app = hs.application.frontmostApplication()
            if app and app:name() == "Hammerspoon" then
                alert("clic hors du champ — rien collé", 2)
                return
            end
            hs.pasteboard.setContents(text)
            if replaceAll then
                hs.eventtap.keyStroke({ "cmd" }, "a", 100000, app)
            end
            hs.eventtap.keyStroke({ "cmd" }, "v", 200000, app)
            panelClose()
            alert("Collé ✅", 1)
            log("collé dans " .. (app and app:name() or "?") .. (replaceAll and " (tout le champ)" or ""))
        end)

        return false
    end)

    pasteTap:start()

    pasteTimer = hs.timer.doAfter(20, function()
        follow:stop()
        pasteStop()
    end)
end


------------------------------------------------------------
-- touches
------------------------------------------------------------

-- F11 : macOS garde parfois la touche (« Afficher le bureau ») même
-- après l'avoir décochée ; on l'intercepte donc au niveau des
-- événements clavier, avant macOS, et on l'avale.
local F11_KEYCODE = 103

f11Tap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    if e:getKeyCode() ~= F11_KEYCODE then return false end
    local mods = e:getFlags()
    if mods.cmd or mods.alt or mods.ctrl or mods.shift then return false end
    hs.timer.doAfter(0, function()
        local ok, err = pcall(assistDraft)
        if not ok then log("F11 erreur : " .. tostring(err)) end
    end)
    return true
end)
f11Tap:start()

hs.hotkey.bind({}, "F12", function() pasteProposal() end)

print("[ASSIST] F11 = relire le brouillon (API " .. MODEL .. ") | F12 = coller la proposition")
