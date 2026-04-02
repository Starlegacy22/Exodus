--!strict

-- AbilityService | Server
-- @ExodusF8, RBLX

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Red = require(ReplicatedStorage.Packages.Red)
local Fireball = require(ReplicatedStorage.Abilities.Fireball.Fireball)
local GravityBeam = require(ReplicatedStorage.Abilities.GravityBeam.GravityBeam)
local Types = require(ReplicatedStorage.Shared.Types)

type CooldownMap = { [number]: { [string]: number } }

-- caches speed and damage at spawn so we're not reading the Config every frame
type ProjectileState = {
	caster: Player,
	damage: number,
	speed: number,
	distance: number,
	maxDistance: number,
}

-- active is the on/off switch for the pull loop, setting it false stops the loop from outside
type BeamSession = {
	active: boolean,
	target: Model,
	originAtt: Attachment?,
	hitAtt: Attachment?,
}

local ProjectileStateMeta = {}
ProjectileStateMeta.__index = ProjectileStateMeta

function ProjectileStateMeta.new(caster: Player, damage: number, speed: number, maxDistance: number): ProjectileState
	return setmetatable({
		caster = caster,
		damage = damage,
		speed = speed,
		distance = 0,
		maxDistance = maxDistance,
	}, ProjectileStateMeta) :: any
end

local AbilityService = Knit.CreateService {
	Name = "AbilityService",
	Client = {},
}

-- each player gets their own table of ability names and the last time they used them
local cooldowns: CooldownMap = {}

-- each projectile part maps to its own state so the Heartbeat loop knows how to move and destroy it
local activeProjectiles: { [Part]: ProjectileState } = {}

-- one beam session per player at a time
local activeSessions: { [Player]: BeamSession } = {}

-- declared here and assigned in KnitStart because Red needs to be set up before we can use it
local Net

local function getRoot(model: Model): BasePart?
	return (model:FindFirstChild("HumanoidRootPart") or model:FindFirstChild("Torso")) :: BasePart?
end

-- checks if enough time has passed since the player last used this ability
-- if not, the cast is blocked
local function isOnCooldown(player: Player, abilityName: string, cooldown: number): boolean
	local userId = player.UserId
	cooldowns[userId] = cooldowns[userId] or {}
	local last = cooldowns[userId][abilityName] or 0
	-- os.clock is more reliable than tick()
	return (os.clock() - last) < cooldown
end

-- stamps the current time so the cooldown starts from this cast
local function setCooldown(player: Player, abilityName: string)
	local userId = player.UserId
	cooldowns[userId] = cooldowns[userId] or {}
	cooldowns[userId][abilityName] = os.clock()
end

local function isCaster(model: Model, caster: Player): boolean
	return Players:GetPlayerFromCharacter(model) == caster
end

local function destroyProjectile(projectile: Part, position: Vector3, didHit: boolean)
	if not activeProjectiles[projectile] then return end -- stops this running twice on the same projectile
	activeProjectiles[projectile] = nil -- remove from the loop immediately before anything yields below

	local travelSound = projectile:FindFirstChild("TravelSound") :: Sound?
	if travelSound then travelSound:Stop() end

	if didHit then
		local impactSound = projectile:FindFirstChild("ImpactSound") :: Sound?
		if impactSound then
			-- move to workspace before destroying the part so the sound isn't cut off early
			impactSound.Parent = workspace
			impactSound:Play()
			task.delay(3, function()
				if impactSound and impactSound.Parent then impactSound:Destroy() end
			end)
		end
		Net:FireAll("AbilityVFX", "FireballExplosion", { Position = position })
	else
		Net:FireAll("AbilityVFX", "FireballFizzle", { Position = position })
	end

	projectile:Destroy()
end

local function clearPullConstraint(targetRoot: BasePart)
	local att = targetRoot:FindFirstChild("_GravityAtt")
	local lv = targetRoot:FindFirstChild("_GravityLV")
	if lv then lv:Destroy() end
	if att then att:Destroy() end
end

