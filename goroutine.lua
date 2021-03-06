--[[  goroutine API

Simple interface for multitasking with coroutines. 
By GopherATL
--]]

local gotTerminate=false
local active
local loaded=false

local termNative={
  restore=term.restore,
  redirect=term.redirect,
}

function isActive()
  return active
end

local activeRoutines = { }
local eventAssignments = { }
local entryRoutine
local rootRoutine
local passEventTo=nil
local numActiveCoroutines=0
local isRunning=false

function getInternalState()
  return active, activeRoutines,eventAssignments,entryRoutine,
    rootRoutine,passEventTo,numActiveCoroutines,isRunning
end

if goroutine then
  active, activeRoutines,eventAssignments,entryRoutine,
  rootRoutine,passEventTo,numActiveCoroutines,isRunning=goroutine.getInternalState()
  
else
  active=false
  activeRoutines = { }
  eventAssignments = { }
  entryRoutine=nil
  rootRoutine=nil
  passEventTo=nil
  numActiveCoroutines=0
  isRunning=false
end

loaded=true

local function findCoroutine(co)
  for _,routine in pairs(activeRoutines) do
    if routine.co==co then
      return routine
    end
  end
  return nil
end

function findNamedCoroutine(name)
  return activeRoutines[name]
end

function running()
  return findCoroutine(coroutine.running())
end

local function validateCaller(funcName)
  local callingRoutine=running()  
  if callingRoutine==nil then
    error(funcName.." can only be called by a coroutine running under goroutine!")
  end
  return callingRoutine
end

function assignEvent(assignTo,event,...)  
  --get the routine calling this funciton
  local callingRoutine=validateCaller("assignEvent")
  if callingRoutine~=entryRoutine then
    return false, "assignEvent: only main routine, passed to run(..), can assign events!"
  end
  --get the assignee
  local assignee=callingRoutine
  if assignTo~=nil and assignTo~=callingRoutine.name then
    assignee=findNamedCoroutine(assignTo)
    if assignee==nil then
      return false, "assignEvent: named coroutine not found!"
    end
  end
    
  --is this event already assigned elsewhere?
  if eventAssignments[event]~=nil then  
    return false,"This event assignment conflicts with an existing assignment!"
  end    
  --still here? good, no conflict then
  eventAssignments[event]={co=assignee,assignedBy=callingRoutine}
  return true
end

function passEvent(passTo)
  if passTo==nil then
    passEventTo=""
  else
    passEventTo=passTo
  end
end

  
function releaseEvent(event)
  local callingRoutine=validateCaller("releaseEvent")  
  local ass=eventAssignments[event]
  
  if ass~=nil then
    if caller.co~=entryRoutine and caller~=ass.assignedBy and caller~=ass.routine then
      return false, "Event can only be released by the assigner, assignee, or the entry routine!"
    end
    table.remove(eventAssignments,i)
    return true
  end
  return false
end
  
--called by goroutines to wait for an event to occur with some 
--set of optional event parameter filters
function waitForEvent(event,...)  
  co=validateCaller("waitForEvent")
  co.filters={event,...}
  return coroutine.yield("goroutine_listening")
  
end


local function matchFilters(params,routine)
  if params[1]=="terminate" then
    return true
  end
  for j=1,#params do
    if routine==nil or (routine.filters and routine.filters[j]~=nil and routine.filters[j]~=params[j]) then
      return false
    end
  end
  return true
end


