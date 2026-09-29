-- probe-kit: paste this block at the TOP of every probe. It records everything the probe sees and
-- ends by printing one clipboard-ready block (and copying it, and saving it under workspace/).
-- Usage:  P.begin("name", "what is tested")   P.log(...)   P.call(remote, ...)   P.watch(remote)   P.finish()
local P = { rows = {}, t0 = os.clock(), cons = {} }
local function ser(v, depth)
	depth = depth or 0
	local t = typeof(v)
	if t == "string" then return ("%q"):format(v) end
	if t == "Instance" then return "<" .. v.ClassName .. " " .. v:GetFullName() .. ">" end
	if t == "table" then
		if depth > 3 then return "{...}" end
		local out, n = {}, 0
		for k, x in pairs(v) do
			n += 1
			if n > 40 then out[#out + 1] = "..."; break end
			out[#out + 1] = "[" .. ser(k, depth + 1) .. "]=" .. ser(x, depth + 1)
		end
		return "{" .. table.concat(out, ", ") .. "}"
	end
	return tostring(v)
end
P.ser = ser
function P.log(...)
	local parts = table.pack(...)
	for i = 1, parts.n do parts[i] = ser(parts[i]) end
	P.rows[#P.rows + 1] = ("%6.2fs  %s"):format(os.clock() - P.t0, table.concat(parts, "  "))
end
-- One paste can carry several probes: begin() closes the previous block (prints it, drops its
-- watchers) and opens the next. finish() closes the last one and copies ALL blocks together.
P.blocks = {}
local function closeBlock()
	if not P.name then return end
	for _, c in ipairs(P.cons) do c:Disconnect() end
	P.cons = {}
	local n = #P.blocks + 1
	local text = ("========== PROBE %d ==========\n%s\n%s\n\n%s\n\n========== END PROBE %d =========="):format(
		n, tostring(P.name), tostring(P.what), table.concat(P.rows, "\n"), n)
	P.blocks[n] = text
	print(text)
	P.name, P.rows = nil, {}
end
function P.begin(name, what) closeBlock(); P.name, P.what, P.t0 = name, what, os.clock(); P.log("start") end
-- InvokeServer with a timeout; logs every argument and every return value.
function P.call(remote, ...)
	local args, done, out = table.pack(...), false, nil
	P.log("INVOKE", remote:GetFullName(), table.unpack(args, 1, args.n))
	task.spawn(function() out = table.pack(pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n))); done = true end)
	local dl = os.clock() + 8
	while not done and os.clock() < dl do task.wait() end
	if not done then P.log("  -> NO REPLY 8s"); return nil end
	P.log("  -> ok=" .. tostring(out[1]), table.unpack(out, 2, out.n))
	return out
end
function P.fire(remote, ...) P.log("FIRE", remote:GetFullName(), ...); return pcall(remote.FireServer, remote, ...) end
-- Records every payload the server sends on a RemoteEvent until finish().
function P.watch(remote)
	P.cons[#P.cons + 1] = remote.OnClientEvent:Connect(function(...) P.log("RECV", remote.Name, ...) end)
end
-- Records every change of a leaderstat / attribute so a probe shows what the server did to you.
function P.track(inst, attr)
	local sig = attr and inst:GetAttributeChangedSignal(attr) or inst:GetPropertyChangedSignal("Value")
	P.cons[#P.cons + 1] = sig:Connect(function() P.log("CHANGED", inst.Name .. (attr and ("." .. attr) or ""), attr and inst:GetAttribute(attr) or inst.Value) end)
end
function P.finish()
	closeBlock()
	local text = table.concat(P.blocks, "\n\n")
	if setclipboard then pcall(setclipboard, text) end
	if writefile then pcall(writefile, "probe_last.txt", text) end
	print("[probe] " .. #P.blocks .. " block(s) copied to the clipboard and saved to probe_last.txt")
	return text
end
