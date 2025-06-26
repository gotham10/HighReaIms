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
        ["CoreGui"] = true,
        ["CorePackages"] = true,
        ["RobloxPluginGuiService"] = true,
        ["PluginGuiService"] = true,
        ["TestService"] = true,
        ["Chat"] = true,
        ["LocalizationService"] = true,
        ["VoiceChatService"] = true,
        ["AnalyticsService"] = true,
    }

    local ancestor = object
    while ancestor do
        if servicesToIgnore[ancestor.Name] then
            return false
        end
        ancestor = ancestor.Parent
    end

    if object:IsA("Script") or object:IsA("LocalScript") then
        if not object.Enabled then return false end
    end

    return true
end

function AI:scanGame()
    local context = {
        remotes = {},
        modules = {},
        values = {},
    }
    local servicesToScan = {
        game:GetService("Workspace"),
        game:GetService("ReplicatedStorage"),
        game:GetService("ReplicatedFirst"),
        game:GetService("Players"),
        game:GetService("StarterGui"),
        game:GetService("StarterPlayer"),
        game:GetService("ServerScriptService"),
        game:GetService("ServerStorage"),
    }
    
    local visitedModules = {}

    local function dumpTable(tbl, path)
        if visitedModules[tbl] or not (type(tbl) == "table") then return end
        visitedModules[tbl] = true
        for k, v in pairs(tbl) do
            local currentPath = path .. "." .. tostring(k)
            local valueType = type(v)
            if valueType ~= "function" and valueType ~= "userdata" and valueType ~= "table" then
                 table.insert(context.modules, {
                    path = currentPath,
                    value = tostring(v),
                    key = tostring(k)
                })
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
                    table.insert(context.values, {
                        path = stat:GetFullName(),
                        value = stat.Value,
                        object = stat,
                        source = "leaderstat"
                    })
                end
            end
        end
    end

    for _, service in ipairs(servicesToScan) do
        for _, descendant in ipairs(service:GetDescendants()) do
            if AI:isGameSpecificObject(descendant) then
                local success, _ = pcall(function()
                    if descendant:IsA("RemoteFunction") then
                        table.insert(context.remotes, {
                            path = descendant:GetFullName(),
                            object = descendant
                        })
                    elseif descendant:IsA("ModuleScript") then
                        local ok, mod = pcall(require, descendant)
                        if ok and type(mod) == "table" then
                           dumpTable(mod, descendant:GetFullName())
                        end
                    elseif descendant:IsA("ValueBase") and not descendant.Parent:IsA("Player") and not descendant.Parent.Name == "leaderstats" then
                         table.insert(context.values, {
                            path = descendant:GetFullName(),
                            value = descendant.Value,
                            object = descendant,
                            source = "valueobject"
                        })
                    end
                end)
            end
        end
    end
    
    return context
end

