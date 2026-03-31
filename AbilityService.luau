--!strict

-- AbilityService | Server
-- @ExodusF8, RBLX

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Red = require(ReplicatedStorage.Packages.Red)

local Fireball = require(ReplicatedStorage.Abilities.Fireball.Fireball)
local GalaxyImpact = require(ReplicatedStorage.Abilities.GalaxyImpact.GalaxyImpact)
local Types = require(ReplicatedStorage.Shared.Types)

local AbilityService = Knit.CreateService {
	Name = "AbilityService",
	Client = {},
}

-- each player gets their own table of ability names and when they last used them
local cooldowns: { [number]: { [string]: number } } = {}

-- each projectile stores its own speed, damage and distance so we don't have to read Config every frame
local activeProjectiles: { [Part]: { caster: Player, damage: number, speed: number, distance: number, maxDistance: number } } = {}

-- declared here and assigned in KnitStart because Red needs to initialise before we can open a channel
local Net


-- checks how much time has passed since the player last used this ability
-- if it is less than the cooldown duration, the cast is blocked
local function isOnCooldown(player: Player, abilityName: string, cooldown: number): boolean
	local userId = player.UserId
	cooldowns[userId] = cooldowns[userId] or {}
	local last = cooldowns[userId][abilityName] or 0
	return (tick() - last) < cooldown
end

-- records the current time so the cooldown window starts from this cast
local function setCooldown(player: Player, abilityName: string)
	local userId = player.UserId
	cooldowns[userId] = cooldowns[userId] or {}
	cooldowns[userId][abilityName] = tick()
end


local function destroyProjectile(projectile: Part, position: Vector3, didHit: boolean)
	if not activeProjectiles[projectile] then return end -- prevents this running twice on the same projectile
	activeProjectiles[projectile] = nil -- drop it from the loop immediately before any yields below

	local travelSound = projectile:FindFirstChild("TravelSound")
	if travelSound then
		travelSound:Stop()
	end

	local impactSound = projectile:FindFirstChild("ImpactSound")
	if impactSound and didHit then
		impactSound.Parent = workspace -- move to workspace before destroying the part so the sound is not cut short
		impactSound:Play()
		task.delay(3, function()
			if impactSound and impactSound.Parent then
				impactSound:Destroy()
			end
		end)
	end

	-- tell every client which effect to play at the position where the projectile stopped
	if didHit then
		Net:FireAll("AbilityVFX", "FireballExplosion", { Position = position })
	else
		Net:FireAll("AbilityVFX", "FireballFizzle", { Position = position })
	end

	projectile:Destroy()
end


local function spawnFireball(caster: Player, data: Types.CastData)
	local ability = Fireball.new() -- constructor returns the ability object with its Config attached via metatable

	if isOnCooldown(caster, data.AbilityName, ability.Config.Cooldown) then return end

	local char = caster.Character
	if not char then return end

	local direction = data.Direction.Unit -- normalise the direction so projectile speed is always consistent

	local template = ReplicatedStorage.Abilities.Fireball.FireballVFX
	local projectile = template:Clone() -- clone the visual so the original template is never modified
	projectile.CFrame = CFrame.new(data.Origin, data.Origin + direction) -- position it at the origin facing the cast direction
	projectile.Anchored = true -- we reposition it manually each frame so physics should not move it
	projectile.CanCollide = false -- hits are detected through raycasting, the physics engine is not involved
	projectile.Parent = workspace

	local travelSound = projectile:FindFirstChild("TravelSound")
	if travelSound then
		travelSound:Play()
	end

	setCooldown(caster, data.AbilityName)

	-- add to the active table so the Heartbeat loop starts simulating it from the next frame
	activeProjectiles[projectile] = {
		caster = caster,
		damage = ability.Config.BaseDamage,
		distance = 0,
		speed = ability.Config.ProjectileSpeed,
		maxDistance = ability.Config.MaxDistance,
	}
