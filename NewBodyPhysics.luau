-- Discord Username: @Raskali , Roblox Username: @RaskaliThings
--[[
class-based body physics system
uses Linear Velocity
]]

local S_RS = game:GetService("ReplicatedStorage")
local S_Tween = game:GetService("TweenService")
local S_Run = game:GetService("RunService")
local S_Http = game:GetService("HttpService")

local bodyEvent_rev = S_RS:WaitForChild("Remotes").Replication.BodyEvent

local sharedTypes = require(S_RS.SharedTypes)
type Body = sharedTypes.Body

local bodyPhysics = {}
bodyPhysics.__index = bodyPhysics

-- local forceData class
local forceData = {}
forceData.__index = forceData

-- main type
export type BodyPhysics = {
	AppliedForces:AppliedForces;
	AppliedModifiers:AppliedModifiers;
	AppliedStates:AppliedStates;
	AppliedStateCounters: {AppliedStateCounter} ;
	IsTargetFacing: boolean;
	TargetFacing_Conn: RBXScriptConnection?;
	Conn: RBXScriptConnection;
	KnockbackResistance: number?;
	Body: sharedTypes.Body;

	ApplyForce: (self: BodyPhysics, ForceParams) -> boolean;
	Destroy: (self:BodyPhysics) -> nil;
	InitializeConnection: (self:BodyPhysics) -> nil;
}

-- type of applied forces. pls pls pls pls pls add to this if making a new one
export type AppliedForces = {
	All: {[string]: ForceData};
	Knockback: {[string]: ForceData};
	Pull: {[string]: ForceData}; -- includes constant pull
	Dash: {[string]: ForceData};
}

-- unstackable forces
export type AppliedStates = {
	StopMovement: {AmountApplied: number, ForceData: ForceData?, yLocked: boolean?};		-- stops movement only
	StopForces: {AmountApplied: number}; -- stops forces from happening
	AntiGravity: {AmountApplied: number, ForceData: ForceData?};
	TargetFacing: {AmountApplied: number, Instances: OrientationInstances?, yLocked: boolean?};
	Invisibility: {AmountApplied: number, InvisParts: {[Part]: number}}; -- {transparent parts}
}

-- for unstackable forces (states) WITH A DURATION. here so i dont have to use task.delay for duration. this is each individual applier of a state (w. durati)
export type AppliedStateCounter = {
	StartTime: number;
	StateName: string;
	Duration: number; -- counters are only for applying state that have a duration!!! (and some modifiers too)
	OnEnd: () -> nil; 
}


-- misc
export type AppliedModifiers = {
	-- target facing isnt a modifier it needs to be running constantly
}


-- attachment and lv
export type PhysicsInstances = {
	Attachment:Attachment;
	LV:LinearVelocity;
	Tween:Tween?;
}

-- attachment and alignOrientation
export type OrientationInstances = {
	Attachment:Attachment;
	AO:AlignOrientation;
	Tween:Tween?;
}

-- the information of a CURRENT force. inherits force params. [CLASS]
export type ForceData = {

	StartTime: number;
	Id: string;
	ForceTypes: {[string]: true}; -- name of force. usually "All" and something else. used to clear it from tracked
	Complete: boolean;
	
	Instances: PhysicsInstances;

	Start:(self: ForceData, body: Body) -> nil;
	Update:(self: ForceData, body: Body, dt:number) -> nil;
	End:(self: ForceData, body: Body) -> nil;
	TrackForce:(self: ForceData, body: Body) -> nil;
} & ForceParams

-- the info needed to apply a force
export type ForceParams = {
	Velocity: Vector3;
	Duration: number;
	MaxForce: Vector3?;
	Decay: number?;
	RunHitbox: {}?; -- work on this
	StartCallback: (bodyCFrame: CFrame, startTime: number) -> nil?,
	EndCallback: (bodyCFrame: CFrame, startTime: number, endTime: number) -> nil?,
}

local DEFAULT_DURATION = 0.25 -- for force applying
local DEFAULT_MAXFORCE = Vector3.new(50000,50000,50000) -- for force applying

--[[
=========
@ CLASS FUNCTIONS
=========
]]

