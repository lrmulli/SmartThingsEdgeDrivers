-- Copyright 2021 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local capabilities = require "st.capabilities"
local clusters = require "st.zigbee.zcl.clusters"
local log = require "log"

local WindowCovering = clusters.WindowCovering
local zigbee_utils = require "zigbee_utils"
local Groups = clusters.Groups
local data_types = require "st.zigbee.data_types"
local device_management = require "st.zigbee.device_management"

local function device_bind(driver,device)
  local devadd = device.preferences.devadd
  local rmv = device.preferences.devrmv
  if(rmv ~= "") then
    log.info("Attempting remove device :"..rmv)
    rmv = rmv:gsub('%x%x',function(c)return c.char(tonumber(c,16))end)
    zigbee_utils.send_unbind_request_64(device, WindowCovering.ID, data_types.IeeeAddress(rmv),data_types.Uint8(0x01))
  end
  if(devadd ~= "") then
    log.info("Attempting add device :"..devadd)
    devadd = devadd:gsub('%x%x',function(c)return c.char(tonumber(c,16))end)
    zigbee_utils.send_bind_request_64(device, WindowCovering.ID, data_types.IeeeAddress(devadd),data_types.Uint8(0x01))
  end
  device:send(device_management.build_bind_request(device, WindowCovering.ID, driver.environment_info.hub_zigbee_eui))
  zigbee_utils.send_read_binding_table(device)
end

local function group_bind(device)
  local grp = device.preferences.group
  local rmv = device.preferences.remove
  if(rmv > 0) then
    log.info("Attempting remove group :"..rmv)
    zigbee_utils.send_unbind_request(device, WindowCovering.ID, rmv)
  end
  if(grp > 0) then
    log.info("Attempting add group :"..grp)
    zigbee_utils.send_bind_request(device, WindowCovering.ID, grp)
  end
  zigbee_utils.send_read_binding_table(device)
end
local function device_info_changed(driver, device, event, args)
  -- Did my preference value change
    if args.old_st_store.preferences.group ~= device.preferences.group then
      log.info("Group Id Changed: "..device.preferences.group)
      local group = device.preferences.group
      local oldgroup = args.old_st_store.preferences.group
      group_bind(device)
    end
end

function build_button_handler(button_name, pressed_type)
  return function(driver, device, zb_rx)
    local additional_fields = {
      state_change = true
    }
    if (device.preferences.verbosegrouplog == true) then
      log.info("Fetching Binding Table")
      zigbee_utils.send_read_binding_table(device)
    end
    if (device.preferences.aggressivebind == true) then
      log.info("Aggressive Bind on button press attempt")
      group_bind(device)
      device_bind(driver,device)
    end
    local event = pressed_type(additional_fields)
    local comp = device.profile.components[button_name]
    if comp ~= nil then
      device:emit_component_event(comp, event)
    else
      log.warn("Attempted to emit button event for unknown button: " .. button_name)
    end
  end
end

local open_close_remote = {
  NAME = "Open/Close Remote",
  zigbee_handlers = {
    cluster = {
      [WindowCovering.ID] = {
        [WindowCovering.server.commands.UpOrOpen.ID] = build_button_handler("button1", capabilities.button.button.pushed),
        [WindowCovering.server.commands.DownOrClose.ID] = build_button_handler("button2", capabilities.button.button.pushed)
      }
    }
  },
  lifecycle_handlers = {
    infoChanged = device_info_changed
  },
  can_handle = function(opts, driver, device, ...)
    return device:get_model() == "TRADFRI open/close remote"
  end
}

return open_close_remote