end


local function spawnGalaxyImpact(caster: Player, data: Types.CastData)
	local ability = GalaxyImpact.new()

	if isOnCooldown(caster, data.AbilityName, ability.Config.Cooldown) then return end

	local char = caster.Character
	if not char then return end

	local position = data.Origin + Vector3.new(0, ability.Config.SpawnHeight, 0) -- push the spawn point up so the vortex sits above the ground
	setCooldown(caster, data.AbilityName)

	local template = ReplicatedStorage.Abilities.GalaxyImpact.GalaxyImpactVFX
	local vortex = template:Clone()
	vortex:PivotTo(CFrame.new(position))
	vortex.Parent = workspace

	-- collect all emitters and beams into arrays before any loops run so we never call GetDescendants per frame
	local emitters: { { emitter: ParticleEmitter, originalRate: number } } = {}
	local beams: { Beam } = {}

	for _, obj in vortex:GetDescendants() do
		if obj:IsA("ParticleEmitter") then
			local originalRate = obj.Rate
			obj.Rate = 0 -- silence it at spawn so the fade-in below controls when it becomes visible
			table.insert(emitters, { emitter = obj, originalRate = originalRate })
		elseif obj:IsA("Beam") then
			obj.Transparency = NumberSequence.new(1) -- fully transparent at spawn, faded in below
			table.insert(beams, obj)
		end
	end

	local sound = vortex:FindFirstChild("VortexSound")
	if sound then
		sound:Play()
	end

	-- run the fade-in on a separate thread so it does not pause the function that called it
	-- 20 steps gives a smooth enough ramp without running too many iterations
	task.spawn(function()
		local steps = 20
		for i = 1, steps do
			for _, entry in emitters do
				if entry.emitter and entry.emitter.Parent then
					entry.emitter.Rate = (i / steps) * entry.originalRate -- gradually bring each emitter up to its original rate
				end
			end
			for _, beam in beams do
				if beam and beam.Parent then
					beam.Transparency = NumberSequence.new(1 - (i / steps)) -- reduce transparency each step until fully visible
				end
			end
			task.wait(1 / steps)
		end
	end)

	local elapsed = 0
	local damageTickRate = 0.5 -- without this cap, damage would scale with frame rate instead of time
	local lastDamageTick = 0
	local connection

	connection = RunService.Heartbeat:Connect(function(dt)
		if not vortex or not vortex.Parent then
			connection:Disconnect()
			return
		end

		elapsed += dt

		local parts = workspace:GetPartBoundsInRadius(position, ability.Config.SuctionRadius)
		local hitModels: { [Model]: boolean } = {}

		for _, part in parts do
			local model = part:FindFirstAncestorWhichIsA("Model")
			if not model then continue end
			if hitModels[model] then continue end -- characters have many parts, we only want to process each character once

			local hum = model:FindFirstChildWhichIsA("Humanoid")
			if not hum then continue end
			if hum.Health <= 0 then continue end

			local targetPlayer = Players:GetPlayerFromCharacter(model)
			if targetPlayer == caster then continue end -- the caster should not be pulled by their own vortex

			local root = model:FindFirstChild("HumanoidRootPart")
			if not root then continue end

			hitModels[model] = true

			local dist = (position - root.Position).Magnitude
			local dir = (position - root.Position).Unit -- direction from the character toward the vortex centre

			if dist <= ability.Config.KillRadius then
				hum.Health = 0 -- anything inside the inner radius dies immediately
				continue
			end

			-- BodyVelocity applies a steady force every frame rather than a single push
			-- this keeps the pull smooth and consistent regardless of frame rate
			-- we reuse an existing one if it is already on the character to avoid creating a new instance every frame
			local bv = root:FindFirstChild("GalaxyBV") or Instance.new("BodyVelocity")
			bv.Name = "GalaxyBV"
			bv.Velocity = dir * ability.Config.SuctionForce
			bv.MaxForce = Vector3.new(1e5, 1e5, 1e5) -- high enough to override the default character movement forces
			bv.P = 1e4
			bv.Parent = root

			if elapsed - lastDamageTick >= damageTickRate then
				hum:TakeDamage(ability.Config.BaseDamage)
			end
		end

		if elapsed - lastDamageTick >= damageTickRate then
			lastDamageTick = elapsed
		end

		if elapsed >= ability.Config.Duration then
			connection:Disconnect()

			-- remove the suction force from every character so they are not stuck being pulled after the vortex ends
			for _, p in workspace:GetChildren() do
				if p:IsA("Model") then
					local root = p:FindFirstChild("HumanoidRootPart")
					if root then
						local bv = root:FindFirstChild("GalaxyBV")
						if bv then bv:Destroy() end
					end
				end
			end

			local vortexSound = vortex:FindFirstChild("VortexSound")
			if vortexSound then
				vortexSound:Stop()
			end

			-- run the same fade logic in reverse so the vortex gradually disappears instead of vanishing instantly
			task.spawn(function()
				local steps = 20
				for i = steps, 0, -1 do
					for _, entry in emitters do
						if entry.emitter and entry.emitter.Parent then
							entry.emitter.Rate = (i / steps) * entry.originalRate
						end
					end
					for _, beam in beams do
						if beam and beam.Parent then
							beam.Transparency = NumberSequence.new(1 - (i / steps))
						end
					end
					task.wait(2 / steps)
				end

				task.delay(2, function()
					if vortex and vortex.Parent then
						vortex:Destroy() -- small delay so any remaining particles finish before the model is removed
					end
				end)
			end)
		end
	end)