--[[
Initialize new body physics. set up values
]]
function bodyPhysics.New(body: sharedTypes.Body)

	local newBodyPhysics = setmetatable({}, bodyPhysics)

	newBodyPhysics.AppliedForces = {}
	newBodyPhysics.AppliedForces.All = {}
	newBodyPhysics.AppliedForces.Knockback = {}
	newBodyPhysics.AppliedForces.Pull = {}
	newBodyPhysics.AppliedForces.Dash = {}
	
	newBodyPhysics.AppliedStates = {}
	newBodyPhysics.AppliedStates.StopMovement = {AmountApplied = 0}
	newBodyPhysics.AppliedStates.StopForces = {AmountApplied = 0}
	newBodyPhysics.AppliedStates.AntiGravity = {AmountApplied = 0}
	newBodyPhysics.AppliedStates.TargetFacing = {AmountApplied = 0}
	newBodyPhysics.AppliedStates.Invisibility = {AmountApplied = 0, InvisParts = {}}
	
	newBodyPhysics.AppliedStateCounters = {}

	newBodyPhysics.AppliedModifiers = {}
	newBodyPhysics.AppliedModifiers.Invisibility = 0

	newBodyPhysics.IsTargetFacing = false
	newBodyPhysics.KnockbackResistance = 0;

	newBodyPhysics.Body = body

	-- begin main run connection for this body's physics
	newBodyPhysics:InitializeConnection()

	return newBodyPhysics
end

-- destroys the body. ends connection and stops all forces
function bodyPhysics:Destroy()

	self.Conn:Disconnect()
	-- remove all forces (they should all be part of ALL at least)
	self:ClearForces()

	setmetatable(self, nil)

end


-- begin connection for bodyPhysics. handles force updates
function bodyPhysics:InitializeConnection()

	assert(not self.Conn, "Could not make a run connection for body physics because it already exists.")

	local body: Body = self.Body

	-- HANDLE FORCE UPDATES
	self.Conn = S_Run.Heartbeat:Connect(function(dt:number)
		-- death event usually clears this connection first but just to be sure
		if (not body) or (body.Health == 0) or (not body.Root) then return end

		local now = workspace:GetServerTimeNow()

		-- check STACKABLE all forces (they should all be part of ALL at least)
		for i, FD: ForceData in pairs(body.Physics.AppliedForces.All) do
			if FD.Complete then continue end
			-- 1) duration check
			if (now - FD.StartTime) >= FD.Duration then
				FD:End(body)
				continue
			end
			--2) update
			FD:Update(body, dt)
		end
		
		-- check all STATES with a duration. end the increment if duration is up
		local removeStateIndexes = {}
		for i, ASC: AppliedStateCounter in pairs(body.Physics.AppliedStateCounters) do
			if (now - ASC.StartTime) >= ASC.Duration then
				ASC:OnEnd()
				removeStateIndexes[i] = true
				continue
			end
		end
		-- remove appliedStateCounters if it ended this frame
		for index: number, _ in pairs(removeStateIndexes) do
			body.Physics.AppliedStateCounters[index] = nil
		end
		
	end)

end

-- gets the number of forces being applied to this body; ex: "Dash". needs to bc a func because key value is id for forceData
function bodyPhysics:GetAppliedForceAmount(forceType: string)
	local appliedForces: AppliedForces = self.AppliedForces
	local amount = 0
	for _, _ in pairs(appliedForces[forceType] or {}) do
		amount += 1
	end
	return amount
end

-- apply a new counter for a state that has a duration. end function should call whataver removes the increment
function bodyPhysics:ApplyStateCounter(duration: number, stateName: string, on_end: () -> nil): AppliedStateCounter
	
	local newCounter:AppliedStateCounter = {}
	newCounter.StartTime = workspace:GetServerTimeNow()
	newCounter.Duration = duration
	newCounter.StateName = stateName
	newCounter.OnEnd = on_end
	
	-- add to bodyphysics
	table.insert(self.AppliedStateCounters, newCounter)
	return newCounter
end

--[[
clears all applied general forces from a body
]]
function bodyPhysics:ClearForces()
	local indexesToRemove = {}
	for i, FD: ForceData in pairs(self.AppliedForces.All) do -- all forces (non state) should at least be part of ALL table
		FD:End(self.Body)
		indexesToRemove[i] = true
	end
	for index, _ in pairs(indexesToRemove) do
		self.AppliedForces.All[index] = nil
	end
end


