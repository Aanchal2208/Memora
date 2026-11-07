local typedefs = require "kong.db.schema.typedefs"

return {
  name = "session-history-request-plugin",
  fields = {
    { consumer = typedefs.no_consumer },
    {
      config = {
        type = "record",
        fields = {
          -- MongoDB settings
          { mongo_host       = { type = "string", default = "127.0.0.1", required = true, description = "MongoDB server host" } },
          { mongo_port       = { type = "number", default = 27017, required = true, description = "MongoDB server port" } },
          { mongo_database   = { type = "string", default = "kong_sessions", required = true, description = "Database name" } },
          { mongo_collection = { type = "string", default = "sessions", required = true, description = "Collection for sessions" } },
          { mongo_username   = { type = "string", required = false, description = "MongoDB username" } },
          { mongo_password   = { type = "string", required = false, encrypted = true, description = "MongoDB password" } },
          { model_name = { type = "string", default = "gemini-1.5-flash", required = true, description = "LLM model name" } }
        },
      },
    },
  },
}