-- recalculates direction every tick so the target curves toward the caster as they both move
-- uses LinearVelocity because BodyVelocity is deprecated
local function applyPullTick(ability: typeof(GravityBeam.new()), casterRoot: BasePart, targetRoot: BasePart)
	local dist = (targetRoot.Position - casterRoot.Position).Magnitude
	if dist <= ability.Config.StopDistance then
		clearPullConstraint(targetRoot)
		return
	end

	local direction = (casterRoot.Position - targetRoot.Position).Unit
	local velocity = direction * ability.Config.PullSpeed

	local lv = targetRoot:FindFirstChild("_GravityLV") :: LinearVelocity?
	if not lv then
		local att = Instance.new("Attachment")
		att.Name = "_GravityAtt"
		att.Parent = targetRoot

		lv = Instance.new("LinearVelocity")
		lv.Name = "_GravityLV"
		lv.Attachment0 = att
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		lv.MaxForce = 1e5
		lv.RelativeTo = Enum.ActuatorRelativeTo.World
		lv.Parent = targetRoot
	end

	(lv :: LinearVelocity).VectorVelocity = velocity
end

-- grabs the two attachments from the cloned VFX model and parents them to the caster arm and target
-- so the Beam instance stretches between them automatically, then trashes the empty container
local function attachBeamVFX(caster: Player, target: Model): (Attachment?, Attachment?)
	local template = ReplicatedStorage.Abilities.GravityBeam.GravityBeamVFX :: Model
	local clone = template:Clone()

	local beamFolder = clone:FindFirstChild("Beam")
	if not beamFolder then clone:Destroy() return nil, nil end

	local originAtt = beamFolder:FindFirstChild("Attachment") :: Attachment?
	local hitAtt = beamFolder:FindFirstChild("2") :: Attachment?
	if not originAtt or not hitAtt then clone:Destroy() return nil, nil end

	local leftArm = caster.Character and caster.Character:FindFirstChild("Left Arm") :: BasePart?
	local targetRoot = getRoot(target)
	if not leftArm or not targetRoot then clone:Destroy() return nil, nil end

	originAtt.Parent = leftArm
	originAtt.Position = Vector3.zero
	hitAtt.Parent = targetRoot
	hitAtt.Position = Vector3.zero

	clone:Destroy()

	Net:FireAll("AbilityVFX", "GravityBeamStart", { CasterChar = caster.Character, Target = target })
	return originAtt, hitAtt
end

local function detachBeamVFX(session: BeamSession, caster: Player)
	if session.originAtt and session.originAtt.Parent then session.originAtt:Destroy() end
	if session.hitAtt and session.hitAtt.Parent then session.hitAtt:Destroy() end
	Net:FireAll("AbilityVFX", "GravityBeamStop", { CasterChar = caster.Character })
end

local function endSession(player: Player)
	local session = activeSessions[player]
	if not session then return end
	session.active = false
	activeSessions[player] = nil

	local targetRoot = getRoot(session.target)
	if targetRoot then clearPullConstraint(targetRoot) end

	detachBeamVFX(session, player)
end

local function spawnFireball(caster: Player, data: Types.CastData)
	local ability = Fireball.new() -- constructor returns the ability object with Config attached via metatable

	if isOnCooldown(caster, data.AbilityName, ability.Config.Cooldown) then return end
	if not caster.Character then return end

	local direction = data.Direction.Unit -- normalise so speed is always consistent regardless of what the client sent

	local template = ReplicatedStorage.Abilities.Fireball.FireballVFX :: Part
	local projectile = template:Clone() :: Part -- clone so the original template is never modified

	-- lookAt points LookVector at the travel direction, which the raycast reads each frame
	projectile.CFrame = CFrame.lookAt(data.Origin, data.Origin + direction)
	projectile.Anchored = true    -- moved manually each frame, physics shouldn't touch it
	projectile.CanCollide = false -- hits come from the raycast, not the physics engine
	projectile.Parent = workspace

	local travelSound = projectile:FindFirstChild("TravelSound") :: Sound?
	if travelSound then travelSound:Play() end

	setCooldown(caster, data.AbilityName)

	-- longer charge = more damage, CalculateDamage handles the scaling curve
	local chargeTime = data.ChargeTime or 0
	local damage = ability:CalculateDamage(chargeTime)

	-- add to the active table so the Heartbeat loop picks it up next frame
	activeProjectiles[projectile] = ProjectileStateMeta.new(
		caster,
		damage,
		ability.Config.ProjectileSpeed,
		ability.Config.MaxDistance
	)
end