--[[
initialize a new forceData
unstackable means its a state, not a modular force
]]
function forceData.New(forceParams:ForceParams, unstackable: boolean?)

	local newForceData: ForceData = {}
	newForceData.Velocity = forceParams.Velocity or Vector3.zero
	newForceData.Duration = forceParams.Duration or DEFAULT_DURATION
	newForceData.MaxForce = forceParams.MaxForce or DEFAULT_MAXFORCE
	newForceData.Decay = forceParams.Decay or false
	newForceData.RunHitbox = forceParams.RunHitbox
	newForceData.StartCallback = forceParams.StartCallback or function() end
	newForceData.EndCallback = forceParams.EndCallback or function() end
	newForceData.Instances = {}
	newForceData.StartTime = workspace:GetServerTimeNow()
	newForceData.ForceTypes = {}
	newForceData.Id = S_Http:GenerateGUID()
	newForceData.Unstackable = unstackable or false

	setmetatable(newForceData, forceData)
	return newForceData
end

--[[
start a force. creates instances and parents them to the body. starts callback
assumes body exists and all force coniditons have been handled
]]
function forceData:Start(body: Body)

	-- make attachment o yeah o yeah
	local att = Instance.new("Attachment")
	att.Name = "ForceAtt"
	att.Parent = body.Root
	self.Instances.Attachment = att

	-- MAKE FORCE!!
	local lv = Instance.new("LinearVelocity")
	lv.Parent = att
	lv.Attachment0 = att
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	self.Instances.LV = lv

	local duration = self.Duration
	lv.MaxAxesForce = self.MaxForce
	lv.VectorVelocity = self.Velocity -- begin

	-- decay tween
	if self.Decay then
		local tween = S_Tween:Create(lv, TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out), {
			VectorVelocity = Vector3.new(0,0,0)
		})
		tween:Play()
		self.Instances.Tween = tween
	end

	-- add to body physics all general forces
	if not self.Unstackable then
		self:TrackForce(body, "All")
	end

	-- START CALLBACK
	self.StartCallback(body.Root.CFrame)

end

-- adds the forceData to an appliedForces table and sets its forceTypes values. assumes body exists
function forceData:TrackForce(body: Body, forceType: string)
	assert(body.Physics.AppliedForces[forceType], "Force type does not exist: ".. tostring(forceType))
	body.Physics.AppliedForces[forceType][self.Id] = self
	self.ForceTypes[forceType] = true
	print(body, self)
end

--[[
states are unstackable. increments the state's applyAmount by one.
RETURNS TRUE IF SHOULD APPLY EFFECT (applyamount is now 1)
RETURNS AN ADDITIONAL PARAM OF THE CURRENT APPLIED FORCE [yLocked Usually] so u can flip flop based on most recent application
]]
function bodyPhysics:TrackState(stateType: string, returnAdditional: "yLocked"?): (true?, any?)
	local body:Body = self.Body
	assert(body.Physics.AppliedStates[stateType], "State type does not exist: ".. tostring(stateType))
	if not body.Physics.AppliedStates[stateType].AmountApplied then body.Physics.AppliedStates[stateType].AmountApplied = 0 end
		body.Physics.AppliedStates[stateType].AmountApplied += 1
	return body.Physics.AppliedStates[stateType].AmountApplied == 1,
		returnAdditional and body.Physics.AppliedStates[stateType][returnAdditional] -- current yLocked state?
end

-- states are unstackable. removes the state's applyAmount by one. RETURNS TRUE IF SHOULD STOP APPLYING EFFECT (applyAmount is now 0)
function bodyPhysics:UntrackState(stateType: string): true?
	local body:Body = self.Body
	assert(body.Physics.AppliedStates[stateType], "State type does not exist: ".. tostring(stateType))
	body.Physics.AppliedStates[stateType].AmountApplied = math.max(body.Physics.AppliedStates[stateType].AmountApplied - 1, 0)
	return body.Physics.AppliedStates[stateType].AmountApplied == 0
end

-- runs every heartbeat from initialized bodyphysics conn. assumes body exists
function forceData:Update(body: Body)

end

-- stops the force and clears the object. assums body exists
function forceData:End(body: Body)

	local instances: PhysicsInstances = self.Instances
	if instances.Attachment then instances.Attachment:Destroy() end
	self.Complete = true
	
	-- END CALLBACK
	self.EndCallback(body:GetCFrame(), self.StartTime, workspace:GetServerTimeNow())

	-- remove from all tables its a part of. (stackable force)
	for forceType:string, _ in pairs(self.ForceTypes) do
		body.Physics.AppliedForces[forceType][self.Id] = nil
	end
	
	print(body.Physics.AppliedForces)

	setmetatable(self, nil)