function AI:createExecutionPlan(userQuery, gameContext)
    local queryWords = {}
    for word in string.gmatch(string.lower(userQuery), "%a+") do
        queryWords[word] = true
    end

    local bestPlan = { score = 0, steps = {}, reasoning = "" }

    local function scorePath(path)
        local score = 0
        local lowerPath = string.lower(path)
        for word in pairs(queryWords) do
            if string.find(lowerPath, word) then
                score = score + 1
            end
        end
        return score
    end
    
    for _, val in ipairs(gameContext.values) do
        local currentScore = scorePath(val.path) * 2 
        if val.source == "leaderstat" then currentScore = currentScore * 1.5 end
        if currentScore > bestPlan.score then
            bestPlan.score = currentScore
            bestPlan.reasoning = "User query keywords matched a value object in the game at '" .. val.path .. "'."
            bestPlan.steps = {{
                action = "READ_VALUE",
                target = val.path,
                description = "Reading the value of object '" .. val.path .. "'."
            }}
        end
    end

    for _, remote in ipairs(gameContext.remotes) do
        local currentScore = scorePath(remote.path)
        if currentScore > bestPlan.score then
            bestPlan.score = currentScore
            bestPlan.reasoning = "User query keywords matched a RemoteFunction at '" .. remote.path .. "'."
            bestPlan.steps = {{
                action = "INVOKE_REMOTE",
                target = remote.path,
                description = "Invoking remote function '" .. remote.path .. "'."
            }, {
                action = "ANALYZE_RESULT",
                description = "Analyzing the returned data for relevant information."
            }}
        end
    end
    
    for _, mod_val in ipairs(gameContext.modules) do
        local currentScore = scorePath(mod_val.key)
        if currentScore > bestPlan.score then
             bestPlan.score = currentScore
             bestPlan.reasoning = "User query keywords matched a key in a ModuleScript at '" .. mod_val.path .. "'."
             bestPlan.steps = {{
                 action = "READ_MODULE_VALUE",
                 target = mod_val.path,
                 value = mod_val.value,
                 description = "Reading module value from '" .. mod_val.path .. "'."
             }}
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
    local results = { success = true, finalAnswer = nil, report = "" }
    local lastData = nil

    for i, step in ipairs(plan.steps) do
        if step.action == "READ_VALUE" then
            local object = AI:getObjectFromPath(step.target)
            if object and object:IsA("ValueBase") then
                lastData = object.Value
                results.report = "Successfully read value from '"..step.target.."'. Value is: "..tostring(lastData)
            else
                results.success = false
                results.report = "Failed to find or read value object at '"..step.target.."'."
                break
            end
        elseif step.action == "READ_MODULE_VALUE" then
            lastData = step.value
            results.report = "Successfully read value '" .. tostring(lastData) .. "' from module path '" .. step.target .. "'."
        elseif step.action == "INVOKE_REMOTE" then
            local remoteObject = AI:getObjectFromPath(step.target)
            if remoteObject then
                local success, data = AI:invokeRemote(remoteObject)
                if success then
                    lastData = data
                    results.report = "Successfully invoked '"..step.target.."'."
                else
                    results.success = false
                    results.report = "Failed to invoke '"..step.target.."'. Reason: "..tostring(data)
                    break
                end
            else
                results.success = false
                results.report = "Could not find RemoteFunction at path '"..step.target.."'."
                break
            end
        elseif step.action == "ANALYZE_RESULT" then
             if type(lastData) == "table" then
                local foundValue = nil
                local searchKey
                for word in string.gmatch(string.lower(plan.reasoning), "%a+") do
                     if not ({["how"]=true, ["many"]=true, ["get"]=true, ["my"]=true, ["what"]=true, ["is"]=true, ["inventory"]=true})[word] then
                        searchKey = word
                        break
                     end
                end
                
                if searchKey then
                     for k, v in pairs(lastData) do
                         if string.lower(tostring(k)) == searchKey then
                             foundValue = v
                             break
                         end
                     end
                end

                if foundValue then
                    lastData = foundValue
                    results.report = results.report .. " Found specific value '" .. tostring(lastData) .. "' for key '" .. searchKey .. "' in the result."
                else
                    results.report = results.report .. " Returning the full table result as no specific key was found."
                    lastData = HttpService:JSONEncode(lastData)
                end
            else
                results.report = results.report .. " The result was a single value: " .. tostring(lastData)
            end
        end
    end

    if results.success then
        results.finalAnswer = lastData
    end

    return results
end

function AI:generateFinalReport(query, plan, executionResults)
    print("--- AI Analysis Report ---")
    print("Query: \"" .. query .. "\"")

    if not plan then
        print("Conclusion: I am unsure. After analyzing the game, I could not form a plan to answer your question.")
        return
    end

    print("\nPlan:")
    print("  Reasoning: " .. plan.reasoning)
    for i, step in ipairs(plan.steps) do
        print("  Step "..i..": "..step.action.." -> "..step.description)
    end

    print("\nExecution Log:")
    print("  " .. executionResults.report)

    print("\nConclusion:")
    if executionResults.success then
        print("  The answer is: " .. tostring(executionResults.finalAnswer))
    else
        print("  I was unable to find the answer. The final step failed.")
    end
    print("--------------------------")
end

local function processQuery(userQuery)
    print("AI is analyzing game context...")
    local context = AI:scanGame()
    
    print("AI is forming an execution plan...")
    local plan = AI:createExecutionPlan(userQuery, context)
    
    local finalReport
    if plan then
        print("AI is executing the plan...")
        local executionResults = AI:executePlan(plan)
        finalReport = AI:generateFinalReport(userQuery, plan, executionResults)
    else
        finalReport = AI:generateFinalReport(userQuery, nil, nil)
    end
end

return processQuery
