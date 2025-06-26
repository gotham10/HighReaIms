local HttpService = game:GetService("HttpService")

local function getObjectFromPath(path)
    local current = game
    for part in string.gmatch(path, "[^%.]+") do
        if part ~= "game" then
            current = current:FindFirstChild(part)
            if not current then return nil end
        end
    end
    return current
end

local function generateGameDataContext()
    local context = {}
    local localPlayer = game:GetService("Players").LocalPlayer
    local leaderstats = localPlayer and localPlayer:FindFirstChild("leaderstats")
    if leaderstats then
        for _, stat in ipairs(leaderstats:GetChildren()) do
            if stat:IsA("ValueBase") then
                table.insert(context, "LEADERSTAT: " .. stat:GetFullName() .. " | VALUE: " .. tostring(stat.Value))
            end
        end
    end

    local function dumpTable(tbl, path, visited)
        visited = visited or {}
        if visited[tbl] or not tbl or not (type(tbl) == "table") then return end
        visited[tbl] = true
        for k, v in pairs(tbl) do
            local currentPath = path .. "." .. tostring(k)
            local valueType = type(v)
            if valueType ~= "function" and valueType ~= "userdata" then
                table.insert(context, "MODULE: " .. currentPath .. " | VALUE: " .. tostring(v))
                if valueType == "table" then
                    dumpTable(v, currentPath, visited)
                end
            end
        end
    end

    for _, descendant in ipairs(game:GetDescendants()) do
        if descendant:IsA("RemoteFunction") then
            table.insert(context, "REMOTE: " .. descendant:GetFullName())
        elseif descendant:IsA("ModuleScript") then
            local ok, mod = pcall(require, descendant)
            if ok and type(mod) == "table" then
                dumpTable(mod, descendant:GetFullName(), {})
            end
        end
    end
    return context
end

local function intelligentAnalysis(userQuery, gameDataContext)
    local queryWords = {}
    for word in string.gmatch(string.lower(userQuery), "%w+") do
        queryWords[word] = true
    end

    local bestPlan = { score = 0 }

    for _, line in ipairs(gameDataContext) do
        local lowerLine = string.lower(line)
        local currentScore = 0
        for word, _ in pairs(queryWords) do
            if string.find(lowerLine, word) then
                currentScore = currentScore + 1
            end
        end

        if currentScore > bestPlan.score then
            bestPlan.score = currentScore
            bestPlan.line = line
        end
    end

    if not bestPlan.line then return nil end

    local lineType, path = bestPlan.line:match("^(%w+): (.-) |")
    path = path and path:match("^%s*(.-)%s*$")
    
    if not lineType or not path then return nil end
    
    local finalPlan = { path = path }

    if lineType == "LEADERSTAT" or lineType == "MODULE" then
        finalPlan.action = "READ_VALUE"
        finalPlan.value = bestPlan.line:match("| VALUE: (.*)$")
    elseif lineType == "REMOTE" then
        finalPlan.action = "INVOKE_REMOTE"
        local searchKey
        for word, _ in pairs(queryWords) do
            if not ({["how"]=true, ["many"]=true, ["get"]=true, ["my"]=true, ["what"]=true, ["is"]=true, ["inventory"]=true})[word] then
                searchKey = word
                break
            end
        end
        finalPlan.searchKey = searchKey
    end
    
    return finalPlan
end

local function invokeRemote(remoteFunc)
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
        return false, "Function timed out"
    end
    return success, result
end

local function processQuery(userQuery)
    print("AI is analyzing game context...")
    local context = generateGameDataContext()
    local plan = intelligentAnalysis(userQuery, context)
    local finalReport

    if not plan then
        finalReport = "I am unsure. After analyzing the game, I could not form a plan to answer your question."
    else
        if plan.action == "READ_VALUE" then
            finalReport = "The AI has concluded the answer is: '" .. plan.value .. "'. This was found at: " .. plan.path
        elseif plan.action == "INVOKE_REMOTE" then
            local remoteObject = getObjectFromPath(plan.path)
            if remoteObject then
                local success, data = invokeRemote(remoteObject)
                if success then
                    if type(data) == "table" and plan.searchKey then
                        local foundValue = nil
                        for k, v in pairs(data) do
                            if type(k) == "string" and string.lower(k) == plan.searchKey then
                                foundValue = v
                                break
                            end
                        end
                        if foundValue then
                             finalReport = "The AI has concluded the answer is: '" .. tostring(foundValue) .. "'. This was found by invoking '" .. plan.path .. "' and searching for '"..plan.searchKey.."'."
                        else
                             finalReport = "I invoked '" .. plan.path .. "' and it returned a table, but I could not find the value for '" .. plan.searchKey .. "' inside it."
                        end
                    else
                        finalReport = "The AI has concluded the answer is: " .. HttpService:JSONEncode(data) .. ". This was found by invoking the RemoteFunction at: " .. plan.path
                    end
                else
                    finalReport = "I tried to invoke '" .. plan.path .. "' but it failed. Reason: " .. tostring(data)
                end
            else
                finalReport = "I planned to invoke '" .. plan.path .. "', but it could not be found in the game."
            end
        end
    end
    
    if not finalReport then
        finalReport = "I am unsure. I formed a plan but could not execute it to find a definitive answer."
    end
    
    print(finalReport)
end

return processQuery
