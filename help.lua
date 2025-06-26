local HttpService = game:GetService("HttpService")

local AI = {}

function AI:getObjectFromPath(path)
    local current = game
    for part in string.gmatch(path, "[^%.]+") do
        if part ~= "game" then
            current = current:FindFirstChild(part, true) -- Use recursive FindFirstChild
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
    }
    
    local function processDescendants(root)
        for _, descendant in ipairs(root:GetDescendants()) do
            if AI:isGameSpecificObject(descendant) then
                pcall(function()
                    if descendant:IsA("RemoteFunction") then
                        table.insert(context.remotes, { path = descendant:GetFullName() })
                    elseif descendant:IsA("ValueBase") then
                         local isLeaderstat = false
                         if descendant.Parent and descendant.Parent.Name == "leaderstats" and descendant.Parent.Parent:IsA("Player") then
                             isLeaderstat = true
                         end
                         table.insert(context.values, { path = descendant:GetFullName(), source = isLeaderstat and "leaderstat" or "valueobject" })
                    end
                end)
            end
        end
    end

    for _, service in ipairs(servicesToScan) do
        processDescendants(service)
    end
    
    return context
end

function AI:createExecutionPlan(userQuery, gameContext)
    local stopWords = {
        ["a"]=true,["an"]=true,["the"]=true,["is"]=true,["are"]=true,["was"]=true,["were"]=true,
        ["how"]=true,["many"]=true,["what"]=true,["where"]=true,["when"]=true,["who"]=true,
        ["get"]=true,["find"]=true,["do"]=true,["does"]=true,["did"]=true,["i"]=true,["me"]=true,
        ["my"]=true,["mine"]=true,["in"]=true,["on"]=true,["of"]=true, ["have"]=true, ["much"]=true, ["show"]=true
    }
    local queryKeywords = {}
    for word in string.gmatch(string.lower(userQuery), "%w+") do
        if not stopWords[word] then
            table.insert(queryKeywords, word)
        end
    end

    if #queryKeywords == 0 then return nil end

    local bestPlan = { score = -1, steps = {}, keywords = queryKeywords }

    local function scorePath(path, keywords)
        local score = 0
        local lowerPath = string.lower(path)
        for _, word in ipairs(keywords) do
            if string.find(lowerPath, word) then
                score = score + 1
            end
        end
        return score
    end

    for _, val in ipairs(gameContext.values) do
        local currentScore = scorePath(val.path, queryKeywords) * 2
        if val.source == "leaderstat" then currentScore = currentScore * 1.5 end
        
        if currentScore > bestPlan.score then
            bestPlan.score = currentScore
            bestPlan.steps = {{ action = "READ_VALUE", target = val.path }}
        end
    end

    for _, remote in ipairs(gameContext.remotes) do
        local currentScore = scorePath(remote.path, queryKeywords) * 3 -- Remotes are highly valued
        if string.find(string.lower(remote.path), "inventory") or string.find(string.lower(remote.path), "data") then
             currentScore = currentScore * 2 -- Especially valuable remotes
        end

        if currentScore > bestPlan.score then
            bestPlan.score = currentScore
            bestPlan.steps = {{ action = "INVOKE_REMOTE", target = remote.path }, { action = "DEEP_ANALYZE_RESULT" }}
        end
    end

    if bestPlan.score > 0 then
        return bestPlan
    else
        return nil
    end
end

function AI:invokeRemote(remoteFunc)
    if not remoteFunc or not remoteFunc:IsA("RemoteFunction") then return false, "RemoteFunction not found or invalid" end
    local success, result = pcall(remoteFunc.InvokeServer, remoteFunc)
    if not success then
        return false, result -- Pass the error message
    end
    return true, result
end

function AI:deepAnalyzeResult(data, keywords)
    local bestMatch = {score = -1, value = nil}

    local function searchTable(currentTable, path)
        if type(currentTable) ~= "table" then return end

        for key, value in pairs(currentTable) do
            local newPath = path .. "." .. string.lower(tostring(key))
            local currentScore = 0
            
            for _, keyword in ipairs(keywords) do
                if string.find(newPath, keyword) then
                    currentScore = currentScore + 1
                end
            end
            
            if type(value) ~= "table" and type(value) ~= "function" then
                if currentScore > bestMatch.score then
                    bestMatch.score = currentScore
                    bestMatch.value = value
                end
            else
                searchTable(value, newPath)
            end
        end
    end

    searchTable(data, "")
    
    if bestMatch.score > 0 then
        return bestMatch.value
    end

    return nil
end


function AI:executePlan(plan)
    local results = { success = true, finalAnswer = nil }
    local lastData = nil

    for _, step in ipairs(plan.steps) do
        if not results.success then break end

        if step.action == "READ_VALUE" then
            local object = AI:getObjectFromPath(step.target)
            if object and object:IsA("ValueBase") then
                lastData = object.Value
            else
                results.success = false
            end
        elseif step.action == "INVOKE_REMOTE" then
            local remoteObject = AI:getObjectFromPath(step.target)
            if remoteObject then
                local success, data = AI:invokeRemote(remoteObject)
                if success then
                    lastData = data
                else
                    results.success = false
                end
            else
                results.success = false
            end
        elseif step.action == "DEEP_ANALYZE_RESULT" then
            if type(lastData) == "table" then
                 local foundValue = AI:deepAnalyzeResult(lastData, plan.keywords)
                 if foundValue ~= nil then
                     lastData = foundValue
                 else
                     -- If deep analysis fails, maybe the raw data is the answer
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