end


function AbilityService:KnitStart()
	-- open the Red channel and declare which events will be sent between server and client
	Net = Red.Server("AbilityNet", {
		"AbilityCast",
		"AbilityVFX",
	})

	-- listen for incoming cast requests and route them to the correct ability function
	Net:On("AbilityCast", function(player: Player, data: Types.CastData)
		if data.AbilityName == "Fireball" then
			spawnFireball(player, data)
		elseif data.AbilityName == "GalaxyImpact" then
			spawnGalaxyImpact(player, data)
		end
	end)

	-- one shared Heartbeat connection steps all active projectiles to avoid multiple connections running at once
	RunService.Heartbeat:Connect(function(dt: number)
		for projectile, state in activeProjectiles do
			if not projectile.Parent then
				activeProjectiles[projectile] = nil -- part no longer exists, remove it from the table
				continue
			end

			local frame = projectile.CFrame
			local stepDistance = state.speed * dt -- multiply by delta time so movement speed does not change with frame rate

			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			rayParams.FilterDescendantsInstances = { state.caster.Character, projectile } -- stop the ray hitting the caster or the projectile itself

			local result = workspace:Raycast(frame.Position, frame.LookVector * stepDistance, rayParams)

			if result then
				local hit = result.Instance
				local model = hit:FindFirstAncestorWhichIsA("Model")
				local hum = model and model:FindFirstChildWhichIsA("Humanoid")

				if hum and hum.Health > 0 then
					local targetPlayer = Players:GetPlayerFromCharacter(model)
					if targetPlayer ~= state.caster then
						hum:TakeDamage(state.damage)
					end
				end

				destroyProjectile(projectile, result.Position, true)
				continue
			end

			projectile.CFrame = frame + frame.LookVector * stepDistance -- move the projectile forward by this frame's distance
			state.distance += stepDistance

			if state.distance >= state.maxDistance then
				destroyProjectile(projectile, projectile.Position, false) -- hit nothing and reached the range limit
			end
		end
	end)

	-- remove the player's cooldown data when they leave so it does not sit in memory indefinitely
	Players.PlayerRemoving:Connect(function(player: Player)
		cooldowns[player.UserId] = nil
	end)
end

return AbilityService