-- test without jit
-- jit.off()

AddCSLuaFile()

if SERVER and not yava then
    local old_CleanUpMap = game.CleanUpMap
    function game.CleanUpMap( dontSendToClients, extraFilters )
        extraFilters = extraFilters or {}
        table.insert(extraFilters, "yava_chunk")
        old_CleanUpMap( dontSendToClients, extraFilters)
    end
end

yava = yava or {}

do -- CONSTANTS
    yava.FACE_NONE = 0
    yava.FACE_TRANSPARENT = 1
    yava.FACE_TRANSPARENT_NOCULL = 2
    yava.FACE_OPAQUE = 3
end

if CLIENT then
    if render.MaxTextureHeight()<4096 then
        ErrorNoHalt("YAVA: Your GPU does not support large enough textures for the atlas: "..render.MaxTextureHeight().."\n")
    end
end

yava.currentConfig = yava.currentConfig or {}

function yava.init(config)

    if not config and yava.currentConfig then
        config = yava.currentConfig
    else
        config = config or {}
        yava.currentConfig = config
        
        local function setDefault(key,value)
            if config[key] ~= nil then return end
            config[key] = value
        end

        setDefault("basePos", Vector(-12800,-12800,-12800))
        setDefault("chunkDimensions", Vector(20,20,20))
        setDefault("blockScale", 40)
        setDefault("generator", function() return "void" end)
        setDefault("imageDir", ".")
    end

    if SERVER then    
        yava._offset = config.basePos
        yava._scale = config.blockScale
    end

    yava._generator = config.generator

    yava._imageDir = config.imageDir

    yava._saveDir = config.saveDir

    -- reset chunks
    yava._chunks = {}
    yava._stale_chunk_set = {}

    if CLIENT then
        timer.Simple(0,function()
            yava._buildAtlas()
        end)
    else
        -- Kill old chunk colliders
        for _, ent in pairs( ents.FindByClass( "yava_chunk" ) ) do
            ent:Remove()
        end

        if config.loadFile then
            yava._load(config.loadFile)
        else
            yava._buildChunks( config.chunkDimensions )
        end
        
        yava._clients = {}
        for _,ply in pairs(player.GetHumans()) do
            yava._addClient(ply)
        end
    end

    yava._isSetup = true
end


if CLIENT then

    function yava._buildAtlas()
        local pointSample = true
        local atlas_texture = GetRenderTargetEx("__yava_atlas",32,4096,
            RT_SIZE_NO_CHANGE,MATERIAL_RT_DEPTH_NONE,pointSample and 1 or 0,CREATERENDERTARGETFLAGS_AUTOMIPMAP,IMAGE_FORMAT_RGBA8888)

        render.PushRenderTarget(atlas_texture)
        cam.Start2D()

        local imgDir = yava._imageDir

        render.Clear(0,0,0,255)
        surface.SetDrawColor(255,255,255,255)
        for i=1,#yava._images do
            local name = yava._images[i]
            local source = Material(imgDir.."/"..name..".png")

            surface.SetMaterial(source)
            surface.DrawTexturedRectUV( 0,(i-1)*64,      16,16,     0,0,1,0.015625)
            surface.DrawTexturedRect(   0,(i-1)*64+16,   32,32)
            surface.DrawTexturedRectUV( 0,(i-1)*64+48,   32,16,     0,0.984375,1,1)
        end

        cam.End2D()
        render.PopRenderTarget()

        yava._atlas = CreateMaterial("__yava_atlas", "VertexLitGeneric")
        yava._atlas:SetTexture("$basetexture",atlas_texture)

        yava._atlas_screen = CreateMaterial("__yava_atlas_screen", "UnlitGeneric")
        yava._atlas_screen:SetTexture("$basetexture",atlas_texture)
    end
end

function yava._chunkKey(x,y,z)
    return x+y*1024+z*1048576
end

