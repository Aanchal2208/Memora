-- SessionHistoryResponsePlugin
-- Kong plugin for testing response capture after ai-proxy-advanced

local uuid = require "resty.jit-uuid"
local cjson = require "cjson"

local mongo_utils = require "kong.plugins.session-history-response-plugin.utils.mongo_utils"
local array_utils = require "kong.plugins.session-history-response-plugin.utils.array_utils"
local session_manager = require "kong.plugins.session-history-response-plugin.utils.session_manager"

uuid.seed()

local SessionHistoryResponsePlugin = {
  VERSION  = "0.8.0",
  PRIORITY = 200,  -- Low priority = runs after ai-proxy-advanced
}

function SessionHistoryResponsePlugin:header_filter(conf)
  local path = kong.request.get_path()
  if path:match(".*/create%-session$") and kong.ctx.shared.process_response then
    kong.response.set_status(200)
    kong.response.set_header("Content-Type", "application/json")
    kong.response.clear_header("Content-Length")
  end
end

function SessionHistoryResponsePlugin:body_filter(conf)
  session_manager.log_debug("SessionHistoryResponsePlugin body_filter running with priority 200", nil)
  local path = kong.request.get_path()
  local chunk, eof = ngx.arg[1], ngx.arg[2]
  
  local ctx = kong.ctx.plugin
  if not ctx.response_body then
    ctx.response_body = ""
  end
  
  if chunk then
    ctx.response_body = ctx.response_body .. chunk
  end
  
  if eof then
    session_manager.log_debug("Complete AI response received", nil)
    session_manager.log_debug("Response body length: ", #ctx.response_body)
    session_manager.log_debug("Response body: ", ctx.response_body)

    local ok, response_data = pcall(cjson.decode, ctx.response_body)
    if not ok or not response_data then
      session_manager.log_error("DEBUG: error - cannot decode response body")
      return 
    end

    if path:match(".*/create%-session$") and kong.ctx.shared.process_response then
      local system_prompt = kong.ctx.shared.system_prompt
      local sys_prompt_tokens = response_data.usage.prompt_tokens

      session_manager.log_debug("system prompt tokens: ", sys_prompt_tokens)

      local initial_messages = {
        {
          role = "system", 
          content = system_prompt,
          tokens = sys_prompt_tokens,
          is_summary = false
        }
      }

      local session_doc = {
        session_id = kong.ctx.shared.client_uuid,
        created_at = os.time(),
        updated_at = os.time(),
        path = path,
        system_prompt = system_prompt,
        messages = initial_messages,  -- OpenAI format messages array
        system_prompt_tokens = sys_prompt_tokens,
        total_tokens = sys_prompt_tokens,
        session_history_depth = kong.ctx.shared.session_history_depth,
        session_life = kong.ctx.shared.session_life
      }

      local ok, err = ngx.timer.at(0, mongo_utils.save_to_mongo, conf, kong.ctx.shared.client_uuid, session_doc, "creation")
      if not ok then
        session_manager.log_error("failed to schedule save for create session object: ", err)
      end 
    
      local custom_response = {
        session_id = kong.ctx.shared.client_uuid
      }
      ngx.arg[1] = cjson.encode(custom_response)
      
    else
      -- For other paths, pass through original response
      ngx.arg[1] = ctx.response_body
    end

  else
    -- Clear chunks while buffering
    ngx.arg[1] = nil
  end
end


-- log phase
function SessionHistoryResponsePlugin:log(conf)
  local path = kong.request.get_path()
  if path:match(".*/create%-session$") then
    session_manager.log_debug("Skipping log phase for create-session path", nil)
    return
  end

  local client_uuid = kong.ctx.shared.client_uuid
  if not client_uuid then
    session_manager.log_error("No client UUID found in context", nil)
    return
  end

  local response_body = kong.ctx.plugin.response_body
  local parsed, err = session_manager.parse_response(response_body)
  if not parsed then
    session_manager.log_error("Error parsing response body", err)
    return
  end

  local update_data, method = session_manager.build_update_data(path, parsed, conf, client_uuid)
  if not update_data then
    session_manager.log_error("Path did not match summarise or ask", nil)
    return
  end

  local ok, timer_err = ngx.timer.at(0, mongo_utils.save_to_mongo, conf, client_uuid, update_data, method)
  if ok then
    session_manager.log_debug("AI proxy response scheduled for MongoDB save", nil)
  else
    session_manager.log_error("Failed to schedule AI proxy response save", timer_err)
  end
end

return SessionHistoryResponsePlugin