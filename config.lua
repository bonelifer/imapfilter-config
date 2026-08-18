-------------
-- Options --
-------------
options.timeout = 120
options.subscribe = true
options.create = true
options.limit = 50

-- Helper to find script path
local function script_path()
  local str = debug.getinfo(2, "S").source:sub(2)
  local path = str:match("(.*/)")
  return path or "./"
end

-- File-loading error handling: only run dofile when the file exists
local function load_config(file)
  local f = io.open(file, "r")
  if f then
    f:close()
    dofile(file)
  end
end

-- Load dependencies once to avoid I/O operations inside loops
local base_path = script_path()
load_config(base_path .. 'accounts.lua')
load_config(base_path .. 'filters.lua')

-- Safety mechanism: define tables as empty if they are missing from the config files
accounts = accounts or {}
from_to_cc_folder = from_to_cc_folder or {}

-- Filter mailing lists dynamically via RFC 2919 List-Id header
local function filter_dynamic_lists(account)
  -- Work around server limitations by selecting all messages in the inbox
  local results = account.INBOX:select_all()

  if #results == 0 then return end

  -- Fetch the complete header for every message to preserve folded lines
  local headers = account.INBOX:fetch_header(results)
  local messages_by_folder = {}

  for _, mesg in ipairs(results) do
    local uid = mesg[2]
    local header = headers[uid] or headers[tostring(uid)] or ""

    if header ~= "" then
      -- RFC 5322 unfolding: replace line breaks followed by whitespace
      -- (spaces or tabs) with a single space across the complete header block.
      header = string.gsub(header, "\r?\n[ \t]+", " ")

      -- Add a leading line break to ensure matches at the start of a line.
      -- [^\n]- prevents the pattern engine from reading past a line break while searching for < >.
      local list_id = string.match("\n" .. header, "\n[Ll][Ii][Ss][Tt]%-[Ii][Dd]:[^\n]-<([^>]+)>")

      if list_id then
        local is_valid = true
        local lower_list_id = string.lower(list_id)

        -- Validation rules that exclude unwanted syntax
        if string.len(list_id) > 50 then is_valid = false end
        if string.match(list_id, "=") then is_valid = false end
        if string.match(lower_list_id, "srs") then is_valid = false end
        if string.match(lower_list_id, "bounces") then is_valid = false end

        if is_valid then
          local clean_name = string.gsub(list_id, "[%.@]", "-")
          local folder_name = "lists-" .. clean_name

          if not messages_by_folder[folder_name] then
            messages_by_folder[folder_name] = {}
          end

          table.insert(messages_by_folder[folder_name], mesg)
        end
      end
    end
  end

  -- Move messages in batches for each folder
  for folder, msgs in pairs(messages_by_folder) do
    Set(msgs):move_messages(account[folder])
  end
end

-- Filter anoying news letters
local function filter_newsletter(account)
  local results = account.INBOX:contain_from("newsletter") +
                  account.INBOX:contain_from("nyhetsbrev") +
                  account.INBOX:contain_subject("newsletter") +
                  account.INBOX:contain_subject("nyhetsbrev") +
                  account.INBOX:contain_body("newsletter") +
                  account.INBOX:contain_body("nyhetsbrev")
  results:move_messages(account['misc-newsletter'])
end

-- Filter anoying webinars.
local function filter_webinar(account)
  local results = account.INBOX:contain_from("webinar") +
                  account.INBOX:contain_subject("webinar") +
                  account.INBOX:contain_body("webinar")
  results:move_messages(account['misc-webinar'])
end

-- Normal filters on from address
local function filter_from(account, address, folder)
  local results = account.INBOX:contain_from(address) +
                  account.INBOX:contain_cc(address) +
                  account.INBOX:contain_to(address)
  results:move_messages(account[folder])
end

-- Run filters on all accounts
for _, account in pairs(accounts) do
  filter_newsletter(account)
  filter_webinar(account)

  -- Automatically identify and route mailing lists
  filter_dynamic_lists(account)

  -- Process manual sender rules (ignored when the table is empty)
  for address, folder in pairs(from_to_cc_folder) do
    filter_from(account, address, folder)
  end
end
