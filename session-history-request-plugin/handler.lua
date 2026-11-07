local uuid = require "resty.jit-uuid"
local json = require "cjson"

-- In handler.lua
local storage_utils = require "kong.plugins.session-history-request-plugin.utils.storage_utils"
local session_manager = require "kong.plugins.session-history-request-plugin.utils.session_manager"

uuid.seed()

local SessionHistoryRequestPlugin = {
  VERSION  = "0.8.0",
  PRIORITY = 780, -- high priority runs before ai proxy advanced
}

-- access phase
function SessionHistoryRequestPlugin:access(conf)
    local path = kong.request.get_path()
    local client_uuid = nil
    local all_messages = {}

    -- to string is unnecessary, string fields are parsed as strings when kong parses JSON
    local function read_body_field(field)
        local body = kong.request.get_body()
        if body and type(body) == "table" then
            return body[field] or nil
        end
        return nil
    end

    local function create_session()
        local client_uuid = require "resty.jit-uuid"()
        local system_prompt = read_body_field("system_prompt") or ""
        local session_life = tonumber(read_body_field("session_life")) or 5256000
        local session_history_depth = tonumber(read_body_field("session_history_depth")) or 50

        if system_prompt == "" then
            local session_doc = {
                session_id = client_uuid,
                created_at = os.time(),
                updated_at = os.time(),
                path = path,
                system_prompt = "",
                messages = {},  -- OpenAI format messages array
                system_prompt_tokens = 0,
                total_tokens = 0,
                session_history_depth = session_history_depth,
                session_life = session_life
            }

            -- schedule asynchronous save 
            local ok, err = ngx.timer.at(0, storage_utils.save_to_mongo, conf, client_uuid, session_doc, "creation")
            if not ok then
                session_manager.log_error("failed to schedule save: ", err)
            end

            session_manager.log_debug("mongodb save successful")

            kong.response.set_header("X-AI-Session-Id", client_uuid)
            kong.ctx.shared.client_uuid = client_uuid
            kong.ctx.shared.process_response = false
            return kong.response.exit(200, { session_id = client_uuid })
        else
            kong.ctx.shared.process_response = true
            kong.ctx.shared.client_uuid = client_uuid
            kong.ctx.shared.system_prompt = system_prompt
            kong.ctx.shared.session_history_depth = session_history_depth
            kong.ctx.shared.session_life = session_life
            all_messages = {
                {
                    role = "system",
                    content = system_prompt
                },
                {
                    role = "user",
                    content = ""
                }
            }

            -- Prepare upstream request
            local upstream_body = {
                model = "gemini-1.5-flash",
                messages = all_messages
            }
            kong.service.request.set_body(upstream_body)
            kong.service.request.set_header("Content-Type", "application/json")
            kong.response.set_header("X-AI-Session-Id", client_uuid)
            kong.service.request.clear_header("accept-encoding")
        end  
    end

    if path:match(".*/create%-session$") then
        return create_session()
    end

    -- only set client uuid to the header value here, create session will always create new client uuid 
    client_uuid = kong.request.get_header("X-AI-Session-Id")

    if not client_uuid or client_uuid == "" then
        return kong.response.exit(400, { error = "Missing X-AI-Session-Id header" })
    end

    -- Retrieve existing session
    local doc_table, err = session_manager.get_existing_session(client_uuid, conf)
    if err then
        return kong.response.exit(err == "Invalid or expired session" and 401 or 500, { error = err })
    end

    local full_messages = storage_utils.mongo_to_array(doc_table.messages or {})
    for _, msg in ipairs(full_messages) do
        table.insert(all_messages, { role = msg.role, content = msg.content })
    end

    local function handle_user_input(route)
        local max_depth, first_non_summary_index = session_manager.check_session_length(full_messages, doc_table)
        local timeout_reached = session_manager.check_timeout(doc_table)
        if max_depth then
            return kong.response.exit(429, { error = "Session history exceeded. Call /distill-session before another request." })
        elseif timeout_reached then 
            return kong.response.exit(429, { error = "Session life has expired. Please create a new session by calling the /create-session endpoint" })
        end

        local user_prompt = read_body_field("user_prompt")
        if user_prompt and user_prompt ~= "" then
            local new_user_message = { role = "user", content = user_prompt }
            table.insert(all_messages, new_user_message)

            kong.ctx.shared.total_tokens_curr = doc_table.total_tokens
            kong.ctx.shared.new_user_message = {
                role = new_user_message.role,
                content = new_user_message.content,
                is_summary = false
            }
            return
        else
            session_manager.log_error("No user_prompt field found in body table", nil)
            return kong.response.exit(400, "user prompt field is not specified in the body")
        end
    end

    local function handle_summarise()
        local max_depth, first_non_summary_index = session_manager.check_session_length(full_messages, doc_table, conf)
        if not max_depth then
            return kong.response.exit(429, { error = "Session history is not long enough to summarise" })
        end

        local system_prompt = read_body_field("system_prompt")
        local summary_message = session_manager.format_for_summarization(full_messages, first_non_summary_index, system_prompt)

        local messages_to_include = {}
        local total_tokens_included = 0
        if first_non_summary_index and first_non_summary_index ~= 1 then
            for i = 1, first_non_summary_index - 1 do
                table.insert(messages_to_include, full_messages[i])
                total_tokens_included = total_tokens_included + (full_messages[i].tokens or 0)
            end
        end

        kong.ctx.shared.messages_to_include = messages_to_include
        kong.ctx.shared.tokens_to_include = total_tokens_included

        all_messages = { { role = "user", content = summary_message } }
    end

    if path:match(".*/ask$") then
        handle_user_input(path)
    elseif path:match(".*/distill%-session$") then
        handle_summarise()
    end

    -- Prepare upstream request
    local upstream_body = {
        model = conf.model_name,
        messages = all_messages
    }

    kong.service.request.set_body(upstream_body)
    kong.service.request.set_header("Content-Type", "application/json")
    kong.response.set_header("X-AI-Session-Id", client_uuid)
    kong.ctx.shared.client_uuid = client_uuid
    kong.service.request.clear_header("accept-encoding")
end

return SessionHistoryRequestPlugin