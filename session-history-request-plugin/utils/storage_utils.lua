-- kong/plugins/ai-state-plugin/mongo/storage_utils.lua
local mongo = require "mongo"
local cjson = require "cjson"

local storage_utils = {}

--
-- MongoDB connection
--
function storage_utils.get_mongo(conf)
  local uri = "mongodb://" .. conf.mongo_host .. ":" .. conf.mongo_port .. "/" .. conf.mongo_database
  if conf.mongo_username and conf.mongo_password then
    uri = "mongodb://" .. conf.mongo_username .. ":" .. conf.mongo_password ..
          "@" .. conf.mongo_host .. ":" .. conf.mongo_port .. "/" .. conf.mongo_database
  end

  kong.log.debug("Connecting to MongoDB with URI: ", uri)

  local client, err = mongo.Client(uri)
  if not client then
    kong.log.err("Mongo client init failed: ", err or "unknown")
    return nil, nil, "failed to connect " .. (err or "unknown")
  end

  local db = client:getDatabase(conf.mongo_database)
  if not db then
    kong.log.err("Mongo database init failed for: ", conf.mongo_database)
    return client, nil, "no database"
  end

  return client, db, nil
end

--
-- Array <-> MongoDB format conversions
--
function storage_utils.array_to_mongo(arr)
  if not arr or type(arr) ~= "table" then return {} end

  local mongo_obj = {}
  for i, item in ipairs(arr) do
    if item and type(item) == "table" then
      mongo_obj[tostring(i - 1)] = item
    end
  end
  return mongo_obj
end

function storage_utils.mongo_to_array(mongo_obj)
  if not mongo_obj or type(mongo_obj) ~= "table" then return {} end

  local arr, indices = {}, {}
  for k, _ in pairs(mongo_obj) do
    local num = tonumber(k)
    if num then table.insert(indices, num) end
  end
  table.sort(indices)

  for _, idx in ipairs(indices) do
    local item = mongo_obj[tostring(idx)]
    if item and type(item) == "table" then
      table.insert(arr, item)
    end
  end

  return arr
end

--
-- Save session data to MongoDB (older)
--
function storage_utils.save_to_mongo(premature, conf, client_uuid, entry, stage)
  if premature then return end

  local client, db, err = storage_utils.get_mongo(conf)
  if not db then
    kong.log.err("Mongo client/db not initialized: ", err)
    return
  end

  local col = db:getCollection(conf.mongo_collection or "sessions")
  if not col then
    kong.log.err("Mongo collection init failed: ", conf.mongo_collection)
    return
  end

  local filter, update = { session_id = client_uuid }, nil

  if stage == "creation" then
    local mongo_entry = {}
    for k, v in pairs(entry) do
      if k == "messages" then
        mongo_entry[k] = storage_utils.array_to_mongo(v)
      else
        mongo_entry[k] = v
      end
    end
    update = { ["$set"] = mongo_entry }

  elseif stage == "update_with_summary" then
    local summarised_messages = storage_utils.array_to_mongo(entry.messages)
    update = {
      ["$set"] = {
        messages = summarised_messages,
        updated_at = entry.updated_at,
        path = entry.path,
        total_tokens = entry.total_tokens
      }
    }

  else
    local existing_ok, existing_cursor = pcall(function()
      return col:find({ session_id = client_uuid })
    end)
    if not existing_ok or not existing_cursor then
      kong.log.err("Database query failed for session ", client_uuid)
      return
    end

    local existing_doc = existing_cursor:next()
    if not existing_doc then
      kong.log.err("Session not found in DB for update: ", client_uuid)
      return
    end

    local existing_parsed, parse_ok = {}, nil
    parse_ok, existing_parsed = pcall(cjson.decode, tostring(existing_doc))
    if not parse_ok then
      kong.log.err("Failed to parse existing doc JSON for session ", client_uuid)
      return
    end

    local existing_messages = existing_parsed.messages or {}
    for _, new_message in ipairs(entry.messages) do
      local next_index = 0
      for k, _ in pairs(existing_messages) do
        local num = tonumber(k)
        if num and num >= next_index then
          next_index = num + 1
        end
      end
      existing_messages[tostring(next_index)] = new_message
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

  local ok, res = pcall(function()
    return col:update(filter, update, { upsert = (stage == "creation") })
  end)

  if not ok then
    kong.log.err("MongoDB update failed for session ", client_uuid, ": ", res)
  else
    kong.log.notice("MongoDB update success: ", cjson.encode(res))
  end
end

return storage_utils