end


--[[
===============
@ FORCE/MODIFIER FUNCTIONS
===============
]]

--[[
apply a basic force to a character
returns IsSuccess, ForceData
use forceData to set
unstackable means its an appliedState not force (doesnt get added to "All" table AND is unable to be force stopped AND duration doesnt matter)
]]
function bodyPhysics:ApplyForce(forceParams:ForceParams, unstackable: boolean?): (true?, ForceData)

	local body: Body = self.Body
	if (not body) or (body.Health.Current == 0) or (not body.Root) then return end

	if not unstackable then
		if self.AppliedStates.StopForces.AmountApplied > 0 then return end
	end

	-- create force data
	local newForceData: ForceData = forceData.New(forceParams, unstackable)
	newForceData:Start(body)
	return true, newForceData

end

--[[
apply KNOCKBACK to a character
can pass direction or position.
do not pass velocity for forceParams because jt will be made automatixally.
]]
function bodyPhysics:ApplyKnockback(position: Vector3?, direction: Vector3?, strength: number, forceParams: ForceParams?): (true?, ForceData?)

	if not self.Body.Root then return end

	-- turn position into direction
	if not direction then
		assert(position, "No position or direction passed for knockback force.")

		direction = (self.Body:GetCFrame().Position - position).Unit

	end

	local finalVelocity = direction * strength
	forceParams = forceParams or {}
	forceParams.Velocity = finalVelocity

	local success: true?, FD: ForceData? = self:ApplyForce(forceParams)
	-- unsucessful
	if not success then return end
	FD:TrackForce(self.Body, "Knockback")

	return success, FD
end

--[[
makes a body dash to their target position
]]
function bodyPhysics:DashToTargetPosition(strength: number, forceParams: ForceParams, yLocked: boolean?, endLag: number?, toFacingDirectionInstead: boolean?):
	(true?, ForceData?)

	if not self.Body.Root then return end
	
	local pos = self.Body:GetCFrame().Position
	local targetPos: Vector3 = self.Body:GetTargetPosition()

	-- handle toFacingDirectionInstead
	if toFacingDirectionInstead then
		targetPos = self.Body:GetCFrame().LookVector * strength -- * strenth is arbitrary
	end
	-- handle yLocked
	if yLocked then
		targetPos = Vector3.new(targetPos.X, self.Body:GetCFrame().Y, targetPos.Z)
	end

	-- apply endLag to EndCallback
	if endLag then
		local oldCallback = forceParams.EndCallback or function() end

		forceParams.EndCallback = function(...)
			
			self:StopMovement(endLag, true)
			
			oldCallback(...)
		end
	end
	
	-- handle VELOCITY
	local directon = (targetPos - pos).Unit
	forceParams.Velocity = strength * directon
	
	-- if airborne, lower the velocity bc of no friction
	if self:IsAirborne() then
		--print("DASH WAS AIRBORNE")
		forceParams.Velocity *= 0.8
	end
	
	-- # CHECK MOVEMENT DIRECTION COMPARED TO TARGET DIRECTION (dot product!!)
	local moveDirection = self.Body.Humanoid.MoveDirection

	local dot = moveDirection:Dot(directon) -- -1 (opposite) to 1 (same)
	local movementSimilarityPercent = (dot + 1) / 2 -- convert to 0�1 range
	movementSimilarityPercent = math.max(movementSimilarityPercent, 0.1) -- not too small

	local scale = math.sqrt(1 / movementSimilarityPercent)
	scale = math.min(scale, 1.2) -- max 1.2x boost

	forceParams.Velocity *= scale
	
	--print("MOVEMENT SIMILAITY: ", movementSimilarityPercent, scale)
	
	local success: true?, FD: ForceData? = self:ApplyForce(forceParams)
	-- unsucessful
	if not success then return end
	FD:TrackForce(self.Body, "Dash")

	return success, FD
end


