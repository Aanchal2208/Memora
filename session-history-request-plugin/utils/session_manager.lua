local mongo = require "mongo"
local cjson = require "cjson"

local _M = {}
function _M.get_existing_session(client_uuid, conf)
  -- Connect to Mongo
  local storage_utils = require "kong.plugins.session-history-request-plugin.utils.storage_utils"
  local client, db, err = storage_utils.get_mongo(conf)
  if not db then
    kong.log.err("Mongo connection failed in access phase: ", err)
    return nil, "Database unavailable"
  end

  -- get table with sessions
  local col = db:getCollection(conf.mongo_collection or "sessions")
  if not col then
    kong.log.err("Failed to get collection: ", conf.mongo_collection)
    return nil, "Database collection missing"
  end

  -- find the document where session_id is the same as one specified
  local ok, cursor = pcall(function()
    return col:find({ session_id = client_uuid })
  end)

  if not ok or not cursor then
    kong.log.err("Mongo find threw error for session ", client_uuid, ": ", cursor)
    return nil, "Database query failed"
  end

  local existing = cursor:next()

  if not existing then
    return nil, "Invalid or expired session"
  end

  local doc_string = tostring(existing)

  local doc_table = {}
  local ok, parsed = pcall(function()
    return cjson.decode(doc_string)
  end)

  if ok and parsed then
    kong.log.debug("Successfully parsed JSON")
    doc_table = parsed
  else
    kong.log.err("JSON parse failed, trying alternative methods")
    return nil, "Failed to parse session data"
  end

  kong.log.debug("DEBUG: Final converted table: ", cjson.encode(doc_table))
  return doc_table, nil
end

function _M.format_for_summarization(all_messages, first_non_summary_index, user_summary_prompt)
  if not all_messages or #all_messages <= 1 then
    kong.log.err("all messages format is incorrect.")
    return nil
  end

  local conversation_parts = {}

  -- Skip the first message (index 1) and process the rest
  for i = first_non_summary_index, #all_messages do
      local message = all_messages[i]
      if message.role and message.content then
          -- Format as "role: content" on one line
          table.insert(conversation_parts, message.role .. ": " .. message.content)
      end
  end

  local conversation_text = table.concat(conversation_parts, "\n")

  local base_summary_prompt = [[
    Please create a concise summary of the following conversation that will help me maintain context in future interactions.

    Include only the important information that should be remembered:
    - User's name and personal details they've shared
    - Facts, preferences, or context they've provided  
    - Ongoing topics, questions, or tasks
    - Key decisions or conclusions

    ALWAYS start with: "CONVERSATION SUMMARY: "

    Only include information that exists - do not mention what is missing or absent. Write as positive facts only.

    Example: "CONVERSATION SUMMARY: The user's name is John. He prefers morning meetings and is working on a Python project."

  ]]

  local summary_prompt = user_summary_prompt or base_summary_prompt

  summary_prompt = summary_prompt .. "\n\n"

  local final_prompt = summary_prompt .. conversation_text

  return final_prompt

end

function _M.check_session_length(all_messages, doc_table)
  local max_messages = doc_table.session_history_depth
  kong.log.debug("maximum amount of messages (without sys prompt): ", max_messages)

  local non_summary_count = 0
  local first_non_summary_index = nil
  local start_index = 1

  -- Skip system prompt if it exists - system prompts don't count toward session history depth
  if doc_table.system_prompt and doc_table.system_prompt ~= "" then
    start_index = 2  -- Start checking from index 2
  end

  -- Count non-summary messages and find first non-summary index
  for i = start_index, #all_messages do
    local message = all_messages[i]
    if message.is_summary == false and message.role == "user" then
      non_summary_count = non_summary_count + 1
      if first_non_summary_index == nil then
        first_non_summary_index = i
      end
    end
  end

  kong.log.debug("total messages in session: ", #all_messages)
  kong.log.debug("non-summary messages count: ", non_summary_count)
  kong.log.debug("first non-summary message index: ", first_non_summary_index or "none found")

  -- Check if we have too many non-summary messages
  if non_summary_count >= max_messages then
    kong.log.err("too many non-summary messages")
    return true, first_non_summary_index
  end

  return false, first_non_summary_index
end

function _M.check_timeout(doc_table)
  local start_time = doc_table.created_at
  local current_time = os.time()
  
  local minutes_since = (current_time - start_time) / 60

  if minutes_since > doc_table.session_life then
    return true
  else
    return false
  end
end

-- Utility logging functions to centralize logging format
function _M.log_debug(msg, data)
  if data ~= nil then
    if type(data) == "table" then
      local ok, json_str = pcall(cjson.encode, data)
      if ok then
        kong.log.debug(msg, " | data: ", json_str)
      else
        kong.log.debug(msg, " | (failed to encode table)")
      end
    else
      kong.log.debug(msg, " | data: ", tostring(data))
    end
  else
    kong.log.debug(msg)
  end
end

function _M.log_error(msg, data)
  if data ~= nil then
    kong.log.err(msg, " | error: ", tostring(data))
  else
    kong.log.err(msg)
  end
end

return _M