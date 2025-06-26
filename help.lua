local HttpService = game:GetService("HttpService")

local AI = {}

function AI:getObjectFromPath(path)
    local current = game
    for part in string.gmatch(path, "[^%.]+") do
        if part ~= "game" then
            current = current:FindFirstChild(part)
            if not current then return nil end
        end
    end
    return current
end

function AI:isGameSpecificObject(object)
    local servicesToIgnore = {
        ["CoreGui"] = true, ["CorePackages"] = true, ["RobloxPluginGuiService"] = true,
        ["PluginGuiService"] = true, ["TestService"] = true, ["Chat"] = true,
        ["LocalizationService"] = true, ["VoiceChatService"] = true, ["AnalyticsService"] = true,
    }
    local ancestor = object
    while ancestor do
        if servicesToIgnore[ancestor.Name] then return false end
        ancestor = ancestor.Parent
    end
    if object:IsA("Script") or object:IsA("LocalScript") then
        if not object.Enabled then return false end
    end
    return true
end

function AI:scanGame()
    local context = { remotes = {}, modules = {}, values = {} }
    local servicesToScan = {
        game:GetService("Workspace"), game:GetService("ReplicatedStorage"),
        game:GetService("ReplicatedFirst"), game:GetService("Players"),
        game:GetService("StarterGui"), game:GetService("StarterPlayer"),
        game:GetService("ServerScriptService"), game:GetService("ServerStorage"),
    }
    local visitedModules = {}

    local function dumpTable(tbl, path)
        if visitedModules[tbl] or not (type(tbl) == "table") then return end
        visitedModules[tbl] = true
        for k, v in pairs(tbl) do
            local currentPath = path .. "." .. tostring(k)
            local valueType = type(v)
            if valueType ~= "function" and valueType ~= "userdata" and valueType ~= "table" then
                table.insert(context.modules, { path = currentPath, value = tostring(v), key = tostring(k) })
            elseif valueType == "table" then
                dumpTable(v, currentPath)
            end
        end
    end

    local localPlayer = game:GetService("Players").LocalPlayer
    if localPlayer then
        local leaderstats = localPlayer:FindFirstChild("leaderstats")
        if leaderstats then
            for _, stat in ipairs(leaderstats:GetChildren()) do
                if stat:IsA("ValueBase") and AI:isGameSpecificObject(stat) then
                    table.insert(context.values, { path = stat:GetFullName(), value = stat.Value, object = stat, source = "leaderstat" })
                end
            end
        end
    end

    for _, service in ipairs(servicesToScan) do
        for _, descendant in ipairs(service:GetDescendants()) do
            if AI:isGameSpecificObject(descendant) then
                pcall(function()
                    if descendant:IsA("RemoteFunction") then
                        table.insert(context.remotes, { path = descendant:GetFullName(), object = descendant })
                    elseif descendant:IsA("ModuleScript") then
                        local ok, mod = pcall(require, descendant)
                        if ok and type(mod) == "table" then
                            dumpTable(mod, descendant:GetFullName())
                        end
                    elseif descendant:IsA("ValueBase") and not descendant.Parent:IsA("Player") and not (descendant.Parent and descendant.Parent.Name == "leaderstats") then
                        table.insert(context.values, { path = descendant:GetFullName(), value = descendant.Value, object = descendant, source = "valueobject" })
                    end
                end)
            end
        end
    end
    return context
end