--[[
pulls body into a point
strength of 100 means the body will always be pulled to the center
]]
function bodyPhysics:ApplyPull(toPos: Vector3, strength: number, forceParams: ForceParams): (true?, ForceData?)
	
	if not self.Body.Root then return end

	local duration = (forceParams and forceParams.Duration) or DEFAULT_DURATION
	local pos = self.Body.Root.Position
	local direction = (toPos - pos)
	local distance = direction.Magnitude
	if distance == 0 then return end

	local ratio = math.clamp(strength / 100, 0, 1)

	-- instead of ratio * distanceLeft, do ratio * originalDistance
	local moveDistance = (ratio * distance)
	local targetPos = pos + direction.Unit * moveDistance

	local newDir = targetPos - pos
	local velocity = newDir.Unit * (newDir.Magnitude / duration)

	local pullInfo: ForceInfo = forceParams or {}
	pullInfo.Velocity = velocity
	pullInfo.Duration = duration

	local success: true?, FD: ForceData? = self:ApplyForce(forceParams)
	-- unsucessful
	if not success then return end
	FD:TrackForce(self.Body, "Pull")

	return success, FD
end

--[[
stop FORCES
so physics functions
returns newApplied: true?
]]
function bodyPhysics:StopForces(duration: number?): true?
	
	-- increment one to movement stoppers
	local shouldApply: true?, wasyLocked:boolean? = self:TrackState("StopForces")

	-- if there's a duration then attach a counter
	if duration then
		self:ApplyStateCounter(duration, "StopForces", function()
			self:ResumeForces()
		end)
	end

	-- should apply unique force
	if shouldApply  then
		return true
	else
		
	end
	
end

--[[
returns successfulRemove:true?
]]
function bodyPhysics:ResumeForces(): true?
	-- increment -1 from movement stoppers
	-- this func returns true if the applied amount is zero
	local shouldStopApplying: true? = self:UntrackState("StopMovement")

	if shouldStopApplying then
		return true -- successful remove
	end
end

--[[
stop MOVEMENT
can also handle force stoppers
returns newApplied: true?
]]
function bodyPhysics:StopMovement(duration: number?, yLocked: boolean?, alsoStopForces: boolean?): true?
	
	-- increment one to movement stoppers
	-- this func returns true if the applied amount is one AND returns the 2nd param value of its current table
	local shouldApply: true?, wasyLocked:boolean? = self:TrackState("StopMovement", "yLocked")
	
	if alsoStopForces then
		self:StopForces(duration)
	end
	
	-- if there's a duration then attach a counter
	if duration then
		self:ApplyStateCounter(duration, "StopMovement", function()
			self:ResumeMovement()
		end)
	end
	
	-- should apply unique force
	if shouldApply  then
		local forceParams: ForceParams = {}
		forceParams.Velocity = Vector3.new(0,0,0)
		forceParams.MaxForce = Vector3.new(math.huge, yLocked and math.huge or 0 ,math.huge)
		
		local success: true?, FD: ForceData? = self:ApplyForce(forceParams, true)
		-- unsucessful
		if not success then return end
		self.AppliedStates.StopMovement.ForceData = FD
		self.AppliedStates.StopMovement.ForceData.Instances.Attachment.Name = "StopMovementAtt"
		self.AppliedStates.StopMovement.yLocked = yLocked
		print(self.AppliedStates.StopMovement)
		
		return true -- new applied force
		
	else
		
		-- force already exists
		local currentForce: ForceData = self.AppliedStates.StopMovement.ForceData
		if not currentForce then return end
		
		-- change current force based on newest yLocked
		currentForce.Instances.LV.MaxAxesForce = Vector3.new(math.huge, yLocked and math.huge or 0, math.huge)
		
	end
	
end

--[[
resumes movement if there are no longer any appliers
returns successfulRemove:true?
]]
function bodyPhysics:ResumeMovement(alsoResumeForce: boolean?): true?
	
	-- increment -1 from movement stoppers
	-- this func returns true if the applied amount is zero
	local shouldStopApplying: true? = self:UntrackState("StopMovement")
	
	if alsoResumeForce then
		self:ResumeForces()
	end
	
	if shouldStopApplying then
		local currentForce: ForceData = self.AppliedStates.StopMovement.ForceData
		if not currentForce then return end
		
		-- remove this force
		currentForce:End(self.Body)
		self.AppliedStates.StopForces.ForceData = nil
		self.AppliedStates.StopForces.yLocked = nil
			
		return true -- successful remove
	end
	
end

return bodyPhysics