if SERVER then
    function yava._buildChunks(dims)
        local t1 = SysTime()
        for z=0,dims.z-1 do
            for y=0,dims.y-1 do
                for x=0,dims.x-1 do
                    local consumer, chunk = yava._chunkConsumerConstruct(x,y,z)
                    yava._chunkProvideGenerate(x,y,z,consumer)

                    yava._chunks[yava._chunkKey(x,y,z)] = chunk
                    yava._stale_chunk_set[chunk] = true
                end
            end
        end

        local sum = 0
        for _,chunk in pairs(yava._chunks) do
            sum = sum + #chunk.block_data
        end
        print("Worldgen: ",SysTime()-t1)
    end

    function yava.save(filename)
        local save_dir = "yava/"

        if yava._saveDir then
            save_dir = save_dir..yava._saveDir.."/"
        end

        file.CreateDir(save_dir)

        if not filename then
            filename = os.date("~autosave_%Y-%m-%d_%H-%M-%S")
        end

        filename = save_dir..filename..".yava.dat"
        
        local file = file.Open(filename, "wb", "DATA")
        file:Write("YAVA1\n")
        
        -- Write block types
        file:WriteUShort(#yava._blockTypes)
        for i=1,#yava._blockTypes do
            file:Write(yava._blockTypes[i].."\n")
        end

        -- Write Scale
        file:WriteFloat(yava._scale)
        
        -- Write chunk count
        local chunk_count = 0
        for k,v in pairs(yava._chunks) do
            chunk_count = chunk_count+1
        end
        file:WriteUShort(chunk_count)

        -- Write individual chunks
        for _,chunk in pairs(yava._chunks) do
            file:WriteUShort(chunk.x)
            file:WriteUShort(chunk.y)
            file:WriteUShort(chunk.z)

            yava._chunkProvideChunk(chunk,function(type,count)
                file:WriteUShort(type)
                file:WriteUShort(count)
            end)
        end
        
        file:Close()

        print("Saved:",filename)
    end

    function yava._load(filename)
        local load_dir = "yava/"

        if yava._saveDir then
            load_dir = load_dir..yava._saveDir.."/"
        end

        filename = load_dir..filename..".yava.dat"

        local file = file.Open(filename, "rb", "DATA")

        assert(file:ReadLine() == "YAVA1\n")

        local save_block_lut = {}
        for save_id=0,file:ReadUShort()-1 do
            local save_name = file:ReadLine()
            save_name = save_name:sub(1,#save_name-1)

            save_block_lut[save_id] = yava._blockTypes[save_name] or 1
        end

        yava._scale = file:ReadFloat()

        local chunk_count = file:ReadUShort()

        for chunk_i=1,chunk_count do
            local x = file:ReadUShort()
            local y = file:ReadUShort()
            local z = file:ReadUShort()

            local consumer, chunk = yava._chunkConsumerConstruct(x,y,z)

            local total_count = 0
            while total_count < 32768 do
                local type = file:ReadUShort()
                local count = file:ReadUShort()

                consumer(save_block_lut[type],count)
                total_count = total_count + count
            end

            yava._chunks[yava._chunkKey(x,y,z)] = chunk
            yava._stale_chunk_set[chunk] = true
        end

        file:Close()

        print("Loaded:",filename)
    end
end

local nul_table = {}
local mesh_time = 0

function yava._updateChunks()
    local chunk = next(yava._stale_chunk_set)
    if not chunk then return false end
    
    local t_start = SysTime()

    -- do this early so we can recover from chunks that fail to mesh right
    yava._stale_chunk_set[chunk] = nil

    local cnx = yava._chunks[yava._chunkKey(chunk.x+1,chunk.y,chunk.z)] or nul_table
    local cny = yava._chunks[yava._chunkKey(chunk.x,chunk.y+1,chunk.z)] or nul_table
    local cnz = yava._chunks[yava._chunkKey(chunk.x,chunk.y,chunk.z+1)] or nul_table

    -- visual mesh
    if CLIENT then
        chunk.mesh = yava._chunkGenMesh(chunk.block_data,chunk.x,chunk.y,chunk.z,cnx.block_data,cny.block_data,cnz.block_data)
    end

    -- physical mesh
    do
        local soup = yava._chunkGenPhysics_dirtySoup(chunk.block_data,chunk.x,chunk.y,chunk.z,cnx.block_data,cny.block_data,cnz.block_data)

        local collider_ent
        if IsValid(chunk.collider_ent) then
            collider_ent = chunk.collider_ent
        end

        if soup then

            if SERVER then
                if not collider_ent then
                    collider_ent = ents.Create("yava_chunk")
                    collider_ent:SetChunkPos(Vector(chunk.x,chunk.y,chunk.z))
                    collider_ent:Spawn()
                    
                    chunk.collider_ent = collider_ent
                end
                
                collider_ent:SetupCollisions(soup)
            else
                if collider_ent then
                    collider_ent:SetupCollisions(soup)
                else
                    chunk.fresh_collider_soup = soup
                end
            end
        else
            if collider_ent then
                if SERVER then
                    collider_ent:Remove()
                end
            end
        end
    end

    mesh_time = mesh_time + (SysTime()-t_start)
    --print(string.format("%.5s",mesh_time))

    return true
end

-- maps (name -> id) and (id+1 -> name)
yava._blockTypes = yava._blockTypes or {}
-- each subtable maps (id+1 -> data)
if CLIENT then
    yava._blockFaceImages = {{},{},{},{},{},{}}
    yava._blockFaceTypes = {{},{},{},{},{},{}}
    -- maps (name -> index) and (index -> name)
    yava._images = {}
end

yava._blockSolidity = {}

local next_block_id = 0
function yava.addBlockType(name,settings)
    if yava._isSetup then error("Cannot add block types after init.") end
    settings = settings or {}

    local block_id = #yava._blockTypes

    yava._blockTypes[block_id+1] = name
    yava._blockTypes[name] = block_id
    
    if CLIENT then
        local defaultImage = settings.faceImage or name
        local imageTable = {
            settings.rightImage or defaultImage,
            settings.backImage or defaultImage,
            settings.topImage or defaultImage,
            settings.leftImage or defaultImage,
            settings.frontImage or defaultImage,
            settings.bottomImage or defaultImage
        }
        
        local defaultType = settings.faceType or yava.FACE_OPAQUE
        local typeTable = {
            settings.rightType or defaultType,
            settings.backType or defaultType,
            settings.topType or defaultType,
            settings.leftType or defaultType,
            settings.frontType or defaultType,
            settings.bottomType or defaultType
        }
        
        for i,img_name in pairs(imageTable) do
            if not yava._images[img_name] and typeTable[i] ~= 0 then
                local img_id = #yava._images+1
                yava._images[img_id] = img_name
                yava._images[img_name] = img_id
            end
        end
        
        for i=1,6 do
            yava._blockFaceImages[i][block_id+1] = yava._images[imageTable[i]] or 0
            yava._blockFaceTypes[i][block_id+1] = typeTable[i]
        end
    end

    local solid = settings.solid
    if solid == nil then solid = true end

    yava._blockSolidity[block_id+1] = solid
end

if #yava._blockTypes == 0 then
    yava.addBlockType("void",{faceType = yava.FACE_NONE, solid = false})
end

include("yava_lib_chunk.lua")

hook.Add("Think","yava_update",function()
    local start = SysTime()
    
    for i=1,1000 do
        local t = SysTime()-start
        if not yava._updateChunks() then break end
        if CLIENT and t>.005 then break end
    end
    
    if SERVER then
        yava._sendChunks()
    end
end)

local chunk_bits = 0
local chunk_time = 0

if CLIENT then
    net.Receive("yava_init", function()
        yava._offset = net.ReadVector()
        yava._scale = net.ReadFloat()

        yava._vmatrix = Matrix()
        yava._vmatrix:Translate( yava._offset )
        yava._vmatrix:Scale( Vector( 1, 1, 1 ) * yava._scale )

        -- reset chunks
        yava._chunks = {}
        yava._stale_chunk_set = {}
    end)


	-- TODO: disable in skybox, etc
    hook.Add("PostDrawOpaqueRenderables","yava_render",function()
        
        if not yava._vmatrix then return end
        
        
	render.SuppressEngineLighting(true) 
    	render.SetLightingOrigin( Vector(0,0,0) )
	render.ResetModelLighting( 0,0,0 )
	render.SetColorModulation( 0,0,0 )
	render.SetBlend( 1 )
			
        render.SetModelLighting(BOX_TOP,    1,1,1 )
        render.SetModelLighting(BOX_FRONT,  .8,.8,.8 )
        render.SetModelLighting(BOX_RIGHT,  .6,.6,.6 )
        render.SetModelLighting(BOX_LEFT,   .5,.5,.5 )
        render.SetModelLighting(BOX_BACK,   .3,.3,.3 )
        render.SetModelLighting(BOX_BOTTOM, .1,.1,.1 )
        
        if yava._atlas then
            render.SetMaterial( yava._atlas )
        end

        cam.PushModelMatrix( yava._vmatrix )
        for _,chunk in pairs(yava._chunks) do
            if chunk.mesh then
                chunk.mesh:Draw()
            end
        end
        cam.PopModelMatrix()

        render.SuppressEngineLighting(false) 
    end)

    local rx_chunk_count = 0
    net.Receive("yava_chunk_blocks", function(bits)
        local t = SysTime()
        
        local chunk = yava._chunkNetworkPP3D_recv(bits)
        local x = chunk.x
        local y = chunk.y
        local z = chunk.z
        yava._chunks[yava._chunkKey(x,y,z)] = chunk
        yava._stale_chunk_set[chunk] = true

        local next_chunk = yava._chunks[yava._chunkKey(x-1,y,z)]
        if next_chunk then yava._stale_chunk_set[next_chunk] = true end
        local next_chunk = yava._chunks[yava._chunkKey(x,y-1,z)]
        if next_chunk then yava._stale_chunk_set[next_chunk] = true end
        local next_chunk = yava._chunks[yava._chunkKey(x,y,z-1)]
        if next_chunk then yava._stale_chunk_set[next_chunk] = true end
        
        chunk_bits = chunk_bits + bits
        chunk_time = chunk_time + (SysTime()-t)
        --print(chunk_bits,chunk_time)
    end)
else
    util.AddNetworkString("yava_init")
    util.AddNetworkString("yava_chunk_blocks")
    --util.AddNetworkString("yava_chunk_blocks_ack")
    util.AddNetworkString("yava_block")
    util.AddNetworkString("yava_sphere")
    util.AddNetworkString("yava_region")



    hook.Add("PlayerInitialSpawn","yava_player_join",function(ply)
        yava._addClient(ply)
    end)

    function yava._addClient(ply)
        if yava._clients[ply] then return end

        
        local info = {chunks={},last_send=CurTime()}
        for _,chunk in pairs(yava._chunks) do
            info.chunks[chunk] = true
        end
        
        yava._clients[ply] = info

        net.Start("yava_init")
        net.WriteVector(yava._offset)
        net.WriteFloat(yava._scale)
        net.Send(ply)
    end

    local bytes_per_second = 100000 -- 100 KB/S

    function yava._sendChunks()

        local removed_clients = {}

        for client, client_info in pairs(yava._clients) do

            if not IsValid(client) then table.insert(removed_clients,client) continue end

            local now = CurTime()
            local delta = now - client_info.last_send

            client_info.last_send = now

            local byte_limit = delta*bytes_per_second
            local bytes = 0


            for i=1,100 do

                local chunk = next(client_info.chunks)
                
                if chunk == nil then table.insert(removed_clients,client) break end
                client_info.chunks[chunk] = nil
                
                -- send the chunk

                local t = SysTime()
                net.Start("yava_chunk_blocks")
                
                yava._chunkNetworkPP3D_send(chunk)

                bytes = bytes + net.BytesWritten()

                net.Send(client)

                chunk_time = chunk_time + (SysTime()-t)

                if bytes > byte_limit then
                    break
                end
            end

        end
        
        -- prune client table
        for _,client in pairs(removed_clients) do
            yava._clients[client] = nil
        end
    end

    --[[net.Receive("yava_chunk_blocks_ack", function(len,ply)
        local x = net.ReadUInt(16)
        local y = net.ReadUInt(16)
        local z = net.ReadUInt(16)

        local client_info = yava._clients[ply]
        local chunk = yava._chunks[yava._chunkKey(x,y,z)]

        if client_info and chunk then
            if client_info.chunks[chunk] ~= nil then
                client_info.chunks[chunk] = nil
                client_info.send_count = client_info.send_count + 1
                client_info.chunks_left = client_info.chunks_left - 1
                --print("ACK",client_info.send_count,client_info.chunks_left)
            end
        end
    end)]]
end

-- setBlock crap
do
    local function set_block(x,y,z,v,quick_and_dirty)
        local cx = math.floor(x/32)
        local cy = math.floor(y/32)
        local cz = math.floor(z/32)
        local lx = x%32
        local ly = y%32
        local lz = z%32
        
        local chunk = yava._chunks[yava._chunkKey(cx,cy,cz)]
        
        if chunk and v then
            yava._chunkSetBlock(chunk.block_data,lx,ly,lz,v)
            
            if quick_and_dirty then return end -- chunk updates and networking are someone elses problem

            yava._stale_chunk_set[chunk] = true
            
            if lx==0 then
                local next_chunk = yava._chunks[yava._chunkKey(cx-1,cy,cz)]
                if next_chunk then yava._stale_chunk_set[next_chunk] = true end
            end
            if ly==0 then
                local next_chunk = yava._chunks[yava._chunkKey(cx,cy-1,cz)]
                if next_chunk then yava._stale_chunk_set[next_chunk] = true end
            end
            if lz==0 then
                local next_chunk = yava._chunks[yava._chunkKey(cx,cy,cz-1)]
                if next_chunk then yava._stale_chunk_set[next_chunk] = true end
            end

            if SERVER then
                net.Start("yava_block")
                net.WriteInt(x,16) 
                net.WriteInt(y,16)
                net.WriteInt(z,16)
                net.WriteUInt(v,16)
                net.Broadcast() 
            end
        end
    end

    local function flag_region(x_low,y_low,z_low,x_high,y_high,z_high)
        local cx1 = math.floor(x_low/32)
        local cy1 = math.floor(y_low/32)
        local cz1 = math.floor(z_low/32)

        if x_low%32 == 0 then cx1=cx1-1 end
        if y_low%32 == 0 then cy1=cy1-1 end
        if z_low%32 == 0 then cz1=cz1-1 end

        local cx2 = math.floor(x_high/32)
        local cy2 = math.floor(y_high/32)
        local cz2 = math.floor(z_high/32)

        for z=cz1,cz2 do
            for y=cy1,cy2 do
                for x=cx1,cx2 do
                    local chunk = yava._chunks[yava._chunkKey(x,y,z)]
                    if chunk then yava._stale_chunk_set[chunk] = true end
                end
            end
        end
    end

    local function set_sphere(x,y,z,r,v)
        if v then
            for iz=z-r,z+r do
                for iy=y-r,y+r do
                    for ix=x-r,x+r do
                        if (x-ix)^2 + (y-iy)^2 + (z-iz)^2 <= r*r then
                            set_block(ix,iy,iz,v,true)
                        end
                    end
                end
            end

            flag_region(x-r,y-r,z-r,x+r,y+r,z+r)

            if SERVER then
                net.Start("yava_sphere")
                net.WriteInt(x,16) 
                net.WriteInt(y,16)
                net.WriteInt(z,16)
                net.WriteUInt(r,16)            
                net.WriteUInt(v,16)
                net.Broadcast() 
            end
        end
    end

    local function set_region(x1,y1,z1,x2,y2,z2,v)
        if v then
            local x_low = math.min(x1,x2)
            local y_low = math.min(y1,y2)
            local z_low = math.min(z1,z2)

            local x_high = math.max(x1,x2)
            local y_high = math.max(y1,y2)
            local z_high = math.max(z1,z2)
            
            for iz=z_low,z_high do
                for iy=y_low,y_high do
                    for ix=x_low,x_high do
                        set_block(ix,iy,iz,v,true)
                    end
                end
            end

            flag_region(x_low,y_low,z_low,x_high,y_high,z_high)

            if SERVER then
                net.Start("yava_region")
                net.WriteInt(x1,16) 
                net.WriteInt(y1,16)
                net.WriteInt(z1,16)
                net.WriteInt(x2,16)
                net.WriteInt(y2,16)
                net.WriteInt(z2,16)
                net.WriteUInt(v,16)
                net.Broadcast()
            end
        end
    end

    if SERVER then
        yava.setBlock = function(x,y,z,type)
            local v = yava._blockTypes[type]
            set_block(x,y,z,v)
        end

        yava.setSphere = function(x,y,z,r,type)
            local v = yava._blockTypes[type]
            set_sphere(x,y,z,r,v)
        end

        yava.setRegion = function(x1,y1,z1,x2,y2,z2,type)
            local v = yava._blockTypes[type]
            set_region(x1,y1,z1,x2,y2,z2,v)
        end
    else
        net.Receive("yava_block", function(bitlen)
            local x = net.ReadInt(16)
            local y = net.ReadInt(16)
            local z = net.ReadInt(16)
            local v = net.ReadUInt(16)
            
            set_block(x,y,z,v)
        end)

        net.Receive("yava_sphere", function(bitlen)
            local x = net.ReadInt(16)
            local y = net.ReadInt(16)
            local z = net.ReadInt(16)
            local r = net.ReadUInt(16)
            local v = net.ReadUInt(16)
            
            set_sphere(x,y,z,r,v)
        end)

        net.Receive("yava_region", function(bitlen)
            local x1 = net.ReadInt(16)
            local y1 = net.ReadInt(16)
            local z1 = net.ReadInt(16)
            local x2 = net.ReadInt(16)
            local y2 = net.ReadInt(16)
            local z2 = net.ReadInt(16)
            local v = net.ReadUInt(16)
            
            set_region(x1,y1,z1,x2,y2,z2,v)
        end)
    end
end

function yava.worldPosToBlockCoords(pos)
    local coords = (pos - yava._offset) / yava._scale
    return math.floor(coords.x), math.floor(coords.y), math.floor(coords.z)
end

function yava.worldDistToBlockCount(n)
    return math.floor(n / yava._scale)
end

-- Don't let players screw with our voxels!
hook.Add("PhysgunPickup", "yava_nophysgun", function(ply,ent)
	if ent:GetClass() == "yava_chunk" then return false end
end)

hook.Add("CanTool", "yava_notool", function(ply,tr,tool)
	if IsValid(tr.Entity) and tr.Entity:GetClass() == "yava_chunk" then return false end
end)