local function sendEventTo(routine, params)
  if routine.dead then
    return
  end
  
  termNative.redirect(routine.redirect[#routine.redirect])
  local succ,r1=coroutine.resume(routine.co,unpack(params))
  termNative.restore()
  
  --did it die or terminate?
  if succ==false or coroutine.status(routine.co)=="dead" then
    --it's dead, remove it from active
    --if there's an error, send coroutine_error
    if r1~=nil then
      os.queueEvent("coroutine_error",routine.name,r1)
    end    
    --send coroutine_end
    routine.dead=true
  --not dead, is it waiting for an event?
  else
    --"goroutine_listening" indicates it yielded via coroutine.waitForEvent
    --which has had filters set already
    if r1~="goroutine_listening" then
      --Add to eventListeners
      routine.filters={r1}
    end
  end
end

local function _spawn(name,method,redirect,parent,args)
    if activeRoutines[name] then
      return nil, "Couldn't spawn; a coroutine with that name already exists!"
    end
    
    local routine={name=name,co=coroutine.create(method),redirect={redirect}, parent=parent,children={}}
    if routine.co==nil then
      error("Failed to create coroutine '"..name.."'!")
    end
    parent.children[#parent.children+1]=routine
    activeRoutines[name]=routine
    os.queueEvent("coroutine_start",name)


    numActiveCoroutines=numActiveCoroutines+1
    --run it a bit..
    sendEventTo(routine,args)
        
    return routine
end

function spawnWithRedirect(name,method,redirect,...)
  return _spawn(name,method,redirect,running(),{...})
end

local mon=peripheral.wrap("right")

function spawn(name,method,...)
  local cur=running()
  
  return _spawn(name,method,cur.redirect[1],cur,{...})
end

local nilRedir = {
  write = function() end,
  getCursorPos = function() return 1,1 end,
  setCursorPos = function() end,
  isColor = function() return false end,
  scroll = function() end,
  setCursorBlink = function() end,
  setTextColor = function() end,
  getTextColor = function() end,
  getTextSize = function() end,
  setTextScale = function() end,
  clear = function() end,
  clearLine = function() end,
  getSize = function() return 51,19 end,
}

function spawnBackground(name,method,...)
  return _spawn(name,method,nilRedir,rootRoutine,{...})
end

function spawnPeer(name,method,...)
  local cur=running()
  return _spawn(name,method,cur.redirect[1],cur.parent,{...})
end

function spawnPeerWithRedirect(name,method,redirect,...)
  local cur=running()
  return _spawn(name,method,redirect,cur.parent,{...})
end

function spawnProgram(name,progName,...)
  local cur=running()
  return _spawn(name, function(...) os.run({}, ...) end,cur.redirect[1],cur,{...})
end


function list()
  local l={}
  local i=1
  for name,_ in pairs(activeRoutines) do
    l[i]=name
    i=i+1
  end
  return l
end

function kill(name)
  local routine=validateCaller("killCoroutine")
  if not routine then
    return false, "Must be called from a coroutine. How'd you even manage this?"
  end
  local target=findNamedCoroutine(name)
  if target then
    if routine==target then
      return false,"You can't commit suicide!"
    end
    --mark it dead
    target.dead=true
    return true
  end
  return false, "coroutine not found"
end


local function logCoroutineErrors()
  while true do
    local _, name, err=os.pullEventRaw("coroutine_error")
    if _~="terminate" then
      local file=fs.open("go.log","a")
      file.write("coroutine '"..tostring(name).."' crashed with the following error: "..tostring(err).."\n")
      file.close()
    end
  end
end

function run(main,terminable,...)
  if isRunning then
    --spawn it
    local cur=running()
    local name="main"
    local i=1
    while activeRoutines[name] do
      i=i+1
      name="main"..i
    end
    if _spawn(name,main,cur.redirect[1],cur,{...}) then
      --wait for it to die
      while true do 
        local e={os.pullEventRaw()}
        if e[1]=="coroutine_end" and e[2]==name then
          return
        elseif e[1]=="coroutine_error" and e[2]==name then
          error(e[3])
          return  
        end
      end
    else
      error("Couldn't spawn main coroutine "..name.."!")
    end
    
  end
  
  --hook term.redirect and term.restore
  local function term_redirect(target)
    --push redirect to current term's stack
    local co=running()
    co.redirect[#co.redirect+1]=target
    --undo the current redirection then redirect
    termNative.restore()
    termNative.redirect(target)
  end

  local function term_restore()
    local co=running()
    --do nothing unless they've got more than 1 redirect in their stack
    if #co.redirect>1 then
      table.remove(co.redirect,#co.redirect)
      --undo current redirection and restore to new end of stack
      termNative.restore()
      termNative.redirect(co.redirect[#co.redirect])
    end
  end

  termNative.redirect=term.redirect
  termNative.restore=term.restore
  term.redirect=term_redirect
  term.restore=term_restore
  
    
  --make the object for the root coroutine (this one)
  rootRoutine={
    co=coroutine.running(),
    name="root",
    redirect={term.native},
    parent=nil,   
    children={}
  }
  
  isRunning=true
  --default terminable to true
  if terminable==nil then 
    terminable=true 
  end
  
  --start the main coroutine for the process
  entryRoutine=_spawn("main",main,term.native,rootRoutine,{...})
  --begin with routine 1
  --gooo!
  local params={}
  while numActiveCoroutines>0 do      
    --grab an event
    params={os.pullEventRaw()}
    if terminable and params[1]=="terminate" then  
      gotTerminate=true
    end
    local assigned=eventAssignments[params[1]]~=nil
    local assignedTo=assigned and eventAssignments[params[1]].co or nil
    local alreadyHandledBy={}
    --set passTo to empty string, meaning anyone listening
    passEventTo=""
    while assignedTo~=nil do
      --set this to nil first
      passEventTo=nil
      --send to assigned guy, if he matches, else break
      if matchFilters(params,assignedTo) then
        sendEventTo(assignedTo,params)
      else
        passEventTo=""
        break
      end
      --add him to the list of guys who've handled this already
      alreadyHandledBy[assignedTo]=true
      --set assignedTo to whatever passTo was
      if passEventTo=="" then
        assignedTo=nil
      elseif passEventTo~=nil then
        assignedTo=findNamedCoroutine(passEventTo)
      else
        assignedTo=nil
      end
    end
    --if it was assigned to nobody, or they passed to everybody..
    if passEventTo=="" then
      for _,routine in pairs(activeRoutines) do
        --if they haven't handled it already via assignments above..
        if not alreadyHandledBy[routine] and not routine.dead then
          local match=matchFilters(params,routine)
          --if it matched, or this routine has never run...
          if match then
            sendEventTo(routine,params)
          end        
        end
      end
    end
    --clean up any dead coroutines
    local dead={}
    local function listChildren(routine,list)
      for i=1,#routine.children do
        if not routine.children[i].dead then
          list[routine.children[i].name]=routine.children[i]
          listChildren(routine.children[i],list)
        end
      end
    end
    for name,routine in pairs(activeRoutines) do
      if routine.dead then
        dead[name]=routine
        listChildren(routine,dead)
      end
    end
    for name,routine in pairs(dead) do
      os.queueEvent("coroutine_end",routine.name)
      activeRoutines[name]=nil
      numActiveCoroutines=numActiveCoroutines-1
      local parent=routine.parent
      if not parent.dead then
        --find and remove from children
        for i=1,#parent.children do
          if parent.children[i]==routine then
            table.remove(parent.children,i)
            break
          end
        end
      end
    end
    
    --release all events assigned to dead coroutines
    local remove={}
    for k,v in pairs(eventAssignments) do      
      if dead[eventAssignments[k].co.name] then
        table.insert(remove,k)
      end
    end
    
    for i=1,#remove do
      eventAssignments[remove[i]]=nil
    end
  end
  
  --Should I send every remaining process a terminate event, regardless 
  --of what they were waiting on, so they can do cleanup? Could cause
  --errors in some cases...
  --[[
  for k,v in activeRoutines do
    coroutine.resume(v.co,"terminate")
  end
  --]]
  
  activeRoutines={}
  eventAssignments = { }
  passEventTo=nil
  entryRoutine=nil  
  rootRoutine=nil
  isRunning=false

  --remove hooks from term.redirect and .restore
  term.redirect=termNative.redirect
  term.restore=termNative.restore
  
end

function launch(sh)
  if not active then
    active=true
    sh=sh or "rom/programs/shell"
    term.clear()
    term.setCursorPos(1,1)
    run(
      function() 
        spawnBackground("errLogger",logCoroutineErrors)
        os.run({},sh)
      end
    )
    os.shutdown()
  end
end