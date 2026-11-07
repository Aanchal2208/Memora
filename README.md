# Session History Plugin
## Overview 
While Kong AI Gateway excels at managing, securing, and routing LLM requests across providers, it lacks conversation state persistence. Our Session History Plugin is a multi-plugin solution that maintains conversation history in persistent session objects. This innovative architecture bridges the critical gap by delivering enterprise-grade conversation management with MongoDB storage, intelligent context summarization, and configurable session lifecycles—ultimately enabling true conversational AI at scale.

## Installation

This guide provides instructions to set up **Lua** and the necessary libraries to interact with **MongoDB** on an Ubuntu VM.

### Prerequisites

* Ubuntu 18.04 / 20.04 / 22.04
* `sudo` privileges
* MongoDB installed and running(host & port required for plugin config)

### Install Lua and Dependencies 

```bash
sudo apt install -y lua5.1 liblua5.1-dev
```
Install LuaRocks (Lua Package Manager) and then the following dependencies since they are used by the plugin:

```bash
sudo apt install -y luarocks
# Required - MongoDB connectivity
luarocks install lua-mongo

# Note: The following are already bundled with Kong Gateway 3.11:
# - lua-cjson (JSON encoding/decoding)
# - lua-resty-jit-uuid (UUID generation) - included in OpenResty/Kong
```

## Setup the Plugins
### Prerequisites 
- An existing AI Gateway service configured with Advanced AI Proxy plugin (this should be there by default) - make sure you have provided your LLM key to the Gateway service. 
- MongoDB instance running and accessible

### Installing the Plugins
To enable the **session-history-request-plugin** and **session-history-response-plugin**, you need to configure them using their respective `schema.lua` files and set up MongoDB connection details.

**1. Place the plugin folders inside the Kong plugin directory** (commonly `/usr/local/share/lua/5.1/kong/plugins/`).

Example:
```
   /usr/local/share/lua/5.1/kong/plugins/session-history-request-plugin/
   /usr/local/share/lua/5.1/kong/plugins/session-history-response-plugin/
```

   Each plugin folder should contain:
   - `handler.lua`
   - `schema.lua`
   - `utils`

**2. Make the Below Changes in Kong.conf**