local function startGravityBeam(caster: Player, data: Types.CastData)
	local ability = GravityBeam.new()
	if isOnCooldown(caster, data.AbilityName, ability.Config.Cooldown) then return end
	if activeSessions[caster] then return end -- one beam at a time per player

	local casterChar = caster.Character
	if not casterChar then return end

	local casterRoot = casterChar:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not casterRoot then return end

	local targetInstance = data.TargetInstance :: Instance?
	if not targetInstance then return end

	-- walk up from the clicked part until we find a model that has a Humanoid
	local target = targetInstance :: Model
	while target and not target:FindFirstChildOfClass("Humanoid") do
		target = target.Parent :: Model
	end
	if not target then return end
	if isCaster(target, caster) then return end -- can't beam yourself

	local targetRoot = getRoot(target)
	if not targetRoot then return end
	if not ability:InRange(casterRoot, targetRoot) then return end

	local originAtt, hitAtt = attachBeamVFX(caster, target)

	local session: BeamSession = {
		active = true,
		target = target,
		originAtt = originAtt,
		hitAtt = hitAtt,
	}
	activeSessions[caster] = session
	setCooldown(caster, data.AbilityName)

	-- runs on its own thread so it doesn't block anything else
	-- session.active = false is what stops the loop cleanly
	task.spawn(function()
		local elapsed = 0
		while session.active and elapsed < ability.Config.MaxChargeTime do
			local currentCasterRoot = casterChar:FindFirstChild("HumanoidRootPart") :: BasePart?
			local currentTargetRoot = getRoot(target)
			if not currentCasterRoot or not currentTargetRoot then break end

			local hum = target:FindFirstChildWhichIsA("Humanoid") :: Humanoid?
			if not hum or hum.Health <= 0 then break end

			applyPullTick(ability, currentCasterRoot, currentTargetRoot)
			task.wait(ability.Config.TickRate)
			elapsed += ability.Config.TickRate
		end

		-- damage is applied once at the end of the hold, not every tick
		if session.active then
			local hum = target:FindFirstChildWhichIsA("Humanoid") :: Humanoid?
			if hum and hum.Health > 0 then
				hum:TakeDamage(ability.Config.BaseDamage)
			end
		end

		endSession(caster)
	end)
end


function AbilityService:KnitStart()
	-- open the Red channel and register which events are allowed through it
	Net = Red.Server("AbilityNet", {
		"AbilityCast",
		"AbilityVFX",
	})

	-- listen for cast requests from clients and route them to the right function
	Net:On("AbilityCast", function(player: Player, data: Types.CastData)
		if data.AbilityName == "Fireball" then
			spawnFireball(player, data)
		elseif data.AbilityName == "GravityBeam" then
			startGravityBeam(player, data)
		elseif data.AbilityName == "GravityBeam_End" then
			endSession(player)
		end
	end)

	-- one connection moves every active projectile instead of one connection per projectile
	RunService.Heartbeat:Connect(function(dt: number)
		for projectile, state in activeProjectiles do
			if not projectile.Parent then
				activeProjectiles[projectile] = nil -- part is gone, clean it up
				continue
			end

			local frame = projectile.CFrame :: CFrame
			local stepDistance = state.speed * dt -- multiply by delta time so speed doesn't change with frame rate

			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			-- exclude the caster and the projectile itself so the ray never hits either of them
			rayParams.FilterDescendantsInstances = { state.caster.Character or Instance.new("Folder"), projectile }

			local result = workspace:Raycast(frame.Position, frame.LookVector * stepDistance, rayParams)

			if result then
				local hit = result.Instance :: BasePart
				local model = hit:FindFirstAncestorWhichIsA("Model")

				if model and not isCaster(model, state.caster) then
					local hum = model:FindFirstChildWhichIsA("Humanoid") :: Humanoid?
					if hum and hum.Health > 0 then
						hum:TakeDamage(state.damage)
					end
				end

				destroyProjectile(projectile, result.Position, true)
				continue
			end

			projectile.CFrame = frame + frame.LookVector * stepDistance -- move it forward by this frame's distance
			state.distance += stepDistance

			if state.distance >= state.maxDistance then
				destroyProjectile(projectile, projectile.Position, false) -- reached max range without hitting anything
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		endSession(player)
		cooldowns[player.UserId] = nil -- clear their data so it doesn't sit in memory after they leave
	end)

	local function hookCharacter(player: Player)
		player.CharacterAdded:Connect(function(char: Model)
			-- clean up any leftover pull constraints from before the respawn
			local root = char:WaitForChild("HumanoidRootPart") :: BasePart
			local lv = root:FindFirstChild("_GravityLV")
			local att = root:FindFirstChild("_GravityAtt")
			if lv then lv:Destroy() end
			if att then att:Destroy() end
		end)
	end

	-- hook players already in the game in case Knit starts late
	for _, player in Players:GetPlayers() do
		hookCharacter(player)
	end

	Players.PlayerAdded:Connect(hookCharacter)
end

return AbilityService
