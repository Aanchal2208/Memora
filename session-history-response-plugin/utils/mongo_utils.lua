local mongo = require "mongo"
local cjson = require "cjson"

local _M = {}

-- Connect to MongoDB
function _M.get_mongo(conf)
  -- Build MongoDB URI
  local uri = "mongodb://" .. conf.mongo_host .. ":" .. conf.mongo_port .. "/" .. conf.mongo_database
  if conf.mongo_user and conf.mongo_password then
    uri = "mongodb://" .. conf.mongo_user .. ":" .. conf.mongo_password ..
          "@" .. conf.mongo_host .. ":" .. conf.mongo_port .. "/" .. conf.mongo_database
  end

  kong.log.debug("Connecting to MongoDB with URI: ", uri)

  -- Initialize MongoDB client
  local client, err = mongo.Client(uri)
  if not client then
    kong.log.err("Mongo client init failed: ", err or "unknown")
    return nil, nil, "failed to connect" .. (err or "unknown")
  end

  -- Get database handle
  local db = client:getDatabase(conf.mongo_database)
  if not db then
    kong.log.err("Mongo database init failed for: ", conf.mongo_database)
    return client, nil, "no database"
  end

  kong.log.debug("Mongo client and DB initialized successfully: ", conf.mongo_database)
  return client, db, nil
end

-- Save session data to MongoDB
function _M.save_to_mongo(premature, conf, client_uuid, entry, stage)
  -- Check if timer was cancelled, if so skip operation
  if premature then return end
  
  -- Connect to mongo db 
  local client, db, err = _M.get_mongo(conf)
  if not db then
      kong.log.err("Mongo client/db not initialized: ", err)
      return
  end
  
  -- Get collection handle
  local col = db:getCollection(conf.mongo_collection or "sessions")
  if not col then
      kong.log.err("Mongo collection init failed: ", conf.mongo_collection)
      return
  end

  local filter = { session_id = client_uuid }
  local update 
  local array_utils = require "kong.plugins.session-history-response-plugin.utils.array_utils"
  
  if stage == "creation" then 
    -- Convert messages array to MongoDB format before saving
    local mongo_entry = {}
    for k, v in pairs(entry) do
      if k == "messages" then
        mongo_entry[k] = array_utils.array_to_mongo(v)
      else
        mongo_entry[k] = v
      end
    end
    
    kong.log.debug("DEBUG: Creating document with data: ", cjson.encode(mongo_entry))
    
    update = {
      ["$set"] = mongo_entry
    }
  elseif stage == "update_with_summary" then
    kong.log.debug("Update with the summarised version.")
    local summarised_messages = array_utils.array_to_mongo(entry.messages)
    update = {
      ["$set"] = {
        messages = summarised_messages,
        updated_at = entry.updated_at,
        path = entry.path,
        total_tokens = entry.total_tokens
      }
    }
  else
    -- For updates, read the existing document first, then modify and replace
    kong.log.debug("DEBUG: Reading existing document for update...")
    
    local existing_ok, existing_cursor = pcall(function()
      return col:find({ session_id = client_uuid })
    end)

    if not existing_ok then
      kong.log.err("Database query failed for session ", client_uuid, ": ", existing_cursor)
      return -- Abort operation on database error
    end
    
    if not existing_cursor then
      kong.log.err("No cursor returned from database query for session ", client_uuid)
      return -- Abort operation
    end
    
    local existing_doc = existing_cursor:next()

    if not existing_doc then
      kong.log.err("Session not found in database for update: ", client_uuid, ". This indicates a data integrity issue.")
      return
    end

    kong.log.debug("Found existing document for update")
        
    -- Parse the existing document
    local existing_string = tostring(existing_doc)
    local existing_parsed = {}
    local parse_ok, parsed = pcall(cjson.decode, existing_string)
    
    if parse_ok and parsed then
      existing_parsed = parsed
    else
      kong.log.err("Failed to parse existing document JSON for session ", client_uuid)
      return -- Abort operation on parse error
    end
    
    -- Get existing messages (in MongoDB format) or empty object
    local existing_messages = existing_parsed.messages or {}
    
    -- Add the new messages
    for _, new_message in ipairs(entry.messages) do
      -- Find the next index for messages
      local next_index = 0
      for k, v in pairs(existing_messages) do
        local num = tonumber(k)
        if num and num >= next_index then
          next_index = num + 1
        end
      end
      
      -- Add the new message at the next index
      existing_messages[tostring(next_index)] = new_message
      kong.log.debug("Adding message at index ", next_index, ": ", cjson.encode(new_message))
    end
    
    update = {
      ["$set"] = {
        messages = existing_messages,
        updated_at = entry.updated_at,
        path = entry.path,
        total_tokens = entry.total_tokens
      }
    }
  end

  -- Protects against Lua errors during MongoDB operation
  local ok, res = pcall(function()
      return col:update(filter, update, { upsert = (stage == "creation") })
  end)

  if not ok then
      kong.log.err("MongoDB update failed for session ", client_uuid, ": ", res)
  else
      kong.log.notice("MongoDB update success: ", cjson.encode(res))
  end
end

return _M