Find the plugins line (may be commented out with #) and set it to:
   ```
    plugins = bundled,session-history-request-plugin,session-history-response-plugin
   ```

**3. Restart Kong**
   ```bash
    kong restart
   ```

**4. Find the ID of the existing AI Gateway Service**

**5. Add Required Routes to Your AI Gateway Service**
   
   **Create Session Route**
  ```bash
    curl -X POST http://localhost:8001/services/{SERVICE_ID}/routes \
      -d 'name=ai-create-session' \
      -d 'paths[]=/ai/create-session' \
      -d 'methods[]=POST'
  ```
  **Chat Route**
  ```bash
    curl -X POST http://localhost:8001/services/{SERVICE_ID}/routes \
      -d 'name=ai-chat' \
      -d 'paths[]=/ai/ask' \
      -d 'methods[]=POST'
  ```
   **Session Summarization Route**
  ```bash
    curl -X POST http://localhost:8001/services/{SERVICE_ID}/routes \
      -d 'name=ai-distill-session' \
      -d 'paths[]=/ai/distill-session' \
      -d 'methods[]=POST'
  ```
  > Replace SERVICE_ID with the actual ID of the AI Gateway Service


**6. Enable the plugins on the AI Gateway service using the Kong Admin API:**
   ```bash
      curl -X POST http://localhost:8001/services/{SERVICE_ID}/plugins \
        -d "name=session-history-request-plugin" \
        -d "config.mongo_host=127.0.0.1" \
        -d "config.mongo_port=27017" \
        -d "config.mongo_database=kong_sessions" \
        -d "config.mongo_collection=sessions" \
        -d "config.model_name=gemini-1.5-flash"
   ```

   ```bash
      curl -X POST http://localhost:8001/services/{SERVICE_ID}/plugins \
        -d "name=session-history-response-plugin" \
        -d "config.mongo_host=127.0.0.1" \
        -d "config.mongo_port=27017" \
        -d "config.mongo_database=kong_sessions" \
        -d "config.mongo_collection=sessions"
   ```
   > Replace SERVICE_ID with the actual ID of the AI Gateway Service
   > 
   > Replace `127.0.0.1`, `27017`, `kong_sessions`, `sessions`, with your actual MongoDB host, port, database name, collection name
   > 
   > Both plugin schemas also allow you to specify a database username and password through defining mongo_username and mongo_password variables respectively

## Test the plugins
### POST `/create-session`
Initialize a new conversation session with MongoDB storage.

**Parameters:**
- `system_prompt` (string) - Custom AI behavior instructions
- `session_history_depth` (integer) - Number of queries the user can ask before summarization is required. 
- `session_life` (integer) - the session object's TTL in minutes.  

**Example:**
```bash
curl -i -X POST http://localhost:8000/ai/create-session \
  -H 'Content-Type: application/json' \
  -d '{
    "system_prompt": "You are a helpful assistant",
    "session_history_depth": 10,
    "session_life": 3600
  }'
```
**Response:** Returns a session ID in the `X-AI-Session-Id` header and response body.


### POST `/ask`
Send a message to the AI with conversation context.

**Headers:**
- `X-AI-Session-Id` (string) - Unique session identifier

**Parameters:**
- `user_prompt` (string) - User message

**Example:**
```bash
curl -i -X POST http://localhost:8000/ai/ask \
  -H 'Content-Type: application/json' \
  -H 'X-AI-Session-Id: YOUR_SESSION_ID' \
  -d '{
    "user_prompt": "What did we discuss earlier?"
  }'
```
**Response:** Returns the session ID in the `X-AI-Session-Id` header and the response body as formatted by Advanced AI proxy.


### POST `/distill-session`
Summarize and compress session history.

**Headers:**
- `X-AI-Session-Id` (string) - Session to summarize

**Parameters:**
- `summary_prompt` (string, optional) - Custom summarization instructions, if not specified a default summarisation message will be used. 

**Example:**
```bash
curl -i -X POST http://localhost:8000/ai/distill-session \
  -H 'Content-Type: application/json' \
  -H 'X-AI-Session-Id: YOUR_SESSION_ID' \
  -d '{
    "summary_prompt": "Summarize the key decisions made"
  }'
```
**Response:** Returns the session ID in the `X-AI-Session-Id` header and the response body as formatted by Advanced AI proxy.

> Note: Replace `YOUR_SESSION_ID` with the actual session ID


## System Architecture
The Advanced AI proxy plugin comes as part of the Kong AI gateway. 
In our implementation, we have used two plugins, one that runs before the Advanced AI proxy plugin - the session history request plugin, and one that runs after the Advanced AI proxy plugin - the session history response plugin. 

### session-history-request-plugin
There is only one phase for this plugin, the **access** phase. It processes the three endpoints differently:
#### /create-session: 
- When a system prompt is not provided we create the session object, save it to MongoDB, and immediately return with status code 200 and the session id in the response body.
- When a system prompt is provided, we calculate its token count by sending it to the LLM provider through the Advanced AI proxy plugin. 
#### /ask: 
- We first extract the conversation history using the session id from MongoDB
- We retrieve the conversation history from MongoDB, combine it with the user's current query into a messages array, and send this complete conversation context to the Advanced AI Proxy Plugin for processing.
#### /distill-session: 
- We first extract the conversation history using the session id from MongoDB
- We take this conversation history (excluding any system prompt message), that has been extracted from MongoDB, and convert all these messages into a single user request asking to summarise the conversations between the user and LLM. This is sent to the Advanced AI Proxy Plugin, which will format and send the request to the corresponding LLM provider.
- We wanted to give users the option to summarise the conversation history to reduce the amount of tokens consumed on subsequent requests, however we did not want to delegate these requests to another LLM as it would risk exposing potentially confidential client data to an LLM without the user's knowledge. Hence we pass the summarisation request to the same LLM provider the user has configured their AI gateway to use.     

### session-history-response-plugin
There are three phases for this plugin, the **header-filter**, **body-filter** and **log** phase. 
#### header-filter:
- For `/create-session` requests, we set the response status to 200, content type to JSON, and clear the content-length header to prepare for custom response body modification.

#### body-filter:
- We buffer the complete AI response from the Advanced AI proxy plugin by accumulating response chunks until the end of the response is reached.
- For `/create-session` requests:
  - We extract the system prompt token count from the AI response
  - Create a new session document with the system prompt, token count, and initial message structure, and save to MongoDB
  - Return a custom response containing only the session ID
- For other requests, we pass through the AI response unchanged.

#### log:
- We skip processing for `/create-session` requests since they are handled in the body-filter phase.
- For `/ask` and `/distill-session` requests:
  - We parse the AI response to extract token usage and content
  - Update the MongoDB session document with the new message, token counts, and conversation state
  - Save the updated session data asynchronously to maintain conversation history.

### Diagram
<img width="1110" height="307" alt="image" src="https://github.com/user-attachments/assets/aeadcfbd-83b6-448c-9112-c09f732c7f62" />


## Contributors
Designed & Implemented By: j.prakash@neosalpha.com, preesha@neosalpha.com, abhishek.chauhan@neosalpha.com
