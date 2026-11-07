local _M = {}

-- Convert array to MongoDB string-indexed format (like the working version)
function _M.array_to_mongo(arr)
  if not arr or type(arr) ~= "table" then
    return {}
  end
  
  local mongo_obj = {}
  for i, item in ipairs(arr) do
    if item and type(item) == "table" then
      mongo_obj[tostring(i-1)] = item
    end
  end
  return mongo_obj
end

-- Convert MongoDB string-indexed format back to array
function _M.mongo_to_array(mongo_obj)
  if not mongo_obj or type(mongo_obj) ~= "table" then
    return {}
  end
  
  local arr = {}
  local indices = {}
  
  -- Collect and sort indices
  for k, v in pairs(mongo_obj) do
    local num = tonumber(k)
    if num then
      table.insert(indices, num)
    end
  end
  table.sort(indices)
  
  -- Convert back to array format
  for _, idx in ipairs(indices) do
    local item = mongo_obj[tostring(idx)]
    if item and type(item) == "table" then
      table.insert(arr, item)
    end
  end
  
  return arr
end

return _M