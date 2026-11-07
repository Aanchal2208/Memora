local mongo = require "mongo"
local cjson = require "cjson"

local _M = {}

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

-- Extracts response data from raw JSON
function _M.parse_response(response_body)
  if not response_body or response_body == "" then
    return nil, "Empty response body"
  end

  local ok, response_data = pcall(cjson.decode, response_body)
  if not ok or not response_data then
    return nil, "Failed to decode JSON"
  end

  -- Check for OpenAI format
  if not (response_data.choices and #response_data.choices > 0) then
    return nil, "Not a valid response"
  end

  local choice = response_data.choices[1]
  local response_tokens = response_data.usage and response_data.usage.completion_tokens or 0

  local content_text = ""
  if choice.message and choice.message.content then
    content_text = choice.message.content
  end

  if content_text == "" then
    return nil, "No text in response"
  end

  return {
    response_data = response_data,
    content_text = content_text,
    response_tokens = response_tokens
  }, nil
end

-- Build MongoDB update data depending on path type
function _M.build_update_data(path, parsed, conf, client_uuid)
  local response_data = parsed.response_data
  local response_tokens = parsed.response_tokens
  local content_text   = parsed.content_text

  local update_data, method

  if path:match(".*/distill%-session$") then
    local summarised_total_tokens = response_tokens + (kong.ctx.shared.tokens_to_include or 0)
    local new_messages = kong.ctx.shared.messages_to_include or {}

    table.insert(new_messages, {
      role = "user",
      content = content_text,
      tokens = response_tokens,
      is_summary = true
    })

    update_data = {
      messages = new_messages,
      updated_at = os.time(),
      path = path,
      total_tokens = summarised_total_tokens
    }
    method = "update_with_summary"

  elseif path:match(".*/ask$") then
    local total_prompt_tokens = response_data.usage and response_data.usage.prompt_tokens or 0
    local total_tokens_new = response_data.usage and response_data.usage.total_tokens or 0

    if kong.ctx.shared.new_user_message then
      kong.ctx.shared.new_user_message.tokens = total_prompt_tokens - (kong.ctx.shared.total_tokens_curr or 0)
    end

    local assistant_message = {
      role = "assistant",
      content = content_text,
      tokens = response_tokens, 
      is_summary = false
    }

    _M.log_debug("Extracted assistant message", assistant_message)

    update_data = {
      messages = {
        kong.ctx.shared.new_user_message,
        assistant_message
      },
      updated_at = os.time(),
      path = path,
      total_tokens = total_tokens_new
    }
    method = "update"
  end

  return update_data, method
end

return _M