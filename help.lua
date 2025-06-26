local HttpService = game:GetService("HttpService")

local function extractKeyword(prompt)
    local stopWords = {
        ["how"] = true, ["many"] = true, ["what"] = true, ["is"] = true,
        ["my"] = true, ["the"] = true, ["do"] = true, ["i"] = true,
        ["have"] = true, ["a"] = true, ["get"] = true, ["can"] = true,
        ["current"] = true, ["value"] = true, ["of"] = true
    }
    local bestKeyword = nil
    local words = {}
    for word in string.gmatch(string.lower(prompt), "%w+") do
        table.insert(words, word)
    end
    for i = #words, 1, -1 do
        if not stopWords[words[i]] then
            bestKeyword = words[i]
            break
        end
    end
    return bestKeyword
end

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

local function findData(keyword)
    local findings = { Labels = {}, Modules = {}, Remotes = {} }
    if not keyword or type(keyword) ~= "string" or keyword == "" then return findings end

    local function searchTable(tbl, path, visited)
        visited = visited or {}
        if visited[tbl] or not tbl then return end
        visited[tbl] = true
        for k, v in pairs(tbl) do
            local currentPath = path .. "." .. tostring(k)
            if type(k) == "string" and string.find(string.lower(k), keyword) then
                table.insert(findings.Modules, { Path = currentPath, Value = tostring(v) })
            end
            if type(v) == "table" then
                searchTable(v, currentPath, visited)
            end
        end
    end

    for _, descendant in ipairs(game:GetDescendants()) do
        local success, name = pcall(function() return descendant.Name end)
        if success and type(name) == "string" and string.find(string.lower(name), keyword) then
            if descendant:IsA("TextLabel") or descendant:IsA("TextButton") or descendant:IsA("TextBox") then
                table.insert(findings.Labels, { Path = descendant:GetFullName(), Text = descendant.Text or "" })
            elseif descendant:IsA("RemoteFunction") then
                table.insert(findings.Remotes, { Path = descendant:GetFullName() })
            elseif descendant:IsA("ModuleScript") then
                local ok, mod = pcall(require, descendant)
                if ok and type(mod) == "table" then
                    searchTable(mod, descendant:GetFullName())
                end
            end
        end
    end

    return findings
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
    local keyword = extractKeyword(userQuery)
    if not keyword then
        print("Could not determine a keyword from your request.")
        return
    end

    local results = findData(keyword)
    local finalAnswer = nil

    for _, labelInfo in ipairs(results.Labels) do
        if labelInfo.Text and string.match(labelInfo.Text, "%d") then
            finalAnswer = "The AI has concluded the answer is: '" .. labelInfo.Text .. "'. This was found in a GUI element at: " .. labelInfo.Path
            break
        end
    end
    if not finalAnswer and #results.Modules > 0 then
         for _, modInfo in ipairs(results.Modules) do
            if modInfo.Value and string.match(modInfo.Value, "%d") then
                finalAnswer = "The AI has concluded the answer is: '" .. modInfo.Value .. "'. This was found in a ModuleScript value at: " .. modInfo.Path
                break
            end
        end
    end
    if not finalAnswer and #results.Remotes > 0 then
        local remoteFailures = {}
        for _, remoteInfo in ipairs(results.Remotes) do
            local remoteObject = getObjectFromPath(remoteInfo.Path)
            if remoteObject then
                local success, data = invokeRemote(remoteObject)
                if success then
                    local dataString = type(data) == "table" and HttpService:JSONEncode(data) or tostring(data)
                    finalAnswer = "The AI has concluded the answer is: " .. dataString .. ". This was found by invoking the RemoteFunction at: " .. remoteInfo.Path
                    break
                else
                    table.insert(remoteFailures, "  - "..remoteInfo.Path..": "..tostring(data))
                end
            end
        end
        if not finalAnswer and #remoteFailures > 0 then
            finalAnswer = "I am unsure. I attempted to invoke the following RemoteFunctions, but they failed:\n" .. table.concat(remoteFailures, "\n")
        end
    end
    local finalReport
    if finalAnswer then
        finalReport = finalAnswer
    else
        finalReport = "I am unsure. After a full scan for '"..keyword.."', I could not find a definitive answer in any GUI elements, modules, or remotes."
    end
    print(finalReport)
end
return processQuery
