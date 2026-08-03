local Store = {}
Store.__index = Store

local function combine(fsApi, root, name)
    return fsApi.combine(root, name .. ".lua")
end


function Store.new(fsApi, codec, root)
    assert(type(fsApi) == "table", "fs API is required")
    assert(type(codec) == "table", "codec is required")
    assert(type(root) == "string" and root ~= "", "store root is required")
    return setmetatable({ fs = fsApi, codec = codec, root = root }, Store)
end

function Store:at(root)
    return Store.new(self.fs, self.codec, root)
end

function Store:_readPath(path, validator)
    local opened, handle = pcall(self.fs.open, path, "r")
    if not opened then return nil, "open " .. path .. ": " .. tostring(handle) end
    if not handle then return nil, "missing " .. path end
    local ok, encoded = pcall(handle.readAll)
    local closeOk, closeReason = pcall(handle.close)
    if not ok then return nil, "read " .. path .. ": " .. tostring(encoded) end
    if not closeOk then return nil, "close " .. path .. ": " .. tostring(closeReason) end

    local decodedOk, value = pcall(self.codec.decode, encoded)
    if not decodedOk then return nil, "decode " .. path .. ": " .. tostring(value) end
    local validateOk, valid, reason = pcall(validator, value)
    if not validateOk then return nil, "validate " .. path .. ": " .. tostring(valid) end
    if not valid then return nil, "invalid " .. path .. ": " .. tostring(reason) end
    return value
end

function Store:read(name, validator)
    return self:_readPath(combine(self.fs, self.root, name), validator)
end

function Store:recover(name, validator)
    local active = combine(self.fs, self.root, name)
    local previous = combine(self.fs, self.root, name .. ".previous")
    local value = self:_readPath(active, validator)
    if value ~= nil then return value end
    local recovered = self:_readPath(previous, validator)
    if recovered ~= nil then return recovered, "recovered previous " .. name end
    if name == "journal" then return nil, "unsafe journal unavailable" end
    return nil, "no valid " .. name .. " available"
end

function Store:_writeStaged(path, encoded)
    local opened, handle = pcall(self.fs.open, path, "w")
    if not opened then return nil, "open staged file: " .. tostring(handle) end
    if not handle then return nil, "could not open staged file" end
    local writeOk, writeReason = pcall(handle.write, encoded)
    local closeOk, closeReason = pcall(handle.close)
    if not writeOk then return nil, "write staged file: " .. tostring(writeReason) end
    if not closeOk then return nil, "close staged file: " .. tostring(closeReason) end
    return true
end

function Store:write(name, value, validator)
    local validateOk, valid, reason = pcall(validator, value)
    if not validateOk then return nil, "validate " .. name .. ": " .. tostring(valid) end
    if not valid then return nil, "refusing invalid " .. name .. ": " .. tostring(reason) end

    local encodedOk, encoded = pcall(self.codec.encode, value)
    if not encodedOk then return nil, "encode " .. name .. ": " .. tostring(encoded) end

    local directoryOk, directoryReason = pcall(self.fs.makeDir, self.root)
    if not directoryOk then
        return nil, "create store directory: " .. tostring(directoryReason)
    end
    local active = combine(self.fs, self.root, name)
    local staged = combine(self.fs, self.root, name .. ".staged")
    local previous = combine(self.fs, self.root, name .. ".previous")
    if self.fs.exists(staged) then self.fs.delete(staged) end

    local wrote, writeReason = self:_writeStaged(staged, encoded)
    if not wrote then return nil, writeReason end
    local stagedValue, stagedReason = self:_readPath(staged, validator)
    if not stagedValue then
        self.fs.delete(staged)
        return nil, "verify staged " .. name .. ": " .. tostring(stagedReason)
    end

    if self.fs.exists(previous) then self.fs.delete(previous) end
    if self.fs.exists(active) then
        local rotated, rotateReason = pcall(self.fs.move, active, previous)
        if not rotated then
            self.fs.delete(staged)
            return nil, "preserve " .. name .. ": " .. tostring(rotateReason)
        end
    end

    local activated, activateReason = pcall(self.fs.move, staged, active)
    if not activated then return nil, "activate " .. name .. ": " .. tostring(activateReason) end
    return true
end

return Store