function AI:createExecutionPlan(userQuery, gameContext)
    local stopWords = {
        ["a"]=true,["an"]=true,["the"]=true,["is"]=true,["are"]=true,["was"]=true,["were"]=true,
        ["how"]=true,["many"]=true,["what"]=true,["where"]=true,["when"]=true,["who"]=true,
        ["get"]=true,["find"]=true,["do"]=true,["does"]=true,["did"]=true,["i"]=true,["me"]=true,
        ["my"]=true,["mine"]=true,["in"]=true,["on"]=true,["of"]=true, ["have"]=true, ["much"]=true,
    }
    local queryKeywords = {}
    for word in string.gmatch(string.lower(userQuery), "%w+") do
        if not stopWords[word] then
            table.insert(queryKeywords, word)
        end
    end

    if #queryKeywords == 0 then return nil end

    local bestPlan = { score = 0, steps = {}, keywords = queryKeywords }

    local function scorePath(path)
        local score = 0
        local lowerPath = string.lower(path)
        local matches = 0
        for _, word in ipairs(queryKeywords) do
            if string.find(lowerPath, word) then
                matches = matches + 1
            end
        end
        if matches > 0 then
            score = matches ^ 2 
        end
        return score
    end

    for _, val in ipairs(gameContext.values) do
        local currentScore = scorePath(val.path) * 2
        if val.source == "leaderstat" then currentScore = currentScore * 1.5 end
        if currentScore > bestPlan.score then
            bestPlan.score = currentScore
            bestPlan.steps = {{ action = "READ_VALUE", target = val.path }}
        end
    end

    for _, remote in ipairs(gameContext.remotes) do
        local currentScore = scorePath(remote.path)
        if currentScore > bestPlan.score then
            bestPlan.score = currentScore
            bestPlan.steps = {{ action = "INVOKE_REMOTE", target = remote.path }, { action = "ANALYZE_RESULT" }}
        end
    end

    for _, mod_val in ipairs(gameContext.modules) do
        local currentScore = scorePath(mod_val.path) * 0.5 
        if currentScore > bestPlan.score then
            bestPlan.score = currentScore
            bestPlan.steps = {{ action = "READ_MODULE_VALUE", target = mod_val.path, value = mod_val.value }}
        end
    end

    if bestPlan.score > 0 then
        return bestPlan
    else
        return nil
    end
end

function AI:invokeRemote(remoteFunc)
    if not remoteFunc then return false, "RemoteFunction not found" end
    local done, success, result = false, false, nil
    local thread = coroutine.create(function()
        success, result = pcall(remoteFunc.InvokeServer, remoteFunc)
        done = true
    end)
    coroutine.resume(thread)
    local start = tick()
    while not done and tick() - start < 5 do
        task.wait()
    end
    if not done then
        coroutine.close(thread)
        return false, "Function timed out"
    end
    return success, result
end

function AI:executePlan(plan)
    local results = { success = true, finalAnswer = nil }
    local lastData = nil

    for _, step in ipairs(plan.steps) do
        if step.action == "READ_VALUE" then
            local object = AI:getObjectFromPath(step.target)
            if object and object:IsA("ValueBase") then
                lastData = object.Value
            else
                results.success = false; break
            end
        elseif step.action == "READ_MODULE_VALUE" then
            lastData = step.value
        elseif step.action == "INVOKE_REMOTE" then
            local remoteObject = AI:getObjectFromPath(step.target)
            if remoteObject then
                local success, data = AI:invokeRemote(remoteObject)
                if success then
                    lastData = data
                else
                    results.success = false; break
                end
            else
                results.success = false; break
            end
        elseif step.action == "ANALYZE_RESULT" then
            if type(lastData) == "table" then
                local bestMatch = { score = 0, value = nil }
                for k, v in pairs(lastData) do
                    local keyStr = string.lower(tostring(k))
                    local currentScore = 0
                    for _, keyword in ipairs(plan.keywords) do
                        if string.find(keyStr, keyword) then
                            currentScore = currentScore + 1
                        end
                    end
                    if currentScore > bestMatch.score then
                        bestMatch.score = currentScore
                        bestMatch.value = v
                    end
                end
                if bestMatch.score > 0 then
                    lastData = bestMatch.value
                else
                    lastData = HttpService:JSONEncode(lastData) 
                end
            end
        end
    end

    if results.success then
        results.finalAnswer = lastData
    end

    return results
end

local function processQuery(userQuery)
    local context = AI:scanGame()
    local plan = AI:createExecutionPlan(userQuery, context)
    
    if plan then
        local executionResults = AI:executePlan(plan)
        if executionResults.success and executionResults.finalAnswer ~= nil then
            setclipboard(tostring(executionResults.finalAnswer))
        else
            setclipboard("I was unable to find the answer.")
        end
    else
        setclipboard("I am unsure how to answer that.")
    end
end

return processQuery
